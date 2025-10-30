# frozen_string_literal: true

module Minigun
  # Wrapper around stage input queue that handles EndOfSource signals
  class InputQueue
    def initialize(queue, stage_name, expected_sources, stage_stats: nil)
      @queue = queue
      @stage_name = stage_name
      @sources_expected = Set.new(expected_sources)
      @sources_done = Set.new
      @stage_stats = stage_stats
    end

    # Pop items from queue, consuming EndOfSource signals
    # Returns EndOfStage sentinel when all upstreams are done
    def pop
      loop do
        item = @queue.pop

        # Handle EndOfSource signals
        if item.is_a?(EndOfSource)
          @sources_expected << item.source # Discover dynamic sources
          @sources_done << item.source

          # All sources done? Return sentinel
          return EndOfStage.new(@stage_name) if @sources_done == @sources_expected

          # More sources pending, keep looping to get next item
          next
        end

        # Track consumption of regular items
        @stage_stats&.increment_consumed

        # Regular item
        return item
      end
    end
  end

  # Wrapper around stage output that routes to downstream queues
  class OutputQueue
    def initialize(stage_name, downstream_queues, all_stage_queues, runtime_edges, stage_stats: nil)
      @stage_name = stage_name
      @downstream_queues = downstream_queues  # Array of Queue objects
      @all_stage_queues = all_stage_queues    # Hash of all queues for .to() method
      @runtime_edges = runtime_edges           # Track dynamic routing
      @stage_stats = stage_stats               # Stats object for tracking (optional)
      @to_cache = {}                           # Memoization cache for .to() results
    end

    # Send item to all downstream stages
    def <<(item)
      @downstream_queues.each { |queue| queue << item }
      @stage_stats&.increment_produced # Track in stats directly
      self
    end

    # Magic sauce: explicit routing to specific stage
    # Returns a memoized OutputQueue that routes only to that stage
    def to(target_stage)
      # Return cached instance if available
      return @to_cache[target_stage] if @to_cache.key?(target_stage)

      target_queue = @all_stage_queues[target_stage]
      raise ArgumentError, "Unknown target stage: #{target_stage}" unless target_queue

      # Track this as a runtime edge for END signal handling
      @runtime_edges[@stage_name].add(target_stage)

      # Create and cache the OutputQueue for this target
      @to_cache[target_stage] = OutputQueue.new(
        @stage_name,
        [target_queue],
        @all_stage_queues,
        @runtime_edges,
        stage_stats: @stage_stats
      )
    end

    # Convert to proc for yield syntax
    # Allows: yield(item) or yield(item, to: :stage_name)
    def to_proc
      @to_proc ||= proc do |item, to: nil|
        if to
          # Route to specific stage
          self.to(to) << item
        else
          # Route to all downstream stages
          self << item
        end
      end
    end
  end

  # IPC-backed input queue that reads items from parent via IPC pipe
  # Used by IpcForkPoolExecutor workers to receive items from parent process
  class IpcInputQueue
    def initialize(pipe_reader, stage_name)
      @pipe_reader = pipe_reader
      @stage_name = stage_name
      @buffer = []
    end

    def pop
      # Return buffered item if available
      return @buffer.shift unless @buffer.empty?

      # Read from IPC pipe
      loop do
        message = Marshal.load(@pipe_reader)

        case message[:type]
        when :item
          return message[:item]
        when :end_of_stage, :shutdown
          return EndOfStage.new(@stage_name)
        end
      end
    rescue EOFError, IOError
      # Pipe closed, return EndOfStage
      return EndOfStage.new(@stage_name)
    end
  end

  # IPC-backed output queue that writes results back to parent via IPC pipe
  # Used by IpcForkPoolExecutor workers to send results to parent process
  class IpcOutputQueue
    def initialize(pipe_writer, stage_stats)
      @pipe_writer = pipe_writer
      @stage_stats = stage_stats
    end

    def <<(item)
      # Send result back to parent via IPC
      begin
        if item.nil?
          Marshal.dump({ type: :no_result }, @pipe_writer)
        else
          Marshal.dump({ type: :result, result: item }, @pipe_writer)
        end
        @pipe_writer.flush
        @stage_stats&.increment_produced
      rescue TypeError, ArgumentError => e
        # Item contains non-serializable objects (e.g., IO, Proc, etc.)
        # Log warning but don't crash - this is a data issue, not a system error
        Minigun.logger.warn "[Minigun] Cannot serialize result for IPC: #{e.message}. Result type: #{item.class}"
        # Send an error notification instead
        begin
          Marshal.dump({
            type: :serialization_error,
            error: "Cannot serialize result: #{e.message}",
            item_type: item.class.to_s
          }, @pipe_writer)
          @pipe_writer.flush
        rescue
          # If we can't even send the error, pipe is broken
          raise
        end
      end
      self
    end

    def to(_target_stage)
      # For IPC workers, routing is handled by parent process
      # Just return self as a proxy
      self
    end

    def to_proc
      proc { |item, to: nil| self << item }
    end
  end
end
