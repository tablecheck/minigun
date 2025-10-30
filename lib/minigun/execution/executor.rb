# frozen_string_literal: true

module Minigun
  # Execution strategies for running pipeline stages
  module Execution
    # Base executor class - all execution strategies inherit from this
    # NOTE: Stages now manage their own execution loops internally via execute(context, input_queue, output_queue).
    # Executors define HOW that execution happens (inline, threaded, etc).
    class Executor
      attr_reader :stage_ctx

      def initialize(stage_ctx)
        @stage_ctx = stage_ctx
      end

      # Execute the actual stage logic using this executor's strategy
      # Subclasses implement this to control HOW execution happens
      # @param stage [Stage] The stage to execute
      # @param user_context [Object] User context for instance_exec
      # @param input_queue [Queue] Input queue for items
      # @param output_queue [Queue] Output queue for results
      def execute_stage(stage, user_context, input_queue, output_queue)
        raise NotImplementedError, "#{self.class}#execute_stage must be implemented"
      end

      # Shutdown and cleanup resources
      def shutdown
        # Default: no-op
      end
    end

    # Inline execution - no concurrency, executes immediately in current thread
    class InlineExecutor < Executor
      def execute_stage(stage, user_context, input_queue, output_queue)
        stage.execute(user_context, input_queue, output_queue, @stage_ctx.stage_stats)
      end
    end

    # Thread pool executor - manages concurrent execution with threads
    class ThreadPoolExecutor < Executor
      attr_reader :max_size

      def initialize(stage_ctx, max_size: nil)
        super(stage_ctx)
        @max_size = max_size || 5
        @active_threads = []
        @mutex = Mutex.new
      end

      def execute_stage(stage, user_context, input_queue, output_queue)
        wait_for_slot

        thread = Thread.new do
          stage.execute(user_context, input_queue, output_queue, @stage_ctx.stage_stats)
        ensure
          @mutex.synchronize { @active_threads.delete(Thread.current) }
        end

        @mutex.synchronize { @active_threads << thread }
        thread.value # Wait for completion
      end

      def shutdown
        @mutex.synchronize { @active_threads.dup }.each do |thread|
          thread.kill if thread.alive?
        end
        @active_threads.clear
      end

      private

      def wait_for_slot
        loop do
          return if @mutex.synchronize { @active_threads.size } < @max_size

          sleep 0.01
        end
      end
    end

    # Abstract base class for fork-based executors
    # Handles common IPC result communication logic
    class AbstractForkExecutor < Executor
      attr_reader :max_size

      def initialize(stage_ctx, max_size: nil)
        super(stage_ctx)
        @max_size = max_size || 5
        @mutex = Mutex.new
      end

      protected

      # Write result from child to parent via IPC pipe
      def write_result_to_pipe(result, writer)
        if result.nil?
          Marshal.dump({ type: :no_result }, writer)
        else
          Marshal.dump({ type: :result, result: result }, writer)
        end
        writer.flush
      end

      # Read result from child via IPC pipe
      def read_result_from_pipe(reader, output_queue)
        response = Marshal.load(reader)
        case response[:type]
        when :result
          result = response[:result]
          # Handle arrays of results (multiple items written to output_queue)
          if result.is_a?(Array)
            result.each { |item| output_queue << item }
          elsif !result.nil?
            output_queue << result
          end
        when :error
          error_msg = response[:error] || "Unknown error in forked process"
          backtrace = response[:backtrace]
          exception = RuntimeError.new("COW forked process failed: #{error_msg}")
          exception.set_backtrace(backtrace) if backtrace
          raise exception
        when :serialization_error
          # Result couldn't be serialized (contains IO, Proc, etc.)
          # Log warning but continue - item is skipped
          warn "[Minigun] Skipped non-serializable result: #{response[:error]} (type: #{response[:item_type]})"
        when :no_result
          # Child processed but produced no output
        end
      rescue EOFError
        # Normal EOF - worker finished processing, re-raise to exit collection loop
        raise
      rescue IOError => e
        warn "[Minigun] Error reading from pipe: #{e.message}"
        raise
      end

      # Send error from child to parent via IPC pipe
      def write_error_to_pipe(error, writer)
        Marshal.dump({
          type: :error,
          error: error.message,
          backtrace: error.backtrace
        }, writer)
        writer.flush
      end
    end

    # COW Fork Pool Executor - Copy-On-Write fork pattern
    # Maintains a pool of up to max_size concurrent forked processes.
    # Each forked process handles ONE item then exits.
    # Memory pages are shared between parent and child until modified (COW).
    # Input item is COW-shared, but results are sent via IPC pipes.
    class CowForkPoolExecutor < AbstractForkExecutor
      def initialize(stage_ctx, max_size:)
        super(stage_ctx, max_size: max_size)
        @active_forks = {} # pid => fork_info
      end

      def execute_stage(stage, user_context, input_queue, output_queue)
        unless Process.respond_to?(:fork)
          warn '[Minigun] Process forking not available, falling back to inline'
          return stage.execute(user_context, input_queue, output_queue, @stage_ctx.stage_stats)
        end

        # Execute before_fork hooks in parent process (once, before any forks)
        # This executes both pipeline-level and stage-specific hooks
        @stage_ctx.pipeline&.send(:execute_fork_hooks, :before_fork, stage.name)

        all_items_queued = false

        # Main loop: fork a process for each item as it arrives
        loop do
          # Reap any completed child processes (non-blocking)
          reap_completed_forks

          # If we have capacity and items remaining, fork for next item
          if !all_items_queued && current_active_count < @max_size
            item = input_queue.pop

            if item.is_a?(Minigun::EndOfStage)
              all_items_queued = true
            else
              # Fork a process for this single item (COW-shared)
              fork_for_item(item, stage, user_context, output_queue)
            end
          end

          # Break when all items processed and no active forks
          break if all_items_queued && current_active_count == 0

          # Small sleep to avoid busy waiting
          sleep 0.001 if current_active_count > 0
        end
      end

      def shutdown
        @mutex.synchronize { @active_forks.keys.dup }.each do |pid|
          Process.kill('TERM', pid)
        rescue StandardError
          nil
        end
        @active_forks.clear
      end

      private

      def current_active_count
        @mutex.synchronize { @active_forks.size }
      end

      def fork_for_item(item, stage, user_context, output_queue)
        # Create pipe for IPC communication (results only - item is COW-shared)
        reader, writer = IO.pipe

        stage_stats = @stage_ctx.stage_stats
        pipeline = @stage_ctx.pipeline

        # Fork child process - item is COW-shared (read-only, no copy until modified)
        pid = fork do
          reader.close # Close read end in child

          begin
            # Execute after_fork hooks in child process
            # This executes both pipeline-level and stage-specific hooks
            pipeline&.send(:execute_fork_hooks, :after_fork, stage.name)

            # Child process has inherited item via COW
            # Execute the stage's block on this single item
            # Create a capture queue to collect results written to output_queue
            capture_queue = Queue.new
            capture_output = Minigun::OutputQueue.new(
              stage.name,
              [capture_queue],
              {},
              {},
              stage_stats: stage_stats
            )

            # Execute stage block with item and capture output queue
            start_time = Time.now if stage_stats
            if stage.respond_to?(:block) && stage.block
              user_context.instance_exec(item, capture_output, &stage.block)
            elsif stage.respond_to?(:call)
              stage.call_with_arity(item, capture_output, &capture_output.to_proc)
            end
            stage_stats&.record_latency(Time.now - start_time) if stage_stats

            # Collect all results written to capture queue
            results = []
            loop do
              result = capture_queue.pop(true)  # non_block = true
              results << result
            rescue ThreadError
              break
            end

            # Send first result (or nil if none) back to parent via IPC pipe
            # For multiple results, we send them as an array
            result_to_send = results.size == 1 ? results.first : (results.empty? ? nil : results)
            write_result_to_pipe(result_to_send, writer)
          rescue => e
            # Send error back to parent via IPC
            write_error_to_pipe(e, writer)
            warn "[Minigun] Error in COW forked process: #{e.message}"
            warn e.backtrace.join("\n")
          ensure
            writer.close
            exit! 0
          end
        end

        if !pid
          reader.close
          writer.close
          warn '[Minigun] Failed to fork process, falling back to inline'
          # Fall back to processing inline for this item
          capture_queue = Queue.new
          capture_output = Minigun::OutputQueue.new(
            stage.name,
            [capture_queue],
            {},
            {},
            stage_stats: stage_stats
          )
          if stage.respond_to?(:block) && stage.block
            user_context.instance_exec(item, capture_output, &stage.block)
          elsif stage.respond_to?(:call)
            stage.call_with_arity(item, capture_output, &capture_output.to_proc)
          end
          # Write captured results to output_queue
          loop do
            result = capture_queue.pop(true)  # non_block = true
            output_queue << result
          rescue ThreadError
            break
          end
          return
        end

        writer.close # Close write end in parent

        @mutex.synchronize { @active_forks[pid] = { reader: reader, output_queue: output_queue } }
      end

      def reap_completed_forks
        @mutex.synchronize do
          @active_forks.keys.each do |pid|
            status = Process.wait2(pid, Process::WNOHANG)
            next unless status

            _pid, process_status = status
            fork_info = @active_forks.delete(pid)
            reader = fork_info[:reader]
            output_queue = fork_info[:output_queue]

            begin
              if process_status.success?
                # Read result from child via IPC pipe
                read_result_from_pipe(reader, output_queue)
              else
                warn "[Minigun] COW forked process #{pid} failed with status: #{process_status.exitstatus}"
              end
            ensure
              reader.close rescue nil
            end
          end
        end
      end
    end

    # IPC Fork Pool Executor - Inter-Process Communication fork pattern
    # Creates persistent worker processes that communicate via IPC pipes.
    # Workers continuously pull items, process them, and send results back.
    # Data is serialized through pipes for both input and output, providing strong process isolation.
    class IpcForkPoolExecutor < AbstractForkExecutor
      def initialize(stage_ctx, max_size:)
        super(stage_ctx, max_size: max_size)
        @workers = []
      end

      def execute_stage(stage, user_context, input_queue, output_queue)
        unless Process.respond_to?(:fork)
          warn '[Minigun] Process forking not available, falling back to inline'
          return stage.execute(user_context, input_queue, output_queue, @stage_ctx.stage_stats)
        end

        # Execute before_fork hooks in parent process (before spawning workers)
        # This executes both pipeline-level and stage-specific hooks
        @stage_ctx.pipeline&.send(:execute_fork_hooks, :before_fork, stage.name)

        # Spawn persistent worker processes
        spawn_workers(stage, user_context)

        # Distribute items to workers
        begin
          distribute_work(input_queue, output_queue)
        ensure
          shutdown
        end
      end

      def shutdown
        @mutex.synchronize do
          @workers.each do |worker|
            begin
              # Send shutdown signal (as end_of_stage so IpcInputQueue handles it)
              Marshal.dump({ type: :end_of_stage }, worker[:to_worker])
              worker[:to_worker].flush
            rescue IOError, EOFError, Errno::EPIPE
              # Worker already closed or pipe broken, ignore
            end
          end

          # Give workers a moment to finish processing
          sleep 0.1

          @workers.each do |worker|
            begin
              # Close pipes
              worker[:to_worker].close rescue nil
              worker[:from_worker].close rescue nil

              # Wait for worker to exit (non-blocking)
              begin
                Process.wait2(worker[:pid], Process::WNOHANG)
              rescue Errno::ECHILD
                # Already reaped
              end
            rescue => e
              # Force kill if graceful shutdown fails
              Process.kill('TERM', worker[:pid]) rescue nil
            end
          end
          @workers.clear
        end
      end

      private

      def spawn_workers(stage, user_context)
        stage_stats = @stage_ctx.stage_stats
        pipeline = @stage_ctx.pipeline

        @max_size.times do
          # Create bidirectional pipes for IPC
          parent_read, child_write = IO.pipe
          child_read, parent_write = IO.pipe

          pid = fork do
            # Worker process - close parent ends
            parent_read.close
            parent_write.close

            worker_loop(stage, user_context, stage_stats, child_read, child_write, pipeline)
          end

          if !pid
            warn '[Minigun] Failed to fork worker process'
            parent_read.close
            parent_write.close
            child_read.close
            child_write.close
            next
          end

          # Parent process - close child ends
          child_read.close
          child_write.close

          @workers << {
            pid: pid,
            to_worker: parent_write,
            from_worker: parent_read
          }
        end
      end

      def worker_loop(stage, user_context, stage_stats, from_parent, to_parent, pipeline)
        # Execute after_fork hooks in child process
        # This executes both pipeline-level and stage-specific hooks
        pipeline&.send(:execute_fork_hooks, :after_fork, stage.name)

        # Create IPC-backed input queue that reads from parent via IPC
        ipc_input_queue = Minigun::IpcInputQueue.new(from_parent, stage.name)

        # Create IPC-backed output queue that writes results back to parent via IPC
        ipc_output_queue = Minigun::IpcOutputQueue.new(to_parent, stage_stats)

        begin
          # Run the stage's execute method with IPC-backed queues
          # This runs the full streaming loop in the worker process
          stage.execute(user_context, ipc_input_queue, ipc_output_queue, stage_stats)
        rescue => e
          # Send error back to parent via IPC pipe
          write_error_to_pipe(e, to_parent)
        end
      rescue EOFError, IOError
        # Parent closed pipe, exit gracefully
      ensure
        from_parent.close rescue nil
        to_parent.close rescue nil
        exit! 0
      end

      def distribute_work(input_queue, output_queue)
        worker_index = 0
        result_threads = []

        # Start result collection threads for each worker
        @workers.each do |worker|
          result_threads << Thread.new do
            begin
              loop do
                read_result_from_pipe(worker[:from_worker], output_queue)
              end
            rescue EOFError, IOError => e
              # Worker closed pipe, done (suppress warnings for normal EOF)
              # Only warn if it's not a normal EOF
              warn "[Minigun] Worker #{worker[:pid]} pipe closed: #{e.message}" unless e.is_a?(EOFError)
            end
          end
        end

        # Distribute items to workers round-robin
        begin
          loop do
            item = input_queue.pop

            if item.is_a?(Minigun::EndOfStage)
              # Send EndOfStage to all workers
              @workers.each do |worker|
                begin
                  Marshal.dump({ type: :end_of_stage }, worker[:to_worker])
                  worker[:to_worker].flush
                rescue IOError, EOFError
                  # Worker already closed, ignore
                end
              end
              break
            end

            # Round-robin distribution to workers
            worker = @workers[worker_index % @workers.size]
            worker_index += 1

            # Send item to worker via IPC
            begin
              Marshal.dump({ type: :item, item: item }, worker[:to_worker])
              worker[:to_worker].flush
            rescue TypeError, ArgumentError => e
              # Item contains non-serializable objects - skip it
              warn "[Minigun] Cannot serialize item for IPC worker: #{e.message}. Item type: #{item.class}. Skipping."
            rescue IOError, EOFError => e
              warn "[Minigun] Lost connection to worker #{worker[:pid]}: #{e.message}"
              raise
            end
          end
        ensure
          # Wait for all result collection threads to finish
          result_threads.each(&:join)
        end
      end
    end

    # Ractor pool executor - manages ractor execution
    class RactorPoolExecutor < Executor
      def initialize(stage_ctx, max_size: nil)
        super(stage_ctx)
        @max_size = max_size || 5
        @fallback = ThreadPoolExecutor.new(stage_ctx, max_size: max_size)
      end

      def execute_stage(stage, user_context, input_queue, output_queue)
        unless defined?(::Ractor)
          warn '[Minigun] Ractors not available, falling back to thread pool'
          return @fallback.execute_stage(stage, user_context, input_queue, output_queue)
        end

        # NOTE: Ractors have similar IPC challenges as process pools
        # Fall back to threads for now
        @fallback.execute_stage(stage, user_context, input_queue, output_queue)
      end
    end

    # Factory for creating executors
    def self.create_executor(type, ...)
      case type
      when :inline
        InlineExecutor.new(...)
      when :thread
        ThreadPoolExecutor.new(...)
      when :cow_fork
        CowForkPoolExecutor.new(...)
      when :ipc_fork
        IpcForkPoolExecutor.new(...)
      when :ractor
        RactorPoolExecutor.new(...)
      else
        raise ArgumentError, "Unknown executor type: #{type}. Valid types: :inline, :thread, :cow_fork, :ipc_fork, :ractor"
      end
    end
  end
end
