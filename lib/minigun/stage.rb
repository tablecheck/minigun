# frozen_string_literal: true

require 'securerandom'

module Minigun
  # Unified context for all stage execution (producers and workers)
  StageContext = Struct.new(
    # Common to all stages
    :pipeline,
    :stage,
    :stage_name, # REMOVE_THIS -- if needed, use stage.name, but prefer doing references by stage
    :dag,
    :runtime_edges,
    :stage_input_queues,
    :stage_stats,
    # Worker-specific (nil/empty for producers)
    :worker,
    :input_queue,
    :sources_expected,
    :sources_done,
    keyword_init: true
  ) do
    # Convenience method to access executor through worker
    def executor
      worker&.executor
    end
  end

  # Base class for all execution units (stages and pipelines)
  # Implements the Composite pattern where Pipeline is a composite Stage
  # Also handles loop-based stages (stages that manage their own input loop)
  class Stage
    attr_reader :name, :options, :block, :pipeline

    def initialize(*args, name: nil, block: nil, options: {}, **kwargs)
      # Support both old (keyword) and new (positional) signatures
      # New: Stage.new(pipeline, name, block, options)
      # Old: Stage.new(name: :foo, block: proc {}, options: {})
      if args.length > 0 && args[0].is_a?(Pipeline)
        # New positional style: (pipeline, name, block, options)
        @pipeline = args[0]
        @name = args[1]
        @block = args[2]
        @options = args[3] || {}
      else # REMOVE_THIS
        # Old keyword style (backward compatible)
        @pipeline = nil
        @name = name
        @block = block
        @options = options
      end

      # Auto-generate name if not provided (for unnamed stages)
      # Use "_" prefix + 8 char random hex
      # TODO: Convert to base62
      @name = :"_#{SecureRandom.hex(4)}" if @name.nil?
    end

    # Get the queue size for this stage
    # Returns nil for unbounded queues (0, Float::INFINITY, nil)
    # Returns integer for bounded queues (SizedQueue)
    def queue_size
      size = @options[:queue_size]

      # Use global default if not specified
      size = Minigun.default_queue_size if size.nil?

      # Check for unbounded indicators
      return nil if [0, Float::INFINITY, false].include?(size)

      size.to_i
    end

    # Execute the stage with the given context
    # For loop-based stages, this receives input_queue and output_queue
    def execute(context, input_queue, output_queue, _stage_stats)
      if @block
        context.instance_exec(input_queue, output_queue, &@block)
      elsif respond_to?(:call)
        call_with_arity(input_queue, output_queue, &output_queue.to_proc)
      end
    end

    # Run the stage execution
    # Loop-based stages manage their own input loop
    def run_stage(stage_ctx)
      # Create wrapped queues
      input_queue = create_input_queue(stage_ctx) # TODO: move to worker?
      output_queue = create_output_queue(stage_ctx)

      # Execute with both queues (block manages its own loop)
      context = stage_ctx.pipeline.context
      execute(context, input_queue, output_queue, stage_ctx.stage_stats)
    ensure
      send_end_signals(stage_ctx)
    end

    # Get execution context configuration for this stage
    def execution_context
      @options[:_execution_context]
    end

    # Hash representation (for test compatibility)
    def to_h
      hash = { name: @name, options: @options }
      hash[:block] = @block if @block
      hash
    end

    # Hash-like access (for test compatibility)
    def [](key)
      case key
      when :name then @name
      when :options then @options
      when :block then @block
      end
    end

    # Type name for logging purposes
    def log_type
      'Worker'
    end

    # Execution strategy: :autonomous, :streaming, or :composite
    def run_mode
      :streaming # Default: process stream of items in worker loop
    end

    private

    # Create wrapped input queue for this stage
    def create_input_queue(stage_ctx)
      InputQueue.new(
        stage_ctx.input_queue,
        stage_ctx.stage,
        stage_ctx.sources_expected,
        stage_stats: stage_ctx.stage_stats
      )
    end

    # Create wrapped output queue for this stage
    def create_output_queue(stage_ctx)
      # DAG and queues now use Stage objects
      downstream = stage_ctx.dag.downstream(stage_ctx.stage)
      downstream_queues = downstream.filter_map { |ds| stage_ctx.stage_input_queues[ds] }
      OutputQueue.new(
        stage_ctx.stage,
        downstream_queues,
        stage_ctx.stage_input_queues,
        stage_ctx.runtime_edges,
        pipeline: stage_ctx.pipeline, # REMOVE_THIS
        stage_stats: stage_ctx.stage_stats
      )
    end

    # Consolidated end signal logic used by all stage types
    def send_end_signals(stage_ctx)
      dag_downstream = stage_ctx.dag.downstream(stage_ctx.stage)
      dynamic_targets = stage_ctx.runtime_edges[stage_ctx.stage].to_a
      all_targets = (dag_downstream + dynamic_targets).uniq

      all_targets.each do |target|
        next unless stage_ctx.stage_input_queues[target]

        stage_ctx.stage_input_queues[target] << EndOfSource.new(stage_ctx.stage)
      end
    end

    # Call the stage's #call method with appropriate args based on arity
    def call_with_arity(*args, &)
      arity = method(:call).arity.abs
      call(*args[...arity], &)
    end
  end

  # Producer stage - executes once, no input
  class ProducerStage < Stage
    def execute(context, _input_queue, output_queue, _stage_stats)
      if @block
        context.instance_exec(output_queue, &@block)
      elsif respond_to?(:call)
        call_with_arity(output_queue, &output_queue.to_proc)
      end
    end

    def log_type
      'Producer'
    end

    def run_mode
      :autonomous # Generates data independently
    end

    def run_stage(stage_ctx)
      # Execute before hooks
      execute_hooks(stage_ctx, :before)

      # Create output queue
      output_queue = create_output_queue(stage_ctx)

      # Execute producer block directly (ProducerStage doesn't use executor since it's autonomous)
      context = stage_ctx.pipeline.context
      execute(context, nil, output_queue, stage_ctx.stage_stats)

      # Execute after hooks
      execute_hooks(stage_ctx, :after)
    ensure
      send_end_signals(stage_ctx)
    end

    private

    def execute_hooks(ctx, type)
      ctx.pipeline.execute_stage_hooks(type, ctx.stage)
    end
  end

  # Consumer/Processor stage - loops on input, processes items
  class ConsumerStage < Stage
    def execute(context, input_queue, output_queue, stage_stats)
      # Consumer stages pop from input_queue and process items
      loop do
        item = input_queue.pop

        break if item.is_a?(EndOfStage)

        # Execute the block or call method with the item, tracking per-item latency
        begin
          start_time = Time.now if stage_stats

          if @block
            context.instance_exec(item, output_queue, &@block)
          elsif respond_to?(:call)
            call_with_arity(item, output_queue, &output_queue.to_proc)
          end

          # Record per-item latency for bottleneck detection
          stage_stats&.record_latency(Time.now - start_time)
        rescue StandardError => e
          # Log item-level errors but continue processing
          Minigun.logger.error "[Stage:#{name}] Error processing item: #{e.message}"
          Minigun.logger.debug e.backtrace.join("\n") if Minigun.logger.debug?
        end
      end
    end

    def run_stage(stage_ctx)
      # Execute before hooks
      stage_ctx.pipeline.send(:execute_stage_hooks, :before, stage_ctx.stage)

      # Create wrapped queues
      input_queue = create_input_queue(stage_ctx)
      output_queue = create_output_queue(stage_ctx)

      # Execute via executor (defines HOW: inline/threaded/process)
      context = stage_ctx.pipeline.context
      stage_ctx.executor.execute_stage(self, context, input_queue, output_queue)

      # Execute after hooks
      stage_ctx.pipeline.send(:execute_stage_hooks, :after, stage_ctx.stage)

      # Flush and cleanup
      flush_if_needed(stage_ctx, output_queue)
    ensure
      send_end_signals(stage_ctx)
    end

    private

    def flush_if_needed(stage_ctx, output_queue)
      return unless respond_to?(:flush)

      context = stage_ctx.pipeline.context
      flush(context, output_queue)
    end
  end

  # Accumulator stage - batches items before passing to consumer
  # Collects N items, then emits them as a batch
  class AccumulatorStage < ConsumerStage
    attr_reader :max_size, :max_wait

    def initialize(*args, name: nil, block: nil, options: {}, **kwargs)
      # Support both old and new signatures
      if args.length > 0 && args[0].is_a?(Pipeline)
        # New style: AccumulatorStage.new(pipeline, name, block, options)
        super(args[0], args[1], args[2], args[3] || {})
        opts = args[3] || {}
      else # REMOVE_THIS
        # Old style: AccumulatorStage.new(name: :foo, block: proc {}, options: {})
        super(name: name, block: block, options: options)
        opts = options
      end

      @max_size = opts[:max_size] || 100
      @max_wait = opts[:max_wait] || nil # Future: time-based batching
      @buffer = []
      @mutex = Mutex.new
    end

    # Override execute to buffer items and emit batches via output queue
    def execute(context, input_queue, output_queue, stage_stats)
      loop do
        item = input_queue.pop

        break if item.is_a?(EndOfStage)

        buffer = nil

        @mutex.synchronize do
          @buffer << item

          if @buffer.size >= @max_size
            buffer = @buffer.dup
            @buffer.clear
          end
        end

        next unless buffer && output_queue

        begin
          start_time = Time.now if stage_stats

          if @block
            # Accumulator block receives |batch, output| like other stages
            context.instance_exec(buffer, output_queue, &@block)
          else
            # No block - just pass through
            output_queue << buffer
          end

          # Record per-batch latency
          stage_stats&.record_latency(Time.now - start_time)
        rescue StandardError => e
          # Log batch-level errors but continue processing
          Minigun.logger.error "[Stage:#{name}] Error processing batch: #{e.message}"
          Minigun.logger.debug e.backtrace.join("\n") if Minigun.logger.debug?
        end
      end
    end

    # Called at end of pipeline to flush remaining items
    def flush(context, output_queue)
      buffer = nil

      @mutex.synchronize do
        if @buffer.any?
          buffer = @buffer.dup
          @buffer.clear
        end
      end

      return unless buffer && output_queue

      if @block
        # Accumulator block receives |batch, output| like other stages
        context.instance_exec(buffer, output_queue, &@block)
      else
        # No block - just pass through
        output_queue << buffer
      end
    end
  end

  # Router stages for fan-out patterns
  # Base functionality for all routers
  class RouterStage < Stage
    attr_accessor :targets

    def initialize(*args, name: nil, targets: nil, **kwargs)
      # Support both old and new signatures
      if args.length > 0 && args[0].is_a?(Pipeline)
        # New style: RouterStage.new(pipeline, name, targets, options)
        super(args[0], args[1], nil, args[3] || {})
        @targets = args[2] || []
      else # REMOVE_THIS
        # Old style: RouterStage.new(name: :foo, targets: [...])
        super(name: name, options: {})
        @targets = targets || []
      end
    end

    protected

    def send_end_signals(worker_ctx)
      # Broadcast EndOfSource to ALL router targets
      @targets.each do |target|
        worker_ctx.stage_input_queues[target] << EndOfSource.new(worker_ctx.stage)
      end
    end
  end

  # Broadcast router - sends each item to ALL downstream stages
  class RouterBroadcastStage < RouterStage
    def run_stage(worker_ctx)
      loop do
        item = worker_ctx.input_queue.pop

        if item.is_a?(EndOfSource)
          worker_ctx.sources_expected << item.source # Discover dynamic source
          worker_ctx.sources_done << item.source
          break if worker_ctx.sources_done == worker_ctx.sources_expected

          next
        end

        # Broadcast to all downstream stages (fan-out semantics)
        @targets.each do |target|
          worker_ctx.stage_input_queues[target] << item
        end
      end
    ensure
      send_end_signals(worker_ctx)
    end
  end

  # Round-robin router - distributes items across downstream stages
  class RouterRoundRobinStage < RouterStage
    def run_stage(worker_ctx)
      target_queues = @targets.map { |target| worker_ctx.stage_input_queues[target] }
      round_robin_index = 0

      loop do
        item = worker_ctx.input_queue.pop

        if item.is_a?(EndOfSource)
          worker_ctx.sources_expected << item.source # Discover dynamic source
          worker_ctx.sources_done << item.source
          break if worker_ctx.sources_done == worker_ctx.sources_expected

          next
        end

        # Round-robin to downstream stages
        target_queues[round_robin_index] << item
        round_robin_index = (round_robin_index + 1) % target_queues.size
      end
    ensure
      send_end_signals(worker_ctx)
    end
  end

  # Stage that wraps and executes a nested pipeline
  class PipelineStage < Stage
    attr_reader :nested_pipeline

    def initialize(*args, name: nil, options: {}, **kwargs)
      # Support both old and new signatures
      if args.length > 0 && args[0].is_a?(Pipeline)
        # New style: PipelineStage.new(pipeline, name, block, options)
        super(args[0], args[1], nil, args[3] || options)
      else # REMOVE_THIS
        # Old style: PipelineStage.new(name: :foo, options: {})
        super(name: name, options: options)
      end
      @nested_pipeline = nil
    end

    # REMOVE_THIS - Backward compatibility: pipeline reader returns nested_pipeline
    def pipeline
      @nested_pipeline
    end

    # Inject the nested pipeline instance
    def pipeline=(pipeline)
      @nested_pipeline = pipeline
    end

    def run_mode
      :composite # Manages internal stages
    end

    # Run the nested pipeline when this stage is executed as a worker
    def run_stage(stage_ctx)
      return unless @nested_pipeline

      # Set up input/output queues for the nested pipeline
      # The pipeline will create :_entrance and :_exit stages based on these
      if stage_ctx.sources_expected.any?
        # Has upstream: set input queue so pipeline creates :_entrance
        # Also pass the expected source count for proper END signal handling
        @nested_pipeline.instance_variable_set(:@input_queues, {
          input: stage_ctx.input_queue,
          sources_expected: stage_ctx.sources_expected
        })
      end

      # Always set output queue so pipeline creates :_exit
      @nested_pipeline.instance_variable_set(:@output_queues, { output: create_output_queue(stage_ctx) })

      # Run the nested pipeline (it will automatically create :_entrance/:_exit as needed)
      @nested_pipeline.run(stage_ctx.pipeline.context)
    ensure
      send_end_signals(stage_ctx)
    end
  end
end
