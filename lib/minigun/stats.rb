# frozen_string_literal: true

require 'concurrent'

module Minigun
  # Tracks execution statistics for a single stage
  class Stats
    attr_reader :stage, :start_time, :end_time, :latency_samples, :latency_count

    # Latency tracking - reservoir sampling for uniform distribution
    RESERVOIR_SIZE = 1000

    def initialize(stage, is_terminal: false)
      @stage = stage
      @is_terminal = is_terminal
      @start_time = nil
      @end_time = nil
      @items_produced = Concurrent::AtomicFixnum.new(0)
      @items_consumed = Concurrent::AtomicFixnum.new(0)
      @items_failed = Concurrent::AtomicFixnum.new(0)

      # Latency tracking - reservoir sampling
      @latency_samples = []
      @latency_count = 0 # Total number of latency observations
      @mutex = Mutex.new
    end

    # Get stage name
    def stage_name
      @stage.name
    end

    # Public accessors that return integer values from AtomicFixnum
    def items_produced
      @items_produced.value
    end

    def items_consumed
      @items_consumed.value
    end

    def items_failed
      @items_failed.value
    end

    # Mark stage as started
    def start!
      @start_time = Time.now
    end

    # Mark stage as completed
    def finish!
      @end_time = Time.now
    end

    # Increment counters (lock-free, thread-safe)
    def increment_produced(count = 1)
      @items_produced.increment(count)
    end

    def increment_consumed(count = 1)
      @items_consumed.increment(count)
    end

    def increment_failed(count = 1)
      @items_failed.increment(count)
    end

    # Record latency for an item (in seconds) using reservoir sampling
    # This ensures uniform probability distribution across all items
    def record_latency(duration)
      @mutex.synchronize do
        @latency_count += 1

        if @latency_samples.size < RESERVOIR_SIZE
          # Reservoir not full yet, just add the sample
          @latency_samples << duration
        else
          # Reservoir is full, randomly replace an existing sample
          # Each item has probability RESERVOIR_SIZE / @latency_count of being kept
          random_index = rand(@latency_count)
          @latency_samples[random_index] = duration if random_index < RESERVOIR_SIZE
        end
      end
    end

    # Calculate runtime
    def runtime
      return 0 if @start_time.nil?

      (@end_time || Time.now) - @start_time
    end

    # Calculate items per second
    def throughput
      return 0 if runtime.zero?

      total_items / runtime
    end

    # Calculate average time per item
    def time_per_item
      return 0 if total_items.zero?

      runtime / total_items.to_f
    end

    # Total items processed
    # For terminal stages (final consumers), count consumed items
    # For non-terminal stages (produce items for downstream), count produced items
    def total_items
      @is_terminal ? items_consumed : items_produced
    end

    # Success rate
    def success_rate
      return 100.0 if total_items.zero?

      ((total_items - items_failed) / total_items.to_f) * 100
    end

    # Calculate percentile from latency samples
    def percentile(p_value)
      return 0 if @latency_samples.empty?

      sorted = @latency_samples.sort
      index = ((p_value / 100.0) * sorted.length).ceil - 1
      index = index.clamp(0, sorted.length - 1)
      sorted[index]
    end

    # Latency percentiles (P50, P90, P95, P99)
    def p50
      percentile(50)
    end

    def p90
      percentile(90)
    end

    def p95
      percentile(95)
    end

    def p99
      percentile(99)
    end

    # Check if we have latency data
    def latency_data?
      @latency_samples.any?
    end

    # Generate a summary hash
    def to_h
      {
        stage_name: stage_name,
        runtime: runtime.round(2),
        items_produced: items_produced,
        items_consumed: items_consumed,
        items_failed: items_failed,
        total_items: total_items,
        throughput: throughput.round(2),
        time_per_item: time_per_item.round(4),
        success_rate: success_rate.round(2)
      }.tap do |h|
        if latency_data?
          h[:latency] = {
            p50: (p50 * 1000).round(2), # Convert to ms
            p90: (p90 * 1000).round(2),
            p95: (p95 * 1000).round(2),
            p99: (p99 * 1000).round(2),
            samples: @latency_samples.size,
            observations: @latency_count # Total items measured
          }
        end
      end
    end

    # Pretty print
    def to_s
      parts = [
        "Stage: #{stage_name}",
        "Runtime: #{runtime.round(2)}s",
        "Items: #{total_items}",
        "Throughput: #{throughput.round(2)} items/s"
      ]

      parts << "Failed: #{items_failed} (#{(100 - success_rate).round(2)}%)" if items_failed > 0

      parts << "Latency P50/P90/P95: #{(p50 * 1000).round(1)}/#{(p90 * 1000).round(1)}/#{(p95 * 1000).round(1)}ms" if latency_data?

      parts.join(', ')
    end
  end

  # Aggregates statistics from multiple stages using DAG
  class AggregatedStats
    attr_reader :pipeline, :dag, :stage_stats

    def initialize(pipeline, dag)
      @pipeline = pipeline # Direct pipeline reference
      @dag = dag
      @stage_stats = {}
      @start_time = nil
      @end_time = nil
    end

    # Backward compatibility method
    def pipeline_name
      @pipeline.name
    end

    # Get or create stats for a stage
    def for_stage(stage, is_terminal: false)
      @stage_stats[stage] ||= Stats.new(stage, is_terminal: is_terminal)
    end

    # Mark pipeline as started
    def start!
      @start_time = Time.now
    end

    # Mark pipeline as completed
    def finish!
      @end_time = Time.now
    end

    # Total pipeline runtime
    def runtime
      return 0 if @start_time.nil?

      (@end_time || Time.now) - @start_time
    end

    # Total items across all stages
    def total_items
      @stage_stats.values.sum(&:total_items)
    end

    # Total items produced (from source stages)
    def total_produced
      source_stages = @dag.sources
      source_stages.sum { |name| @stage_stats[name]&.items_produced || 0 }
    end

    # Total items consumed (by terminal stages)
    def total_consumed
      terminal_stages = @dag.terminals
      terminal_stages.sum { |name| @stage_stats[name]&.items_consumed || 0 }
    end

    # Pipeline throughput (items/second)
    def throughput
      return 0 if runtime.zero?

      total_produced / runtime
    end

    # Find bottleneck stage (slowest throughput)
    def bottleneck
      return nil if @stage_stats.empty?

      @stage_stats.values.min_by(&:throughput)
    end

    # Get stats for stages in topological order
    def stages_in_order
      @dag.topological_sort.filter_map { |name| @stage_stats[name] }
    end

    # Generate summary hash
    def to_h
      {
        pipeline: @pipeline.name,
        runtime: runtime.round(2),
        total_produced: total_produced,
        total_consumed: total_consumed,
        throughput: throughput.round(2),
        stages: stages_in_order.map(&:to_h)
      }.tap do |h|
        if (bn = bottleneck)
          h[:bottleneck] = {
            stage: bn.stage_name,
            throughput: bn.throughput.round(2)
          }
        end
      end
    end

    # Pretty print summary
    def summary
      lines = []
      lines << "Pipeline: #{@pipeline.name}"
      lines << "Runtime: #{runtime.round(2)}s"
      lines << "Items: #{total_produced} produced, #{total_consumed} consumed"
      lines << "Throughput: #{throughput.round(2)} items/s"

      if (bn = bottleneck)
        lines << "Bottleneck: #{bn.stage_name} (#{bn.throughput.round(2)} items/s)"
      end

      lines << "\nStages:"
      stages_in_order.each do |stats|
        lines << "  • #{stats}"
      end

      lines.join("\n")
    end
  end
end
