# frozen_string_literal: true

module Minigun
  # Pipeline represents a single data processing pipeline with stages
  # A Pipeline can be standalone or part of a multi-pipeline Task
  class Pipeline
    attr_reader :name, :config, :stages, :hooks, :dag, :output_queues, :stats,
                :context, :stage_hooks, :runtime_edges, :input_queues, :parent_pipeline, :task

    def initialize(name, task, parent_pipeline, config = {}, stages: nil, hooks: nil, stage_hooks: nil, dag: nil, stats: nil)
      @name = name
      @task = task
      @parent_pipeline = parent_pipeline
      @config = {
        max_threads: config[:max_threads] || 5,
        max_processes: config[:max_processes] || 2,
        max_retries: config[:max_retries] || 3,
        use_ipc: config[:use_ipc] || false
      }

      @stages = stages || []
      @deferred_edges = [] # Store edges with forward references: [{from: stage, to: :name}, ...]
      @entrance_router = nil # Router stage for nested pipeline entrance (if multiple entry stages)

      # Pipeline-level hooks (run once per pipeline)
      @hooks = hooks || {
        before_run: [],
        after_run: [],
        before_fork: [],
        after_fork: []
      }

      # Stage-specific hooks (run per stage execution)
      @stage_hooks = stage_hooks || {
        before: {},   # { stage_name => [blocks] }
        after: {},    # { stage_name => [blocks] }
        before_fork: {},
        after_fork: {}
      }

      @dag = dag || DAG.new

      # Statistics tracking
      @stats = stats # Will be initialized in run() if nil
    end

    # Get the root pipeline (top-level pipeline in the hierarchy)
    # Walks up the parent chain until it finds a pipeline with no parent
    def root_pipeline
      @root_pipeline ||= @parent_pipeline&.root_pipeline || self
    end

    # Find a stage by name or object reference
    def find_stage(name_or_obj)
      return name_or_obj if name_or_obj.is_a?(Stage)

      # Use the StageRegistry for proper scoped lookup with ambiguity detection
      if task&.stage_registry
        task.stage_registry.find_by_name(name_or_obj, from_pipeline: self)
      else
        # Fallback to local search if registry not available (e.g., in tests)
        # TODO: This condition should be removed, and we should rely 100% on task.registry
        @stages.find { |stage| stage.name == name_or_obj }
      end
    end

    # Duplicate this pipeline for inheritance
    def dup
      Pipeline.new(
        @name,
        @task,
        @parent_pipeline,
        @config.dup,
        stages: @stages.dup,
        hooks: {
          before_run: @hooks[:before_run].dup,
          after_run: @hooks[:after_run].dup,
          before_fork: @hooks[:before_fork].dup,
          after_fork: @hooks[:after_fork].dup
        },
        stage_hooks: {
          before: @stage_hooks[:before].transform_values(&:dup),
          after: @stage_hooks[:after].transform_values(&:dup),
          before_fork: @stage_hooks[:before_fork].transform_values(&:dup),
          after_fork: @stage_hooks[:after_fork].transform_values(&:dup)
        },
        dag: @dag.dup
      )
    end

    # Add a stage to this pipeline
    # type can be a Symbol (:producer, :consumer, etc.) or a custom Stage class
    def add_stage(type, name, options = {}, &block)
      # Extract routing information (will be resolved after stage creation)
      to_targets = options.delete(:to)
      from_sources = options.delete(:from)

      # Extract inline hook procs (Option 3)
      if (before_proc = options.delete(:before))
        add_stage_hook(:before, name, &before_proc)
      end

      if (after_proc = options.delete(:after))
        add_stage_hook(:after, name, &after_proc)
      end

      if (before_fork_proc = options.delete(:before_fork))
        add_stage_hook(:before_fork, name, &before_fork_proc)
      end

      if (after_fork_proc = options.delete(:after_fork))
        add_stage_hook(:after_fork, name, &after_fork_proc)
      end

      # Create stage instance
      stage = if type.is_a?(Class)
                # Custom stage class provided (positional constructor style)
                type.new(name, self, block, options)
              else
                # Extract stage_type from options if present (used by DSL)
                actual_type = options.delete(:stage_type) || type

                # Create appropriate stage subclass based on type symbol (pipeline-first positional style)
                case actual_type
                when :producer
                  ProducerStage.new(name, self, block, options)
                when :processor, :consumer
                  ConsumerStage.new(name, self, block, options)
                when :stage
                  Stage.new(name, self, block, options)
                when :accumulator
                  AccumulatorStage.new(name, self, block, options)
                else
                  raise Minigun::Error, "Unknown stage type: #{actual_type}"
                end
              end

      # Check for name collision LOCALLY (within this pipeline only)
      if @stages.any? { |s| s.name == name }
        raise Minigun::Error, "Stage name collision: '#{name}' is already defined in pipeline '#{@name}'"
      end

      # Store stage in array
      @stages << stage

      # Add to DAG (using object reference)
      @dag.add_node(stage)

      # Add routing edges - resolve names to Stage objects immediately
      if to_targets
        Array(to_targets).each do |target|
          if (target_stage = find_stage(target))
            @dag.add_edge(stage, target_stage)
          else
            # Forward reference - defer until target is created
            @deferred_edges << { from: stage, to: target }
          end
        end
      end

      if from_sources
        Array(from_sources).each do |source|
          if (source_stage = find_stage(source))
            @dag.add_edge(source_stage, stage)
          else
            # Forward reference - defer until source is created
            @deferred_edges << { from: source, to: stage }
          end
        end
      end

      # Process any deferred edges that now have both endpoints
      process_deferred_edges!
    end

    # Process deferred edges - add them to DAG once both endpoints exist
    def process_deferred_edges!
      resolved = []
      @deferred_edges.each do |edge|
        from_stage = edge[:from].is_a?(Stage) ? edge[:from] : find_stage(edge[:from])
        to_stage = edge[:to].is_a?(Stage) ? edge[:to] : find_stage(edge[:to])

        if from_stage && to_stage
          @dag.add_edge(from_stage, to_stage)
          resolved << edge
        end
      end

      # Remove resolved edges
      @deferred_edges -= resolved
    end

    # Reroute stages by modifying the DAG
    # from_stage: Stage object or name
    # to: Stage object(s) or name(s)
    def reroute_stage(from_stage, to:)
      # Resolve from_stage to object
      from_obj = find_stage(from_stage)
      raise Minigun::Error, "[Pipeline:#{@name}] Cannot find stage: #{from_stage}" unless from_obj

      # Remove existing outgoing edges from this stage
      old_targets = @dag.downstream(from_obj).dup
      old_targets.each do |target|
        @dag.edges[from_obj].delete(target)
        @dag.reverse_edges[target].delete(from_obj)
      end

      # Add new edges (resolve targets to objects)
      Array(to).each do |target|
        target_obj = find_stage(target)
        raise Minigun::Error, "[Pipeline:#{@name}] Cannot find stage: #{target}" unless target_obj
        @dag.add_edge(from_obj, target_obj)
      end

      # Disconnected stage detection happens after DAG is fully built
      # See: apply_await_to_disconnected_stages! called from build_dag_routing!
    end

    # Add a pipeline-level hook
    def add_hook(type, &block)
      @hooks[type] ||= []
      @hooks[type] << block
    end

    # Add a stage-specific hook
    def add_stage_hook(type, stage_name, &block)
      @stage_hooks[type] ||= {}
      @stage_hooks[type][stage_name] ||= []
      @stage_hooks[type][stage_name] << block
    end

    # Execute stage-specific hooks
    # stage_or_name can be Stage object or name
    def execute_stage_hooks(type, stage_or_name)
      # REMOVE_THIS -- hooks should directly reference stage objects, not by name
      # Get the stage name (hooks are keyed by name)
      name = stage_or_name.is_a?(Stage) ? stage_or_name.name : stage_or_name
      hooks = @stage_hooks.dig(type, name) || []
      hooks.each { |h| @context.instance_exec(&h) }
    end

    # Execute both pipeline-level and stage-specific hooks
    # Pipeline-level hooks are executed first, then stage-specific hooks
    def execute_fork_hooks(type, stage_or_name)
      # Execute pipeline-level hooks first
      (@hooks[type] || []).each { |h| @context.instance_exec(&h) }
      # Then execute stage-specific hooks
      execute_stage_hooks(type, stage_or_name)
    end

    # Run this pipeline
    def run(context, job_id: nil)
      @context = context
      @job_start = Time.now
      @job_id = job_id

      # Initialize statistics tracking
      @stats = AggregatedStats.new(self, @dag)
      @stats.start!

      log_debug "#{log_prefix} Starting"

      # Build and validate DAG routing
      build_dag_routing!

      # Run before_run hooks
      @hooks[:before_run].each { |h| context.instance_eval(&h) }

      # Execute the pipeline
      run_pipeline(context)

      @job_end = Time.now
      @stats.finish!

      log_debug "#{log_prefix} Finished in #{(@job_end - @job_start).round(2)}s"

      # Run after_run hooks
      @hooks[:after_run].each { |h| context.instance_eval(&h) }

      # Return produced count
      @stats.total_produced
    end

    # Main pipeline execution logic
    def run_pipeline(_context)
      # Insert router stages for fan-out
      insert_router_stages_for_fan_out

      # Create one input queue per stage (except producers) and register with Task
      build_stage_input_queues
      @produced_count = Concurrent::AtomicFixnum.new(0)
      @stage_threads = []

      # Track runtime edges (who sends to whom) for dynamic routing termination
      # Key: source stage, Value: Set of target stages
      @runtime_edges = Concurrent::Hash.new { |h, k| h[k] = Concurrent::Set.new }

      # Start unified workers for ALL stages (producers and consumers)
      @stages.each do |stage|
        worker = Worker.new(self, stage, @config)
        worker.start
        @stage_threads << worker
      end

      # Wait for all workers to finish
      @stage_threads.each(&:join)
    end

    # Build one input queue per stage (except producers) and register with Task
    def build_stage_input_queues
      # Find entrance infrastructure (router or single entry stage)
      entry_stages = @stages.select do |s|
        s.run_mode != :autonomous && @dag.upstream(s).empty?
      end

      @stages.each do |stage|
        # Skip autonomous stages - they don't have input queues
        next if stage.run_mode == :autonomous

        # Entrance router uses PipelineStage's queue
        if stage == @entrance_router && @input_queues && @input_queues[:input]
          register_queue(stage, @input_queues[:input])
          next
        end

        # Single entry stage uses PipelineStage's queue directly (no router)
        if entry_stages.size == 1 && stage == entry_stages.first && @input_queues && @input_queues[:input]
          register_queue(stage, @input_queues[:input])
          next
        end

        # Use stage's queue_size setting (bounded SizedQueue or unbounded Queue)
        size = stage.queue_size
        queue = if size.nil?
                  Queue.new # Unbounded queue
                else
                  SizedQueue.new(size) # Bounded queue with backpressure
                end
        register_queue(stage, queue)
      end
    end

    # Insert RouterStage instances for fan-out patterns
    def insert_router_stages_for_fan_out
      stages_to_add = []
      dag_updates = []

      @stages.dup.each do |stage|  # dup to avoid modifying during iteration
        # After normalization, DAG uses Stage objects
        downstream = @dag.downstream(stage)

        # Fan-out: stage has multiple downstream consumers
        next unless downstream.size > 1

        # Get explicit routing strategy from stage options, or default to :broadcast
        routing_strategy = stage.options[:routing] || :broadcast

        # Create the appropriate router subclass (pipeline-first positional style)
        router_name = :"#{stage.name}_router"
        router_stage = if routing_strategy == :round_robin
                         RouterRoundRobinStage.new(router_name, self, downstream.dup, {})
                       else
                         RouterBroadcastStage.new(router_name, self, downstream.dup, {})
                       end
        stages_to_add << router_stage

        # Update DAG: stage -> router -> [downstream targets] (all objects)
        dag_updates << {
          remove_edges: downstream.map { |target| [stage, target] },
          add_edge: [stage, router_stage],
          add_router_edges: downstream.map { |target| [router_stage, target] }
        }

        downstream_names = downstream.map(&:name).join(', ')
        log_debug "[Pipeline:#{@name}] Inserting RouterStage '#{router_name}' (#{routing_strategy}) for fan-out: #{stage.name} -> #{downstream_names}"
      end

      # Apply DAG updates
      dag_updates.each do |update|
        update[:remove_edges].each { |(from, to)| @dag.remove_edge(from, to) }
        @dag.add_edge(update[:add_edge][0], update[:add_edge][1])
        update[:add_router_edges].each { |(from, to)| @dag.add_edge(from, to) }
      end

      # Add router stages to @stages array
      stages_to_add.each do |stage|
        @stages << stage
      end
    end

    # stage: Stage object only (no name lookup)
    def terminal_stage?(stage)
      @dag.terminal?(stage)
    end

    # stage: Stage object only (no name lookup)
    def get_targets(stage)
      targets = @dag.downstream(stage)

      # If no targets and we have output queues, this is an output stage
      return [:output] if targets.empty? && !@output_queues.empty? && !terminal_stage?(stage)

      targets
    end

    # Helper methods to find stages by characteristics
    def find_producer
      @stages.find { |stage| stage.run_mode == :autonomous }
    end

    def find_all_producers
      @stages.select do |stage|
        if stage.run_mode == :composite
          # Composite stage is a producer if it has no upstream (DAG uses objects)
          @dag.upstream(stage).empty?
        else
          stage.run_mode == :autonomous
        end
      end
    end

    private

    def build_dag_routing!
      # Finalize any remaining deferred edges
      process_deferred_edges!

      # Check for unresolved forward references (edges)
      unless @deferred_edges.empty?
        unresolved = @deferred_edges.map { |e| "#{e[:from].inspect} -> #{e[:to].inspect}" }.join(", ")
        raise Minigun::Error, "[Pipeline:#{@name}] Unresolved routing references: #{unresolved}"
      end

      # Handle multiple producers specially - they should all connect to first non-producer
      handle_multiple_producers_routing!

      # Fill any remaining sequential gaps (handles fan-out, siblings, cycles)
      fill_sequential_gaps_by_definition_order!

      # If this pipeline has input_queues (nested pipeline), add entrance distributor
      insert_entrance_distributor_for_inputs! if @input_queues && !@input_queues.empty?

      # If this pipeline has output_queues, add :_exit collector for terminal stages
      insert_exit_collector_for_outputs! if @output_queues && !@output_queues.empty?

      @dag.validate!
      validate_stages_exist!

      # Apply await: false to stages that are fully disconnected (no upstreams)
      # This handles rerouted stages and other disconnected scenarios
      apply_await_to_disconnected_stages!

      log_debug "#{log_prefix} DAG: #{@dag.topological_sort.map(&:name).join(' -> ')}"
    end

    def apply_await_to_disconnected_stages!
      # After DAG is fully built, identify stages with no upstreams and auto-configure await behavior.
      # Stages without upstreams fall into three categories:
      # 1. Producers (autonomous) - expected to have no upstreams, skip these
      # 2. Rerouted or orphaned stages - auto-set await: false for immediate shutdown
      # 3. Dynamic routing targets - user should explicitly set await: true
      @stages.each do |stage|
        # Skip producers - they're autonomous and don't need upstreams
        next if stage.run_mode == :autonomous

        # Check if stage has any upstreams
        upstreams = @dag.upstream(stage)
        next unless upstreams.empty?

        # Stage has no upstreams and no explicit await configuration
        # Default to immediate shutdown (await: false) to catch pipeline bugs quickly
        unless stage.options.key?(:await)
          stage.options[:await] = false
          Minigun.logger.debug "[Pipeline:#{@name}] Stage #{stage.name} has no DAG upstreams, auto-set await: false"
        end
      end
    end

    def validate_stages_exist!
      @dag.nodes.each do |node|
        # After normalization, all nodes should be Stage objects
        unless node.is_a?(Stage)
          raise Minigun::Error, "[Pipeline:#{@name}] Routing references non-existent stage '#{node}'"
        end
      end
    end

    def handle_multiple_producers_routing!
      # @stages contains Stage objects in definition order
      producers = @stages.select { |stage| stage.run_mode == :autonomous }

      # Each producer without explicit routing should connect to its next stage in definition order
      producers.each do |producer|
        # Skip if this producer already has explicit downstream edges
        next unless @dag.downstream(producer).empty?

        # Find the next non-autonomous stage after this producer
        producer_index = @stages.index(producer)
        next_stage = @stages[(producer_index + 1)..].find { |stage| stage.run_mode != :autonomous }

        @dag.add_edge(producer, next_stage) if next_stage
      end
    end

    def fill_sequential_gaps_by_definition_order!
      # @stages contains Stage objects in definition order
      @stages.each_with_index do |stage, index|
        # Skip if already has downstream edges
        next if !@dag.downstream(stage).empty?
        # Skip if this is the last stage
        next if index >= @stages.size - 1

        # Find the next non-producer stage
        next_stage = nil
        ((index + 1)...@stages.size).each do |next_index|
          candidate = @stages[next_index]

          # Skip autonomous stages
          next if candidate.run_mode == :autonomous

          # Skip stages with await: true - they're dynamic routing targets
          # and shouldn't be auto-connected
          next if candidate.options[:await] == true

          # Found a valid non-producer stage
          next_stage = candidate
          break
        end

        # No valid next stage found
        next unless next_stage

        # Skip if current stage has await: true - it shouldn't connect to anything
        # (it's a dynamic routing target that only receives via output.to())
        next if stage.options[:await] == true

        # Skip if BOTH current and next are composite stages (isolated pipelines)
        next if stage.run_mode == :composite && next_stage.run_mode == :composite

        # Skip if this is a fan-out pattern (next_stage is a sibling)
        next if @dag.fan_out_siblings?(stage, next_stage)

        # Skip if any sibling already routes to next_stage
        siblings = @dag.siblings(stage)
        next if siblings.any? { |sib| @dag.downstream(sib).include?(next_stage) }

        # Don't add edge if it would create a cycle
        next if @dag.would_create_cycle?(stage, next_stage)

        @dag.add_edge(stage, next_stage)
      end
    end

    # Insert an entrance distributor for nested pipelines
    # Uses RouterStage for multiple entries, direct connection for single entry
    def insert_entrance_distributor_for_inputs!
      # Find stages that have no upstream (would be entry points)
      entry_stages = @stages.select do |stage|
        next false if stage.run_mode == :autonomous
        @dag.upstream(stage).empty?
      end

      return if entry_stages.empty?

      # Single entry stage: it uses PipelineStage's queue directly (no router needed)
      # This is handled in build_stage_input_queues
      return if entry_stages.size == 1

      # Multiple entry stages: create a router to distribute items
      # Get routing strategy from parent_pipeline's config (where PipelineStage lives)
      pipeline_stage = @parent_pipeline&.stages&.find { |s| s.is_a?(PipelineStage) && s.nested_pipeline == self }
      routing_strategy = pipeline_stage&.options&.[](:routing) || :broadcast

      # Create anonymous router stage
      @entrance_router = if routing_strategy == :round_robin
                           RouterRoundRobinStage.new(nil, self, entry_stages.dup, {})
                         else
                           RouterBroadcastStage.new(nil, self, entry_stages.dup, {})
                         end

      # Add router to pipeline
      @stages.unshift(@entrance_router)
      @dag.add_node(@entrance_router)

      # Connect router to entry stages
      entry_stages.each do |stage|
        @dag.add_edge(@entrance_router, stage)
      end

      entry_names = entry_stages.map(&:name).join(', ')
      log_debug "[Pipeline:#{@name}] Added #{routing_strategy} entrance router for entry stages: #{entry_names}"
    end

    # Insert an :_exit collector stage that terminal stages drain into
    # This allows nested pipelines to send their outputs to the parent pipeline
    def insert_exit_collector_for_outputs!
      # Find terminal stages (stages with no downstream)
      # After normalization, DAG uses Stage objects
      terminal_stages = @stages.select { |stage| @dag.terminal?(stage) }
      return if terminal_stages.empty?

      # Create a consumer stage that forwards items to @output_queues[:output]
      # The block receives (item, output) but we ignore output and use @output_queues directly
      parent_output = @output_queues[:output]
      exit_block = proc do |item, _stage_output|
        parent_output << item if parent_output
      end
      exit_stage = Minigun::ExitStage.new(nil, self, exit_block, {})

      # Add the :_exit stage to the pipeline
      @stages << exit_stage
      @dag.add_node(exit_stage)

      # Connect terminal stages to :_exit (all objects)
      terminal_stages.each do |stage|
        @dag.add_edge(stage, exit_stage)
      end

      # Note: input queue for :_exit will be created automatically by build_stage_input_queues

      terminal_names = terminal_stages.map(&:name).join(', ')
      log_debug "[Pipeline:#{@name}] Added :_exit collector for terminal stages: #{terminal_names}"
    end

    def log_prefix
      if @job_id
        "[Job:#{@job_id}][Pipeline:#{@name}]"
      else
        "[Pipeline:#{@name}]"
      end
    end

    def log_debug(msg)
      Minigun.logger.debug(msg)
    end

    # Register a queue with the task's queue registry
    def register_queue(stage, queue)
      @task&.register_stage_queue(stage, queue)
    end

    def log_error(msg)
      Minigun.logger.error(msg)
    end
  end
end

