# frozen_string_literal: true

module Minigun
  # Execution strategies for running pipeline stages
  module Execution
    # Base executor class - all execution strategies inherit from this
    # NOTE: Stages now manage their own execution loops internally via execute(context, input_queue, output_queue).
    # Executors define HOW that execution happens (inline, threaded, etc).
    class Executor
      # Execute the actual stage logic using this executor's strategy
      # Subclasses implement this to control HOW execution happens
      def execute_stage(stage, user_context, input_queue, output_queue, stage_stats)
        raise NotImplementedError, "#{self.class}#execute_with_strategy must be implemented"
      end

      # Shutdown and cleanup resources
      def shutdown
        # Default: no-op
      end
    end

    # Inline execution - no concurrency, executes immediately in current thread
    class InlineExecutor < Executor
      def execute_stage(stage, user_context, input_queue, output_queue, stage_stats)
        stage.execute(user_context, input_queue, output_queue, stage_stats)
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

      def execute_stage(stage, user_context, input_queue, output_queue, stage_stats)
        wait_for_slot

        thread = Thread.new do
          stage.execute(user_context, input_queue, output_queue, stage_stats)
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

    # COW Fork Pool Executor - Copy-On-Write fork pattern
    # Maintains a pool of up to max_size concurrent forked processes.
    # Each forked process handles ONE item then exits.
    # Memory pages are shared between parent and child until modified (COW).
    # No serialization overhead - child inherits parent's memory.
    class CowForkPoolExecutor < Executor
      attr_reader :max_size

      def initialize(max_size:)
        super()
        @max_size = max_size
        @active_forks = {} # pid => item
        @mutex = Mutex.new
      end

      def execute_stage(stage, user_context, input_queue, output_queue, stage_stats)
        unless Process.respond_to?(:fork)
          warn '[Minigun] Process forking not available, falling back to inline'
          return stage.execute(user_context, input_queue, output_queue, stage_stats)
        end

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
              fork_for_item(item, stage, user_context, output_queue, stage_stats)
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

      def fork_for_item(item, stage, user_context, output_queue, stage_stats)
        # Create wrapper hash before fork - this structure is COW-shared
        # When child writes to wrapper[:result], it triggers COW but parent can check original
        wrapper = { item: item, result: nil }

        # Fork child process - wrapper hash is COW-shared
        pid = fork do
          begin
            # Child process has inherited wrapper via COW
            # Read item from wrapper (read-only, no COW copy)
            item_to_process = wrapper[:item]

            # Execute the stage's block on this single item
            result = stage.process_item(item_to_process, user_context)

            # Write result to wrapper - this triggers COW copy for this hash entry
            wrapper[:result] = result unless result.nil?
          rescue => e
            warn "[Minigun] Error in COW forked process: #{e.message}"
            warn e.backtrace.join("\n")
            exit! 1
          ensure
            # Clean exit from child
            exit! 0
          end
        end

        if !pid
          warn '[Minigun] Failed to fork process, falling back to inline'
          # Fall back to processing inline for this item
          result = stage.process_item(item, user_context)
          output_queue << result unless result.nil?
          return
        end

        @mutex.synchronize { @active_forks[pid] = { wrapper: wrapper, output_queue: output_queue } }
      end

      def reap_completed_forks
        @mutex.synchronize do
          @active_forks.keys.each do |pid|
            status = Process.wait2(pid, Process::WNOHANG)
            next unless status

            _pid, process_status = status
            fork_info = @active_forks.delete(pid)
            wrapper = fork_info[:wrapper]
            output_queue = fork_info[:output_queue]

            if process_status.success?
              # TODO: Results handling with COW-only (no IPC)
              # Child writes to wrapper[:result] trigger COW copy, so parent doesn't see changes
              # Options:
              # 1. Re-process item inline after fork (loses parallelism benefit)
              # 2. Results go to side effects (files, DB, etc.) - no return needed
              # 3. Item is mutated in place - but same COW issue
              # For now, check wrapper - may need different mechanism
              if wrapper[:result]
                output_queue << wrapper[:result]
              end
            else
              warn "[Minigun] COW forked process #{pid} failed with status: #{process_status.exitstatus}"
            end
          end
        end
      end
    end

    # IPC Fork Pool Executor - Inter-Process Communication fork pattern
    # Creates persistent worker processes that communicate via IPC pipes.
    # Workers continuously pull items, process them, and send results back.
    # Data is serialized through pipes, providing strong process isolation.
    class IpcForkPoolExecutor < Executor
      attr_reader :max_size

      def initialize(max_size:)
        super()
        @max_size = max_size
        @workers = []
        @mutex = Mutex.new
      end

      def execute_stage(stage, user_context, input_queue, output_queue, stage_stats)
        unless Process.respond_to?(:fork)
          warn '[Minigun] Process forking not available, falling back to inline'
          return stage.execute(user_context, input_queue, output_queue, stage_stats)
        end

        # Spawn persistent worker processes
        spawn_workers(stage, user_context, stage_stats)

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
              # Send shutdown signal
              Marshal.dump({ type: :shutdown }, worker[:to_worker])
              worker[:to_worker].close
              worker[:from_worker].close

              # Wait for worker to exit
              Process.wait(worker[:pid])
            rescue => e
              # Force kill if graceful shutdown fails
              Process.kill('TERM', worker[:pid]) rescue nil
            end
          end
          @workers.clear
        end
      end

      private

      def spawn_workers(stage, user_context, stage_stats)
        @max_size.times do
          # Create bidirectional pipes for IPC
          parent_read, child_write = IO.pipe
          child_read, parent_write = IO.pipe

          pid = fork do
            # Worker process - close parent ends
            parent_read.close
            parent_write.close

            worker_loop(stage, user_context, stage_stats, child_read, child_write)
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

      def worker_loop(stage, user_context, stage_stats, from_parent, to_parent)
        loop do
          # Read item from parent via IPC
          message = Marshal.load(from_parent)

          break if message[:type] == :shutdown

          if message[:type] == :item
            item = message[:item]

            begin
              # Process the item
              result = stage.process_item(item, user_context)

              # Send result back to parent via IPC (if not nil)
              unless result.nil?
                Marshal.dump({ type: :result, result: result }, to_parent)
                to_parent.flush
              else
                Marshal.dump({ type: :no_result }, to_parent)
                to_parent.flush
              end
            rescue => e
              # Send error back to parent
              Marshal.dump({
                type: :error,
                error: e.message,
                backtrace: e.backtrace
              }, to_parent)
              to_parent.flush
            end
          end
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

        loop do
          item = input_queue.pop
          break if item.is_a?(Minigun::EndOfStage)

          # Round-robin distribution to workers
          worker = @workers[worker_index % @workers.size]
          worker_index += 1

          # Send item to worker via IPC
          begin
            Marshal.dump({ type: :item, item: item }, worker[:to_worker])
            worker[:to_worker].flush

            # Wait for worker response
            response = Marshal.load(worker[:from_worker])

            case response[:type]
            when :result
              # Worker produced a result, push to output queue
              output_queue << response[:result]
            when :error
              # Worker encountered an error
              error_msg = response[:error] || "Unknown error in worker"
              backtrace = response[:backtrace]
              exception = RuntimeError.new("IPC worker error: #{error_msg}")
              exception.set_backtrace(backtrace) if backtrace
              raise exception
            when :no_result
              # Worker processed but produced no output (consumer stage)
            end
          rescue IOError, EOFError => e
            warn "[Minigun] Lost connection to worker #{worker[:pid]}: #{e.message}"
            raise
          end
        end
      end
    end

    # Ractor pool executor - manages ractor execution
    class RactorPoolExecutor < Executor
      def initialize(max_size:)
        super()
        @max_size = max_size
        @fallback = ThreadPoolExecutor.new(max_size: max_size)
      end

      def execute_stage(stage, user_context, input_queue, output_queue, stage_stats)
        unless defined?(::Ractor)
          warn '[Minigun] Ractors not available, falling back to thread pool'
          return @fallback.send(:execute_stage, stage, user_context, input_queue, output_queue, stage_stats)
        end

        # NOTE: Ractors have similar IPC challenges as process pools
        # Fall back to threads for now
        @fallback.send(:execute_stage, stage, user_context, input_queue, output_queue, stage_stats)
      end
    end

    # Factory for creating executors
    def self.create_executor(type:, max_size:)
      case type
      when :inline
        InlineExecutor.new
      when :thread
        ThreadPoolExecutor.new(max_size: max_size)
      when :cow_fork
        CowForkPoolExecutor.new(max_size: max_size)
      when :ipc_fork
        IpcForkPoolExecutor.new(max_size: max_size)
      when :ractor
        RactorPoolExecutor.new(max_size: max_size)
      else
        raise ArgumentError, "Unknown executor type: #{type}. Valid types: :inline, :thread, :cow_fork, :ipc_fork, :ractor"
      end
    end
  end
end
