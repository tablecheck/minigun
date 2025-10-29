# frozen_string_literal: true

module Minigun
  # Unified context for all stage execution (producers and workers)
  StageContext = Struct.new(
    # Common to all stages
    :pipeline,
    :stage_name,
    :dag,
    :runtime_edges,
    :stage_input_queues,
    :stats,
    # Worker-specific (nil/empty for producers)
    :input_queue,
    :sources_expected,
    :sources_done,
    :executor,
    keyword_init: true
  )

  # Base class for all execution units (stages and pipelines)
  # Implements the Composite pattern where Pipeline is a composite Stage
  # Also handles loop-based stages (stages that manage their own input loop)
  class Stage
    attr_reader :name, :options, :block

    def initialize(name:, block: nil, options: {})
      @name = name
      @block = block
      @options = options
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
    def execute(context, input_queue: nil, output_queue: nil)
      if @block
        context.instance_exec(input_queue, output_queue, &@block)
      elsif respond_to?(:call)
        call_with_arity(input_queue, output_queue, &output_queue.to_proc)
      end
    end

    # Run the worker loop for loop-based stages
    # Loop-based stages manage their own input loop
    def run_worker_loop(stage_ctx)
      # Get stage stats for tracking
      stage_stats = stage_ctx.stats.for_stage(stage_ctx.stage_name, is_terminal: stage_ctx.dag.terminal?(stage_ctx.stage_name))

      # Create wrapped queues
      wrapped_input = InputQueue.new(stage_ctx.input_queue, stage_ctx.stage_name, stage_ctx.sources_expected)
      wrapped_output = OutputQueue.new(
        stage_ctx.stage_name,
        stage_ctx.dag.downstream(stage_ctx.stage_name).map { |ds| stage_ctx.stage_input_queues[ds] },
        stage_ctx.stage_input_queues,
        stage_ctx.runtime_edges,
        stage_stats: stage_stats
      )

      # Execute with both queues (block manages its own loop)
      context = stage_ctx.pipeline.context
      execute(context, input_queue: wrapped_input, output_queue: wrapped_output)

      # Send END signals to downstream
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

    def send_end_signals(stage_ctx)
      dag_downstream = stage_ctx.dag.downstream(stage_ctx.stage_name)
      dynamic_targets = stage_ctx.runtime_edges[stage_ctx.stage_name].to_a
      all_targets = (dag_downstream + dynamic_targets).uniq

      all_targets.each do |target|
        next unless stage_ctx.stage_input_queues[target]

        stage_ctx.stage_input_queues[target] << Message.end_signal(source: stage_ctx.stage_name)
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
    def execute(context, item: nil, input_queue: nil, output_queue: nil) # rubocop:disable Lint/UnusedMethodArgument
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

    def run_worker_loop(stage_ctx)
      stage_stats = stage_ctx.stats.for_stage(stage_ctx.stage_name, is_terminal: false)
      stage_stats.start!
      log_info(stage_ctx, 'Starting')

      begin
        # Execute before hooks
        execute_hooks(stage_ctx, :before)

        # Create output queue
        output_queue = create_output_queue(stage_ctx)

        # Execute producer block
        context = stage_ctx.pipeline.context
        execute(context, item: nil, input_queue: nil, output_queue: output_queue)

        # Execute after hooks
        execute_hooks(stage_ctx, :after)
      rescue StandardError => e
        log_error(stage_ctx, "Error: #{e.message}")
        log_error(stage_ctx, e.backtrace.join("\n"))
      ensure
        stage_stats.finish!
        log_info(stage_ctx, 'Done')
        send_end_signals(stage_ctx)
      end
    end

    private

    def create_output_queue(ctx)
      downstream = ctx.dag.downstream(ctx.stage_name)
      downstream_queues = downstream.filter_map { |to| ctx.stage_input_queues[to] }
      stage_stats = ctx.stats.for_stage(ctx.stage_name, is_terminal: ctx.dag.terminal?(ctx.stage_name))
      OutputQueue.new(ctx.stage_name, downstream_queues, ctx.stage_input_queues, ctx.runtime_edges, stage_stats: stage_stats)
    end

    def execute_hooks(ctx, type)
      ctx.pipeline.execute_stage_hooks(type, ctx.stage_name)
    end

    def send_end_signals(ctx)
      downstream = ctx.dag.downstream(ctx.stage_name)
      dynamic_targets = ctx.runtime_edges[ctx.stage_name].to_a
      all_targets = (downstream + dynamic_targets).uniq

      all_targets.each do |target|
        ctx.stage_input_queues[target] << Message.end_signal(source: ctx.stage_name)
      end
    end

    def log_info(ctx, msg)
      Minigun.logger.info "[Pipeline:#{ctx.pipeline.name}][Producer:#{ctx.stage_name}] #{msg}"
    end

    def log_error(ctx, msg)
      Minigun.logger.error "[Pipeline:#{ctx.pipeline.name}][Producer:#{ctx.stage_name}] #{msg}"
    end
  end

  # Consumer/Processor stage - loops on input, processes items
  class ConsumerStage < Stage
    def execute(context, item: nil, input_queue: nil, output_queue: nil) # rubocop:disable Lint/UnusedMethodArgument
      if @block
        context.instance_exec(item, output_queue, &@block)
      elsif respond_to?(:call)
        call_with_arity(item, output_queue, &output_queue.to_proc)
      end
    end

    def run_worker_loop(stage_ctx)
      # Get stage stats for tracking
      stage_stats = stage_ctx.stats.for_stage(stage_ctx.stage_name, is_terminal: stage_ctx.dag.terminal?(stage_ctx.stage_name))

      # Create wrapped queues
      InputQueue.new(stage_ctx.input_queue, stage_ctx.stage_name, stage_ctx.sources_expected)
      wrapped_output = OutputQueue.new(
        stage_ctx.stage_name,
        stage_ctx.dag.downstream(stage_ctx.stage_name).map { |ds| stage_ctx.stage_input_queues[ds] },
        stage_ctx.stage_input_queues,
        stage_ctx.runtime_edges,
        stage_stats: stage_stats
      )

      # Process items loop
      process_items(stage_ctx, wrapped_output)

      # Flush and cleanup
      flush_if_needed(stage_ctx, wrapped_output)
      send_end_signals(stage_ctx)
    end

    private

    def process_items(stage_ctx, wrapped_output)
      loop do
        msg = stage_ctx.input_queue.pop

        # Handle END signal
        if msg.is_a?(Message) && msg.end_of_stream?
          stage_ctx.sources_expected << msg.source
          stage_ctx.sources_done << msg.source
          break if stage_ctx.sources_done == stage_ctx.sources_expected

          next
        end

        # Execute item
        execute_item(stage_ctx, msg, wrapped_output)
      end
    end

    def execute_item(stage_ctx, item, wrapped_output)
      context = stage_ctx.pipeline.context
      stats = stage_ctx.stats

      stage_ctx.executor.execute_stage_item(
        stage: self,
        item: item,
        user_context: context,
        input_queue: nil,
        output_queue: wrapped_output,
        stats: stats,
        pipeline: stage_ctx.pipeline
      )
    end

    def flush_if_needed(stage_ctx, wrapped_output)
      return unless respond_to?(:flush)

      context = stage_ctx.pipeline.context
      flush(context, wrapped_output)
    end

    def send_end_signals(stage_ctx)
      dag_downstream = stage_ctx.dag.downstream(stage_ctx.stage_name)
      dynamic_targets = stage_ctx.runtime_edges[stage_ctx.stage_name].to_a
      all_targets = (dag_downstream + dynamic_targets).uniq

      all_targets.each do |target|
        next unless stage_ctx.stage_input_queues[target]

        stage_ctx.stage_input_queues[target] << Message.end_signal(source: stage_ctx.stage_name)
      end
    end
  end

  # Accumulator stage - batches items before passing to consumer
  # Collects N items, then emits them as a batch
  class AccumulatorStage < ConsumerStage
    attr_reader :max_size, :max_wait

    def initialize(name:, block: nil, options: {})
      super
      @max_size = options[:max_size] || 100
      @max_wait = options[:max_wait] || nil # Future: time-based batching
      @buffer = []
      @mutex = Mutex.new
    end

    # Override execute to buffer items and emit batches via output queue
    def execute(context, item: nil, input_queue: nil, output_queue: nil) # rubocop:disable Lint/UnusedMethodArgument
      return unless item

      batch_to_emit = nil

      @mutex.synchronize do
        @buffer << item

        if @buffer.size >= @max_size
          batch_to_emit = @buffer.dup
          @buffer.clear
        end
      end

      return unless batch_to_emit && output_queue

      if @block
        # Accumulator block receives |batch, output| like other stages
        context.instance_exec(batch_to_emit, output_queue, &@block)
      else
        # No block - just pass through
        output_queue << batch_to_emit
      end
    end

    # Called at end of pipeline to flush remaining items
    def flush(context, output_queue)
      batch_to_emit = nil

      @mutex.synchronize do
        if @buffer.any?
          batch_to_emit = @buffer.dup
          @buffer.clear
        end
      end

      return unless batch_to_emit && output_queue

      if @block
        # Accumulator block receives |batch, output| like other stages
        context.instance_exec(batch_to_emit, output_queue, &@block)
      else
        # No block - just pass through
        output_queue << batch_to_emit
      end
    end
  end

  # Router stages for fan-out patterns
  # Base functionality for all routers
  class RouterStage < Stage
    attr_accessor :targets

    def initialize(name:, targets:)
      super(name: name, options: {})
      @targets = targets
    end

    def execute(_context, item)
      # Router doesn't transform, just passes through
      [item]
    end

    protected

    def send_end_signals(worker_ctx)
      # Broadcast END to ALL router targets
      @targets.each do |target|
        worker_ctx.stage_input_queues[target] << Message.end_signal(source: worker_ctx.stage_name)
      end
    end
  end

  # Broadcast router - sends each item to ALL downstream stages
  class RouterBroadcastStage < RouterStage
    def run_worker_loop(worker_ctx)
      loop do
        msg = worker_ctx.input_queue.pop

        # Handle END signal
        if msg.is_a?(Message) && msg.end_of_stream?
          worker_ctx.sources_expected << msg.source # Discover dynamic source
          worker_ctx.sources_done << msg.source
          break if worker_ctx.sources_done == worker_ctx.sources_expected

          next
        end

        # Broadcast to all downstream stages (fan-out semantics)
        @targets.each do |target|
          worker_ctx.stage_input_queues[target] << msg
        end
      end

      send_end_signals(worker_ctx)
    end
  end

  # Round-robin router - distributes items across downstream stages
  class RouterRoundRobinStage < RouterStage
    def run_worker_loop(worker_ctx)
      target_queues = @targets.map { |target| worker_ctx.stage_input_queues[target] }
      round_robin_index = 0

      loop do
        msg = worker_ctx.input_queue.pop

        # Handle END signal
        if msg.is_a?(Message) && msg.end_of_stream?
          worker_ctx.sources_expected << msg.source # Discover dynamic source
          worker_ctx.sources_done << msg.source
          break if worker_ctx.sources_done == worker_ctx.sources_expected

          next
        end

        # Round-robin to downstream stages
        target_queues[round_robin_index] << msg
        round_robin_index = (round_robin_index + 1) % target_queues.size
      end

      send_end_signals(worker_ctx)
    end
  end

  # Stage that wraps and executes a nested pipeline
  class PipelineStage < Stage
    attr_reader :pipeline, :stages_to_add

    def initialize(name:, options: {})
      super

      # PipelineStage wraps a Pipeline instance for execution
      # We'll inject the pipeline later when we have the config
      @pipeline = nil
      @stages_to_add = [] # Queue of stages to add when pipeline is created
      @temp_collector = nil # Track temp collector stage if added
    end

    def run_mode
      :composite # Manages internal stages
    end

    # Execute method for when PipelineStage is used as a processor/consumer
    def execute(context, item: nil, input_queue: nil, output_queue: nil) # rubocop:disable Lint/UnusedMethodArgument
      # If no pipeline set, just pass item through
      unless @pipeline
        output_queue << item if output_queue && item
        return
      end

      # If used as producer (no item), run the nested pipeline and collect outputs
      if item.nil?
        execute_as_producer(context, output_queue)
        return
      end

      # Process item through the pipeline's stages sequentially (in-process, no full pipeline infrastructure)
      current_items = [item]

      @pipeline.stages.each_value do |stage|
        # Only feed to streaming stages
        next unless stage.run_mode == :streaming

        break if current_items.empty?

        next_items = []
        current_items.each do |current_item|
          # Create a temporary output queue for this stage
          stage_output = []
          stage_output.define_singleton_method(:<<) do |i|
            push(i)
            self
          end

          # Execute stage with temporary output queue
          stage.execute(context, item: current_item, output_queue: stage_output)

          # Collect outputs
          next_items.concat(stage_output)
        end
        current_items = next_items
      end

      # Output final results to output queue
      current_items.each { |result_item| output_queue << result_item } if output_queue
    end

    # Run the worker loop for pipeline stages
    def run_worker_loop(stage_ctx)
      # Check if this PipelineStage is acting as a producer (no upstream)
      if stage_ctx.sources_expected.empty?
        # Producer mode: run the nested pipeline once
        stage_stats = stage_ctx.stats.for_stage(stage_ctx.stage_name, is_terminal: stage_ctx.dag.terminal?(stage_ctx.stage_name))
        wrapped_output = OutputQueue.new(
          stage_ctx.stage_name,
          stage_ctx.dag.downstream(stage_ctx.stage_name).map { |ds| stage_ctx.stage_input_queues[ds] },
          stage_ctx.stage_input_queues,
          stage_ctx.runtime_edges,
          stage_stats: stage_stats
        )

        context = stage_ctx.pipeline.context
        execute(context, item: nil, input_queue: nil, output_queue: wrapped_output)

        # Send END signals to downstream
        dag_downstream = stage_ctx.dag.downstream(stage_ctx.stage_name)
        dynamic_targets = stage_ctx.runtime_edges[stage_ctx.stage_name].to_a
        all_targets = (dag_downstream + dynamic_targets).uniq

        all_targets.each do |target|
          next unless stage_ctx.stage_input_queues[target]

          stage_ctx.stage_input_queues[target] << Message.end_signal(source: stage_ctx.stage_name)
        end
        return
      end

      # Consumer mode: process items from upstream
      stage_stats = stage_ctx.stats.for_stage(stage_ctx.stage_name, is_terminal: stage_ctx.dag.terminal?(stage_ctx.stage_name))
      InputQueue.new(stage_ctx.input_queue, stage_ctx.stage_name, stage_ctx.sources_expected)
      wrapped_output = OutputQueue.new(
        stage_ctx.stage_name,
        stage_ctx.dag.downstream(stage_ctx.stage_name).map { |ds| stage_ctx.stage_input_queues[ds] },
        stage_ctx.stage_input_queues,
        stage_ctx.runtime_edges,
        stage_stats: stage_stats
      )

      # Traditional item-by-item processing
      loop do
        msg = stage_ctx.input_queue.pop

        # Handle END signal
        if msg.is_a?(Message) && msg.end_of_stream?
          stage_ctx.sources_expected << msg.source # Discover dynamic source
          stage_ctx.sources_done << msg.source
          break if stage_ctx.sources_done == stage_ctx.sources_expected

          next
        end

        # Execute the stage with queue wrappers
        context = stage_ctx.pipeline.context
        stats = stage_ctx.stats

        stage_ctx.executor.execute_stage_item(
          stage: self,
          item: msg,
          user_context: context,
          input_queue: nil,
          output_queue: wrapped_output,
          stats: stats,
          pipeline: stage_ctx.pipeline
        )
      end

      # Send END signals
      dag_downstream = stage_ctx.dag.downstream(stage_ctx.stage_name)
      dynamic_targets = stage_ctx.runtime_edges[stage_ctx.stage_name].to_a
      all_targets = (dag_downstream + dynamic_targets).uniq

      all_targets.each do |target|
        # Skip if target doesn't have an input queue (e.g., producers)
        next unless stage_ctx.stage_input_queues[target]

        stage_ctx.stage_input_queues[target] << Message.end_signal(source: stage_ctx.stage_name)
      end
    end

    # Execute as a producer - run the nested pipeline and collect its outputs
    def execute_as_producer(context, output_queue)
      # Collect all items produced by the nested pipeline
      collected_items = []

      # Add a temporary consumer to collect items if not already present
      if @temp_collector.nil?
        @pipeline.instance_eval do
          add_stage(:stage, :_temp_collector, stage_type: :consumer) do |item, _output|
            collected_items << item
          end
        end
        @temp_collector = @pipeline.stages[:_temp_collector]
      end

      # Run the nested pipeline
      @pipeline.run(context)

      # Send collected items to parent output queue
      collected_items.each { |item| output_queue << item } if output_queue

      # Clean up temporary collector
      return unless @temp_collector

      @pipeline.stages.delete(:_temp_collector)
      @temp_collector = nil
    end

    # Set the wrapped pipeline (called by Task)
    def pipeline=(pipeline)
      @pipeline = pipeline

      # Add any queued stages
      @stages_to_add.each do |stage_info|
        @pipeline.add_stage(stage_info[:type], stage_info[:name], stage_info[:options], &stage_info[:block])
      end
      @stages_to_add.clear
    end

    # Add a child stage to this pipeline
    def add_stage(type, name, options = {}, &block)
      if @pipeline
        @pipeline.add_stage(type, name, options, &block)
      else
        # Queue for later when pipeline is set
        @stages_to_add << { type: type, name: name, options: options, block: block }
      end
    end
  end
end
