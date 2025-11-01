# frozen_string_literal: true

module Minigun
  # Wrapper for stages array that provides both array and hash-like access
  # This maintains backward compatibility with tests that use stages[:name]
  # REMOVE_THIS - convert back to registry
  class StagesCollection < Array
    def [](key)
      if key.is_a?(Integer)
        # Array access: stages[0]
        super
      else
        # Hash access: stages[:name] - find by name
        find { |stage| stage.name == key }
      end
    end

    def []=(key, value)
      if key.is_a?(Integer)
        # Array assignment: stages[0] = stage
        super
      else
        # Hash assignment: stages[:name] = stage
        # Remove any existing stage with this name first
        delete_if { |stage| stage.name == key }
        # Add the new stage
        self << value
      end
    end

    def key?(name)
      any? { |stage| stage.name == name }
    end
  end

  # Pipeline represents a single data processing pipeline with stages
  # A Pipeline can be standalone or part of a multi-pipeline Task
  class Pipeline
    attr_reader :name, :config, :stages, :hooks, :dag, :output_queues, :stage_order, :stats,
                :context, :stage_hooks, :stage_input_queues, :runtime_edges, :input_queues

    def initialize(name, config = {}, stages: nil, hooks: nil, stage_hooks: nil, dag: nil, stage_order: nil, stats: nil)
      @name = name
      @config = {
        max_threads: config[:max_threads] || 5,
        max_processes: config[:max_processes] || 2,
        max_retries: config[:max_retries] || 3,
        use_ipc: config[:use_ipc] || false
      }

      @stages = stages || StagesCollection.new # REMOVE_THIS - implement NameRegistry Array of Stage objects with hash-like access
      @deferred_edges = [] # Store edges with forward references: [{from: stage, to: :name}, ...]

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
      @stage_order = stage_order || []

      # Statistics tracking
      @stats = stats # Will be initialized in run() if nil
    end

    # Find a stage by name or object reference
    def find_stage(name_or_obj)
      return name_or_obj if name_or_obj.is_a?(Stage)
      @stages.find { |stage| stage.name == name_or_obj }
    end

    # Duplicate this pipeline for inheritance
    def dup
      duped_stages = StagesCollection.new # REMOVE_THIS
      @stages.each { |stage| duped_stages << stage.dup }

      Pipeline.new(
        @name,
        @config.dup,
        stages: duped_stages, # REMOVE_THIS - change to just @stages.map(&:dup) Deep copy - dup each stage object
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
        dag: @dag.dup,
        stage_order: @stage_order.dup
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
                type.new(self, name, block, options)
              else
                # Extract stage_type from options if present (used by DSL)
                actual_type = options.delete(:stage_type) || type

                # Create appropriate stage subclass based on type symbol (pipeline-first positional style)
                case actual_type
                when :producer
                  ProducerStage.new(self, name, block, options)
                when :processor, :consumer
                  ConsumerStage.new(self, name, block, options)
                when :stage
                  Stage.new(self, name, block, options)
                when :accumulator
                  AccumulatorStage.new(self, name, block, options)
                else
                  raise Minigun::Error, "Unknown stage type: #{actual_type}"
                end
              end

      # Check for name collision
      raise Minigun::Error, "Stage name collision: '#{name}' is already defined in pipeline '#{@name}'" if find_stage(name)

      # Store stage in array
      @stages << stage

      # Add to stage order and DAG (using object reference)
      @stage_order << stage
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
      @stats = AggregatedStats.new(@name, @dag)
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

      # Create one input queue per stage (except producers)
      @stage_input_queues = build_stage_input_queues
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

    # Build one input queue per stage (except producers)
    def build_stage_input_queues
      queues = {}

      @stages.each do |stage|
        # Skip autonomous stages - they don't have input queues
        next if stage.run_mode == :autonomous

        # Special case: EntranceStage uses the parent pipeline's input queue
        if stage.is_a?(EntranceStage) && @input_queues && @input_queues[:input]
          queues[stage] = @input_queues[:input]  # Key by object
          next
        end

        # Use stage's queue_size setting (bounded SizedQueue or unbounded Queue)
        size = stage.queue_size
        queues[stage] = if size.nil?
                          Queue.new # Unbounded queue
                        else
                          SizedQueue.new(size) # Bounded queue with backpressure
                        end
      end

      queues
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
                         RouterRoundRobinStage.new(self, router_name, downstream.dup, {})
                       else
                         RouterBroadcastStage.new(self, router_name, downstream.dup, {})
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

      # Add router stages to @stages array and stage_order
      stages_to_add.each do |stage|
        @stages << stage
        @stage_order << stage  # Add to stage_order for proper tracking
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

      # If this pipeline has input_queues (nested pipeline), add :_entrance distributor
      insert_entrance_distributor_for_inputs! if @input_queues && !@input_queues.empty?

      # If this pipeline has output_queues, add :_exit collector for terminal stages
      insert_exit_collector_for_outputs! if @output_queues && !@output_queues.empty?

      @dag.validate!
      validate_stages_exist!

      log_debug "#{log_prefix} DAG: #{@dag.topological_sort.map(&:name).join(' -> ')}"
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
      # After normalization, @stage_order contains Stage objects
      producers = @stage_order.select { |stage| stage.run_mode == :autonomous }

      # Each producer without explicit routing should connect to its next stage in definition order
      producers.each do |producer|
        # Skip if this producer already has explicit downstream edges
        next unless @dag.downstream(producer).empty?

        # Find the next non-autonomous stage after this producer
        producer_index = @stage_order.index(producer)
        next_stage = @stage_order[(producer_index + 1)..].find { |stage| stage.run_mode != :autonomous }

        @dag.add_edge(producer, next_stage) if next_stage
      end
    end

    def fill_sequential_gaps_by_definition_order!
      # After normalization, @stage_order contains Stage objects
      @stage_order.each_with_index do |stage, index|
        # Skip if already has downstream edges
        next if @dag.downstream(stage).any?
        # Skip if this is the last stage
        next if index >= @stage_order.size - 1

        # Find the next non-producer stage
        next_stage = nil
        ((index + 1)...@stage_order.size).each do |next_index|
          candidate = @stage_order[next_index]

          # Skip autonomous stages
          next if candidate.run_mode == :autonomous

          # Found a valid non-producer stage
          next_stage = candidate
          break
        end

        # No valid next stage found
        next unless next_stage

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

    # Insert an :_entrance distributor stage for nested pipelines
    # This receives items from the parent pipeline and distributes to entry stages
    def insert_entrance_distributor_for_inputs!
      # Find stages that have no upstream (would be entry points)
      # After normalization, DAG uses Stage objects
      entry_stages = @stages.select do |stage|
        # Skip autonomous stages (they're producers)
        next false if stage.run_mode == :autonomous
        # Entry stages have no upstream
        @dag.upstream(stage).empty?
      end

      return if entry_stages.empty?

      # Create a consumer stage that reads from parent input and emits to nested pipeline
      # Use ConsumerStage (not ProducerStage) so it properly tracks multiple END signals
      parent_input = @input_queues[:input]
      entrance_block = proc do |item, output|
        # Just forward items from parent to nested pipeline
        output << item
      end
      entrance_stage = Minigun::EntranceStage.new(self, :_entrance, entrance_block, {})

      # Add the :_entrance stage to the pipeline
      @stages << entrance_stage
      @stage_order.unshift(entrance_stage) # Add stage object
      @dag.add_node(entrance_stage)

      # Connect :_entrance to entry stages (all objects)
      entry_stages.each do |stage|
        @dag.add_edge(entrance_stage, stage)
      end

      entry_names = entry_stages.map(&:name).join(', ')
      log_debug "[Pipeline:#{@name}] Added :_entrance distributor for entry stages: #{entry_names}"
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
      exit_stage = Minigun::ExitStage.new(self, :_exit, exit_block, {})

      # Add the :_exit stage to the pipeline
      @stages << exit_stage
      @stage_order << exit_stage  # Add stage object
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

    def log_error(msg)
      Minigun.logger.error(msg)
    end
  end
end

