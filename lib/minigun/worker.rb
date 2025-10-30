# frozen_string_literal: true

module Minigun
  # Unified worker for all stage types (producers and consumers)
  # Manages thread lifecycle and delegates to stage.run_stage()
  class Worker
    attr_reader :thread, :stage_name, :stage, :executor

    def initialize(pipeline, stage, config = {})
      @pipeline = pipeline
      @stage = stage
      @stage_name = stage.name
      @config = config
      @thread = nil
      @executor = nil # Created later in create_stage_context
    end

    # Start the worker thread
    def start
      @thread = Thread.new { run }
    end

    # Wait for worker to complete
    def join
      @thread&.join
    end

    private

    def run
      log_debug 'Starting'

      stage_ctx = create_stage_context

      # Create executor with stage_ctx (only for non-autonomous stages)
      @executor = create_executor_if_needed(stage_ctx)

      # Check for disconnected stages (no upstream, not a producer, not a PipelineStage)
      return if handle_disconnected_stage(stage_ctx)

      stage_stats = stage_ctx.stage_stats
      stage_stats.start!
      log_debug('Starting')

      @stage.run_stage(stage_ctx)

      stage_ctx.stage_stats.finish!
      log_debug('Done')
    rescue StandardError => e
      log_error "Unhandled error: #{e.message}"
      log_error e.backtrace.join("\n")
    ensure
      @executor&.shutdown
    end

    def handle_disconnected_stage(stage_ctx) # rubocop:disable Naming/PredicateMethod
      # Only check streaming stages (autonomous and composite manage their own execution)
      return false unless @stage.run_mode == :streaming

      # If no upstream sources, this stage is disconnected
      if stage_ctx.sources_expected.empty?
        log_debug 'No upstream sources, sending END signals and exiting'

        # Send EndOfSource to all downstream stages so they don't deadlock
        downstream = stage_ctx.dag.downstream(stage_ctx.stage_name)
        downstream.each do |target|
          stage_ctx.stage_input_queues[target] << EndOfSource.new(stage_ctx.stage_name)
        end

        log_debug 'Done'
        return true
      end

      false
    end

    def create_stage_context
      dag = @pipeline.dag
      stage_input_queues = @pipeline.stage_input_queues

      # Calculate sources for workers (empty for autonomous stages)
      sources_expected = if @stage.run_mode == :autonomous
                           Set.new
                         elsif @stage_name == :_entrance && @pipeline.input_queues
                           # For :_entrance, use sources from parent pipeline if available
                           @pipeline.input_queues[:sources_expected] || Set.new
                         else
                           Set.new(dag.upstream(@stage_name))
                         end

      # Create stats object for this specific stage
      is_terminal = dag.terminal?(@stage_name)
      stage_stats = @pipeline.stats.for_stage(@stage_name, is_terminal: is_terminal)

      StageContext.new(
        worker: self,
        pipeline: @pipeline,
        stage_name: @stage_name,
        dag: dag,
        runtime_edges: @pipeline.runtime_edges,
        stage_input_queues: stage_input_queues,
        stage_stats: stage_stats,
        # Worker-specific (nil/empty for producers)
        input_queue: stage_input_queues[@stage_name],
        sources_expected: sources_expected,
        sources_done: Set.new
      )
    end

    def create_executor_if_needed(stage_ctx)
      return nil if @stage.run_mode == :autonomous

      exec_ctx = @stage.execution_context
      return Execution::InlineExecutor.new(stage_ctx) if exec_ctx.nil?

      type = exec_ctx[:type]
      pool_size = exec_ctx[:pool_size] || exec_ctx[:max] || default_pool_size(type)

      Execution.create_executor(type, stage_ctx, max_size: pool_size)
    end

    # TODO: Move this elsewhere? DSL class?
    def default_pool_size(type)
      case type
      when :thread then @config[:max_threads] || 5
      when :cow_fork then @config[:max_processes] || 2
      when :ractor then @config[:max_ractors] || 4
      else 5
      end
    end

    def log_debug(msg)
      Minigun.logger.debug "[Pipeline:#{@pipeline.name}][#{@stage.log_type}:#{@stage_name}] #{msg}"
    end

    def log_error(msg)
      Minigun.logger.error "[Pipeline:#{@pipeline.name}][#{@stage.log_type}:#{@stage_name}] #{msg}"
    end
  end
end
