# frozen_string_literal: true

module Minigun
  # Pipeline represents a single data processing pipeline with stages
  # A Pipeline can be standalone or part of a multi-pipeline Task
  class Pipeline
    attr_reader :name, :config, :stages, :hooks, :dag, :input_queue, :output_queues, :stage_order, :stats,
                :context, :stage_hooks, :stage_input_queues, :runtime_edges

    def initialize(name, config = {}, stages: nil, hooks: nil, stage_hooks: nil, dag: nil, stage_order: nil, stats: nil)
      @name = name
      @config = {
        max_threads: config[:max_threads] || 5,
        max_processes: config[:max_processes] || 2,
        max_retries: config[:max_retries] || 3,
        use_ipc: config[:use_ipc] || false
      }

      @stages = stages || {} # { stage_name => Stage }

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

    # Duplicate this pipeline for inheritance
    def dup
      Pipeline.new(
        @name,
        @config.dup,
        stages: @stages.transform_values(&:dup), # Deep copy - dup each stage object
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
      # Extract routing information
      to_targets = options.delete(:to)
      Array(to_targets).each { |target| @dag.add_edge(name, target) } if to_targets

      # Extract reverse routing (from:)
      from_sources = options.delete(:from)
      Array(from_sources).each { |source| @dag.add_edge(source, name) } if from_sources

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
                # Custom stage class provided
                type.new(name: name, options: options)
              else
                # Extract stage_type from options if present (used by DSL)
                actual_type = options.delete(:stage_type) || type

                # Create appropriate stage subclass based on type symbol
                case actual_type
                when :producer
                  ProducerStage.new(name: name, block: block, options: options)
                when :processor, :consumer
                  ConsumerStage.new(name: name, block: block, options: options)
                when :stage
                  Stage.new(name: name, block: block, options: options)
                when :accumulator
                  AccumulatorStage.new(name: name, block: block, options: options)
                else
                  raise Minigun::Error, "Unknown stage type: #{actual_type}"
                end
              end

      # Check for name collision
      raise Minigun::Error, "Stage name collision: '#{name}' is already defined in pipeline '#{@name}'" if @stages.key?(name)

      # Store stage by name
      @stages[name] = stage

      # Add to stage order and DAG
      @stage_order << name
      @dag.add_node(name)
    end

    # Reroute stages by modifying the DAG
    def reroute_stage(from_stage, to:)
      # Remove existing outgoing edges from this stage
      old_targets = @dag.downstream(from_stage).dup
      old_targets.each do |target|
        @dag.edges[from_stage].delete(target)
        @dag.reverse_edges[target].delete(from_stage)
      end

      # Add new edges
      Array(to).each do |target|
        @dag.add_edge(from_stage, target)
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
    def execute_stage_hooks(type, stage_name)
      hooks = @stage_hooks.dig(type, stage_name) || []
      hooks.each { |h| @context.instance_exec(&h) }
    end

    # Run this pipeline
    def run(context, job_id: nil)
      @context = context
      @job_start = Time.now
      @job_id = job_id

      # Initialize statistics tracking
      @stats = AggregatedStats.new(@name, @dag)
      @stats.start!

      log_info "#{log_prefix} Starting"

      # Build and validate DAG routing
      build_dag_routing!

      # Run before_run hooks
      @hooks[:before_run].each { |h| context.instance_eval(&h) }

      # Execute the pipeline
      run_pipeline(context)

      @job_end = Time.now
      @stats.finish!

      log_info "#{log_prefix} Finished in #{(@job_end - @job_start).round(2)}s"

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
      @stages.each_value do |stage|
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

      @stages.each do |stage_name, stage|
        # Skip autonomous stages - they don't have input queues
        next if stage.run_mode == :autonomous

        # Use stage's queue_size setting (bounded SizedQueue or unbounded Queue)
        size = stage.queue_size
        queues[stage_name] = if size.nil?
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

      @stages.each do |stage_name, stage|
        downstream = @dag.downstream(stage_name)

        # Fan-out: stage has multiple downstream consumers
        next unless downstream.size > 1

        # Get explicit routing strategy from stage options, or default to :broadcast
        routing_strategy = stage.options[:routing] || :broadcast

        # Create the appropriate router subclass
        router_name = :"#{stage_name}_router"
        router_stage = if routing_strategy == :round_robin
                         RouterRoundRobinStage.new(name: router_name, targets: downstream.dup)
                       else
                         RouterBroadcastStage.new(name: router_name, targets: downstream.dup)
                       end
        stages_to_add << [router_name, router_stage]

        # Update DAG: stage -> router -> [downstream targets]
        dag_updates << {
          remove_edges: downstream.map { |target| [stage_name, target] },
          add_edge: [stage_name, router_name],
          add_router_edges: downstream.map { |target| [router_name, target] }
        }

        log_info "[Pipeline:#{@name}] Inserting RouterStage '#{router_name}' (#{routing_strategy}) for fan-out: #{stage_name} -> #{downstream.join(', ')}"
      end

      # Apply DAG updates
      dag_updates.each do |update|
        update[:remove_edges].each { |(from, to)| @dag.remove_edge(from, to) }
        @dag.add_edge(update[:add_edge][0], update[:add_edge][1])
        update[:add_router_edges].each { |(from, to)| @dag.add_edge(from, to) }
      end

      # Add router stages to @stages
      stages_to_add.each do |name, stage|
        @stages[name] = stage
      end
    end

    def find_stage(name)
      @stages[name]
    end

    def terminal_stage?(stage_name)
      @dag.terminal?(stage_name)
    end

    def get_targets(stage_name)
      targets = @dag.downstream(stage_name)

      # If no targets and we have output queues, this is an output stage
      return [:output] if targets.empty? && !@output_queues.empty? && !terminal_stage?(stage_name)

      targets
    end

    # Helper methods to find stages by characteristics
    def find_producer
      @stages.values.find { |stage| stage.run_mode == :autonomous }
    end

    def find_all_producers
      @stages.values.select do |stage|
        if stage.run_mode == :composite
          # Composite stage is a producer if it has no upstream
          @dag.upstream(stage.name).empty?
        else
          stage.run_mode == :autonomous
        end
      end
    end

    private

    def build_dag_routing!
      # Handle multiple producers specially - they should all connect to first non-producer
      puts "[DAG BUILD] BEFORE handle_multiple_producers: edges=#{@dag.edges.map { |k, v| "#{k}->#{v.to_a.join(',')}" }.join(' | ')}"
      handle_multiple_producers_routing!
      puts "[DAG BUILD] AFTER handle_multiple_producers: edges=#{@dag.edges.map { |k, v| "#{k}->#{v.to_a.join(',')}" }.join(' | ')}"

      # Fill any remaining sequential gaps (handles fan-out, siblings, cycles)
      fill_sequential_gaps_by_definition_order!
      puts "[DAG BUILD] AFTER fill_sequential_gaps: edges=#{@dag.edges.map { |k, v| "#{k}->#{v.to_a.join(',')}" }.join(' | ')}"

      @dag.validate!
      validate_stages_exist!

      log_info "#{log_prefix} DAG: #{@dag.topological_sort.join(' -> ')}"
    end

    def validate_stages_exist!
      @dag.nodes.each do |node_name|
        raise Minigun::Error, "[Pipeline:#{@name}] Routing references non-existent stage '#{node_name}'" unless find_stage(node_name)
      end
    end

    def handle_multiple_producers_routing!
      producers = @stage_order.select { |s| find_stage(s)&.run_mode == :autonomous }

      # Each producer without explicit routing should connect to its next stage in definition order
      producers.each do |producer_name|
        # Skip if this producer already has explicit downstream edges
        next unless @dag.downstream(producer_name).empty?

        # Find the next non-autonomous stage after this producer
        producer_index = @stage_order.index(producer_name)
        next_stage = @stage_order[(producer_index + 1)..].find { |s| find_stage(s)&.run_mode != :autonomous }

        @dag.add_edge(producer_name, next_stage) if next_stage
      end
    end

    def fill_sequential_gaps_by_definition_order!
      # Then fill remaining sequential gaps
      @stage_order.each_with_index do |stage_name, index|
        # Skip if already has downstream edges
        next if @dag.downstream(stage_name).any?
        # Skip if this is the last stage
        next if index >= @stage_order.size - 1

        # Find the next non-producer stage
        next_stage = nil
        next_stage_obj = nil
        ((index + 1)...@stage_order.size).each do |next_index|
          candidate = @stage_order[next_index]
          candidate_obj = find_stage(candidate)

          # Skip autonomous stages
          next if candidate_obj.run_mode == :autonomous

          # Found a valid non-producer stage
          next_stage = candidate
          next_stage_obj = candidate_obj
          break
        end

        # No valid next stage found
        next unless next_stage

        # Skip if BOTH current and next are composite stages (isolated pipelines)
        current_stage = find_stage(stage_name)
        next if current_stage.run_mode == :composite && next_stage_obj.run_mode == :composite

        # Skip if this is a fan-out pattern (next_stage is a sibling)
        next if @dag.fan_out_siblings?(stage_name, next_stage)

        # Skip if any sibling already routes to next_stage
        siblings = @dag.siblings(stage_name)
        next if siblings.any? { |sib| @dag.downstream(sib).include?(next_stage) }

        # Don't add edge if it would create a cycle
        next if @dag.would_create_cycle?(stage_name, next_stage)

        @dag.add_edge(stage_name, next_stage)
      end
    end

    def log_prefix
      if @job_id
        "[Job:#{@job_id}][Pipeline:#{@name}]"
      else
        "[Pipeline:#{@name}]"
      end
    end

    def log_info(msg)
      Minigun.logger.info(msg)
    end

    def log_error(msg)
      Minigun.logger.error(msg)
    end
  end
end
