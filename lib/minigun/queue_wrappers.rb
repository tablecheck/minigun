# frozen_string_literal: true

module Minigun
  # Wrapper around stage input queue that handles EndOfSource signals
  class InputQueue
    def initialize(queue, stage, expected_sources, stage_stats: nil)
      @queue = queue
      @stage = stage
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
          @sources_expected << item.stage # Discover dynamic source Stage object
          @sources_done << item.stage

          # All sources done? Return sentinel
          return EndOfStage.new(@stage) if @sources_done == @sources_expected

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
    def initialize(stage, downstream_queues, runtime_edges, stage_stats: nil)
      @stage = stage
      @downstream_queues = downstream_queues # Array of Queue objects
      @runtime_edges = runtime_edges         # Track dynamic routing (keyed by Stage objects)
      @stage_stats = stage_stats             # Stats object for tracking (optional)
      @to_cache = {}                         # Memoization cache for .to() results
    end

    # Send item to all downstream stages
    def <<(item)
      @downstream_queues.each { |queue| queue << item }
      @stage_stats&.increment_produced # Track in stats directly
      self
    end

    # Magic sauce: explicit routing to specific stage
    # Returns a memoized OutputQueue that routes only to that stage
    # target can be Stage object or name
    def to(target)
      # Return cached instance if available (cache by original key for user convenience)
      return @to_cache[target] if @to_cache.key?(target)

      # Resolve target to Stage object if it's a name
      # Use StageRegistry for cross-pipeline lookup
      target_stage = task.stage_registry.find(target, from_pipeline: pipeline)
      raise ArgumentError, "Unknown target stage: #{target}" unless target_stage

      # Look up queue by Stage object using Task's queue registry
      target_queue = task.find_queue(target_stage)
      raise ArgumentError, "Unknown target stage: #{target} (resolved to #{target_stage.name})" unless target_queue

      # Track this as a runtime edge for END signal handling
      # Ensure the entry exists before adding to it (important for fork contexts)
      @runtime_edges[@stage] ||= Set.new
      @runtime_edges[@stage].add(target_stage)

      # Create and cache the OutputQueue for this target
      @to_cache[target] = OutputQueue.new(
        @stage,
        [target_queue],
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

    private

    def pipeline
      @stage.pipeline
    end

    def task
      pipeline&.task
    end
  end

  # IPC-backed input queue that reads items from parent via IPC pipe
  # Used by IpcForkPoolExecutor workers to receive items from parent process
  class IpcInputQueue
    def initialize(pipe_reader, stage)
      @pipe_reader = pipe_reader
      @stage = stage
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
        when :routed_item
          # Item targeted at specific nested stage - return with routing metadata
          return RoutedItem.new(message[:target_stage], message[:item])
        when :end_of_stage, :shutdown
          return EndOfStage.new(@stage)
        end
      end
    rescue EOFError, IOError
      # Pipe closed, return EndOfStage
      return EndOfStage.new(@stage)
    end
  end

  # IPC-backed output queue that writes results back to parent via IPC pipe
  # Used by IpcForkPoolExecutor workers to send results to parent process
  # Wrapper for IPC output that encodes routing information
  class IpcRoutedOutputQueue
    def initialize(pipe_writer, stage_stats, target_stage)
      @pipe_writer = pipe_writer
      @stage_stats = stage_stats
      @target_stage = target_stage
    end

    def <<(item)
      # Send result with routing target back to parent via IPC
      begin
        Marshal.dump({
          type: :routed_result,
          target: @target_stage,
          result: item
        }, @pipe_writer)
        @pipe_writer.flush
        @stage_stats&.increment_produced
      rescue TypeError, ArgumentError => e
        Minigun.logger.warn "[Minigun] Cannot serialize routed result for IPC: #{e.message}"
        begin
          Marshal.dump({
            type: :serialization_error,
            error: "Cannot serialize result: #{e.message}",
            item_type: item.class.to_s
          }, @pipe_writer)
          @pipe_writer.flush
        rescue
          raise
        end
      end
      self
    end
  end

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
        elsif item.is_a?(Minigun::EndOfStage)
          # EndOfStage contains Stage objects which aren't marshalable
          # Send as a control message instead
          Marshal.dump({ type: :end_of_stage }, @pipe_writer)
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

    def to(target_stage)
      # For IPC workers, routing must be encoded in the result
      # Return a wrapper that includes routing information
      IpcRoutedOutputQueue.new(@pipe_writer, @stage_stats, target_stage)
    end

    def to_proc
      proc { |item, to: nil| self << item }
    end
  end
end
