# frozen_string_literal: true

module Minigun
  # Execution strategies for running pipeline stages
  module Execution
    # Base executor class - all execution strategies inherit from this
    # Executors handle stage execution including hooks, stats, and error handling
    class Executor
      # Execute a stage item with queue-based routing
      # @param stage [Stage] The stage to execute
      # @param item [Object] The item to process
      # @param user_context [Object] The user's pipeline context
      # @param input_queue [InputQueue] Wrapped input queue for the stage
      # @param output_queue [OutputQueue] Wrapped output queue for the stage
      # @param stats [Stats] The stats object for tracking
      # @param pipeline [Pipeline] The pipeline instance (for hooks)
      def execute_stage_item(stage:, item:, user_context:, stats:, pipeline:, input_queue: nil, output_queue: nil)
        # Check if stage is terminal
        dag = pipeline.dag
        is_terminal = dag.terminal?(stage.name)
        stage_stats = stats.for_stage(stage.name, is_terminal: is_terminal)
        stage_stats.start! unless stage_stats.start_time
        start_time = Time.now

        # Execute before hooks for this stage
        pipeline.send(:execute_stage_hooks, :before, stage.name)

        # Track consumption of input item
        stage_stats.increment_consumed if item

        # Execute the stage using this executor's strategy
        execute_with_strategy(stage, item, user_context, pipeline, input_queue, output_queue)

        # Record latency
        duration = Time.now - start_time
        stage_stats.record_latency(duration)

        # Execute after hooks for this stage
        pipeline.send(:execute_stage_hooks, :after, stage.name)
      rescue StandardError => e
        Minigun.logger.error "[Pipeline:#{pipeline.name}][Stage:#{stage.name}] Error: #{e.message}"
        Minigun.logger.error e.backtrace.join("\n")
      end

      # Shutdown and cleanup resources
      def shutdown
        # Default: no-op
      end

      protected

      # Execute the actual stage logic using this executor's strategy
      # Subclasses implement this to control HOW execution happens
      def execute_with_strategy(stage, item, user_context, pipeline, input_queue, output_queue)
        raise NotImplementedError, "#{self.class}#execute_with_strategy must be implemented"
      end

      # Run the stage's actual processing logic with queues
      def run_stage_logic(stage, item, user_context, input_queue, output_queue)
        stage.execute(user_context, item: item, input_queue: input_queue, output_queue: output_queue)
      end
    end

    # Inline execution - no concurrency, executes immediately in current thread
    class InlineExecutor < Executor
      protected

      def execute_with_strategy(stage, item, user_context, _pipeline, input_queue, output_queue)
        run_stage_logic(stage, item, user_context, input_queue, output_queue)
      end
    end

    # Thread pool executor - manages concurrent execution with threads
    class ThreadPoolExecutor < Executor
      attr_reader :max_size

      def initialize(max_size:)
        super()
        @max_size = max_size
        @active_threads = []
        @mutex = Mutex.new
      end

      def shutdown
        @mutex.synchronize { @active_threads.dup }.each do |thread|
          thread.kill if thread.alive?
        end
        @active_threads.clear
      end

      protected

      def execute_with_strategy(stage, item, user_context, _pipeline, input_queue, output_queue)
        wait_for_slot

        thread = Thread.new do
          run_stage_logic(stage, item, user_context, input_queue, output_queue)
        ensure
          @mutex.synchronize { @active_threads.delete(Thread.current) }
        end

        @mutex.synchronize { @active_threads << thread }
        thread.value # Wait for completion
      end

      private

      def wait_for_slot
        loop do
          return if @mutex.synchronize { @active_threads.size } < @max_size

          sleep 0.01
        end
      end
    end

    # Process pool executor - manages forked process execution
    class ProcessPoolExecutor < Executor
      attr_reader :max_size

      def initialize(max_size:)
        super()
        @max_size = max_size
        @active_pids = []
        @mutex = Mutex.new
      end

      def shutdown
        @mutex.synchronize { @active_pids.dup }.each do |pid|
          Process.kill('TERM', pid)
        rescue StandardError
          nil
        end
        @active_pids.clear
      end

      protected

      def execute_with_strategy(stage, item, user_context, _pipeline, input_queue, output_queue)
        unless Process.respond_to?(:fork)
          warn '[Minigun] Process forking not available, falling back to inline'
          return run_stage_logic(stage, item, user_context, input_queue, output_queue)
        end

        # NOTE: Queue-based DSL doesn't work with process pools since queues can't cross process boundaries
        # This would require implementing IPC for queue operations
        # For now, process pools execute stages but can't properly route via queues
        raise NotImplementedError, 'Process pools are not yet compatible with queue-based DSL. Use threads or inline execution.'

        # Keeping old implementation commented for reference
        # wait_for_slot
        #
        # # Execute before_fork hooks
        # execute_fork_hooks(:before_fork, stage, pipeline)
        #
        # reader, writer = IO.pipe
        # pid = fork do
        #   reader.close
        #
        #   # Execute after_fork hooks in child
        #   execute_fork_hooks(:after_fork, stage, pipeline)
        #
        #   begin
        #     run_stage_logic(stage, item, user_context, input_queue, output_queue)
        #     Marshal.dump(:success, writer)
        #   rescue => e
        #     Marshal.dump({ error: e }, writer)
        #   ensure
        #     writer.close
        #   end
        # end
        #
        # writer.close
        # @mutex.synchronize { @active_pids << pid }
        #
        # # Wait for child
        # Process.wait(pid)
        # result = Marshal.load(reader) rescue nil
        # reader.close
        #
        # @mutex.synchronize { @active_pids.delete(pid) }
        #
        # if result.is_a?(Hash) && result[:error]
        #   raise result[:error]
        # end
      end

      private

      def wait_for_slot
        loop do
          return if @mutex.synchronize { @active_pids.size } < @max_size

          sleep 0.01
        end
      end

      def execute_fork_hooks(hook_type, stage, pipeline)
        user_context = pipeline.context
        stage_hooks = pipeline.stage_hooks

        # Pipeline-level fork hooks
        hooks = pipeline.hooks[hook_type] || []
        hooks.each { |h| user_context.instance_eval(&h) }

        # Stage-specific fork hooks
        stage_hooks_list = stage_hooks.dig(hook_type, stage.name) || []
        stage_hooks_list.each { |h| user_context.instance_exec(&h) }
      end
    end

    # Ractor pool executor - manages ractor execution
    class RactorPoolExecutor < Executor
      def initialize(max_size:)
        super()
        @max_size = max_size
        @fallback = ThreadPoolExecutor.new(max_size: max_size)
      end

      protected

      def execute_with_strategy(stage, item, user_context, pipeline, input_queue, output_queue)
        unless defined?(::Ractor)
          warn '[Minigun] Ractors not available, falling back to thread pool'
          return @fallback.send(:execute_with_strategy, stage, item, user_context, pipeline, input_queue, output_queue)
        end

        # NOTE: Ractors have similar IPC challenges as process pools
        # Fall back to threads for now
        @fallback.send(:execute_with_strategy, stage, item, user_context, pipeline, input_queue, output_queue)
      end
    end

    # Factory for creating executors
    def self.create_executor(type:, max_size:)
      case type
      when :inline
        InlineExecutor.new
      when :thread
        ThreadPoolExecutor.new(max_size: max_size)
      when :fork
        ProcessPoolExecutor.new(max_size: max_size)
      when :ractor
        RactorPoolExecutor.new(max_size: max_size)
      else
        raise ArgumentError, "Unknown executor type: #{type}"
      end
    end
  end
end
