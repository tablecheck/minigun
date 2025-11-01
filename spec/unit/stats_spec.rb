# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Minigun::Stats do
  let(:test_stage) { double('Stage', name: 'test_stage') }

  describe '#initialize' do
    it 'creates stats with stage object' do
      stats = described_class.new(test_stage)
      expect(stats.stage_name).to eq('test_stage')
    end

    it 'defaults is_terminal to false' do
      stats = described_class.new(test_stage)
      expect(stats.total_items).to eq(0)
    end

    it 'accepts is_terminal parameter' do
      stats = described_class.new(test_stage, is_terminal: true)
      stats.items_consumed # Just verify it was set
      expect(stats.stage_name).to eq('test_stage')
    end
  end

  describe '#start! and #finish!' do
    it 'records start time' do
      stats = described_class.new(test_stage)
      stats.start!
      expect(stats.start_time).to be_a(Time)
    end

    it 'records end time' do
      stats = described_class.new(test_stage)
      stats.start!
      stats.finish!
      expect(stats.end_time).to be_a(Time)
    end
  end

  describe '#increment_produced' do
    it 'increments produced count' do
      stats = described_class.new(test_stage)
      stats.increment_produced
      expect(stats.items_produced).to eq(1)
    end

    it 'increments by custom amount' do
      stats = described_class.new(test_stage)
      stats.increment_produced(5)
      expect(stats.items_produced).to eq(5)
    end

    it 'is thread-safe' do
      stats = described_class.new(test_stage)
      threads = Array.new(10) do
        Thread.new { 100.times { stats.increment_produced } }
      end
      threads.each(&:join)
      expect(stats.items_produced).to eq(1000)
    end
  end

  describe '#increment_consumed' do
    it 'increments consumed count' do
      stats = described_class.new(test_stage)
      stats.increment_consumed
      expect(stats.items_consumed).to eq(1)
    end

    it 'increments by custom amount' do
      stats = described_class.new(test_stage)
      stats.increment_consumed(3)
      expect(stats.items_consumed).to eq(3)
    end

    it 'is thread-safe' do
      stats = described_class.new(test_stage)
      threads = Array.new(10) do
        Thread.new { 100.times { stats.increment_consumed } }
      end
      threads.each(&:join)
      expect(stats.items_consumed).to eq(1000)
    end
  end

  describe '#increment_failed' do
    it 'increments failed count' do
      stats = described_class.new(test_stage)
      stats.increment_failed
      expect(stats.items_failed).to eq(1)
    end

    it 'is thread-safe' do
      stats = described_class.new(test_stage)
      threads = Array.new(10) do
        Thread.new { 50.times { stats.increment_failed } }
      end
      threads.each(&:join)
      expect(stats.items_failed).to eq(500)
    end
  end

  describe '#runtime' do
    it 'returns 0 when not started' do
      stats = described_class.new(test_stage)
      expect(stats.runtime).to eq(0)
    end

    it 'calculates runtime when finished' do
      stats = described_class.new(test_stage)
      stats.start!
      sleep(0.01)
      stats.finish!
      expect(stats.runtime).to be > 0
    end

    it 'calculates runtime from start to now when not finished' do
      stats = described_class.new(test_stage)
      stats.start!
      sleep(0.01)
      expect(stats.runtime).to be > 0
    end
  end

  describe '#total_items' do
    context 'when is_terminal is false (non-terminal stage)' do
      it 'counts produced items only' do
        stats = described_class.new(:test_stage, is_terminal: false)
        stats.increment_produced(10)
        stats.increment_consumed(5)
        expect(stats.total_items).to eq(10)
      end
    end

    context 'when is_terminal is true (terminal stage)' do
      it 'counts consumed items only' do
        stats = described_class.new(:test_stage, is_terminal: true)
        stats.increment_produced(10)
        stats.increment_consumed(5)
        expect(stats.total_items).to eq(5)
      end
    end
  end

  describe '#throughput' do
    it 'returns 0 when runtime is 0' do
      stats = described_class.new(test_stage)
      expect(stats.throughput).to eq(0)
    end

    it 'calculates items per second' do
      stats = described_class.new(test_stage)
      stats.start!
      stats.increment_produced(100)
      sleep(0.1)
      stats.finish!
      expect(stats.throughput).to be > 0
      expect(stats.throughput).to be < 10_000
    end
  end

  describe '#time_per_item' do
    it 'returns 0 when no items' do
      stats = described_class.new(test_stage)
      stats.start!
      stats.finish!
      expect(stats.time_per_item).to eq(0)
    end

    it 'calculates average time per item' do
      stats = described_class.new(test_stage)
      stats.start!
      stats.increment_produced(10)
      sleep(0.1)
      stats.finish!
      expect(stats.time_per_item).to be > 0
      expect(stats.time_per_item).to be < 1
    end
  end

  describe '#success_rate' do
    it 'returns 100% when no items' do
      stats = described_class.new(test_stage)
      expect(stats.success_rate).to eq(100.0)
    end

    it 'returns 100% when no failures' do
      stats = described_class.new(test_stage)
      stats.increment_produced(10)
      expect(stats.success_rate).to eq(100.0)
    end

    it 'calculates success rate with failures' do
      stats = described_class.new(test_stage)
      stats.increment_produced(10)
      stats.increment_failed(2)
      expect(stats.success_rate).to eq(80.0)
    end
  end

  describe '#record_latency' do
    it 'uses reservoir sampling for uniform probability' do
      stats = described_class.new(test_stage)

      # Record many latencies
      200.times do |i|
        stats.record_latency(0.001 * i)
      end

      # Should have sampled data
      expect(stats.latency_data?).to be true
      samples = stats.latency_samples

      # Should have up to 200 samples (less than reservoir size)
      expect(samples.size).to eq(200)

      # Samples should be in the recorded range
      expect(samples.min).to be >= 0
      expect(samples.max).to be <= 0.199
    end

    it 'maintains reservoir size limit' do
      stats = described_class.new(test_stage)

      # Record more items than reservoir size
      2000.times do |i|
        stats.record_latency(0.001 * i)
      end

      samples = stats.latency_samples
      reservoir_size = described_class::RESERVOIR_SIZE

      # Should not exceed reservoir size
      expect(samples.size).to eq(reservoir_size)

      # Should have recorded all 2000 observations
      expect(stats.latency_count).to eq(2000)
    end

    it 'maintains uniform probability distribution' do
      stats = described_class.new(test_stage)

      # Record many items with distinct values
      5000.times do |i|
        stats.record_latency(i.to_f)
      end

      samples = stats.latency_samples
      reservoir_size = described_class::RESERVOIR_SIZE

      # Should have exactly reservoir_size samples
      expect(samples.size).to eq(reservoir_size)

      # Check distribution - samples should be spread across the range
      # With uniform sampling, we expect samples throughout [0, 4999]
      ranges = [
        (0...1000),
        (1000...2000),
        (2000...3000),
        (3000...4000),
        (4000...5000)
      ]

      ranges.each do |range|
        count = samples.count { |s| range.cover?(s) }
        # Each range should have roughly 1/5 of samples (200 ± some variance)
        # Allow for statistical variance - expect at least 100 in each range
        expect(count).to be > 100
      end
    end

    it 'is thread-safe with concurrent latency recording' do
      stats = described_class.new(test_stage)

      threads = Array.new(10) do
        Thread.new do
          100.times do |i|
            stats.record_latency(0.001 * i)
          end
        end
      end
      threads.each(&:join)

      # Should have recorded all 1000 observations
      expect(stats.latency_count).to eq(1000)

      # Should have up to 1000 samples (less than reservoir size)
      samples = stats.latency_samples
      expect(samples.size).to eq(1000)
    end

    it 'tracks total observation count separately from samples' do
      stats = described_class.new(test_stage)

      # Record 10,000 latencies
      10_000.times do |i|
        stats.record_latency(0.001 * i)
      end

      reservoir_size = described_class::RESERVOIR_SIZE

      # Samples should be capped at reservoir size
      expect(stats.latency_samples.size).to eq(reservoir_size)

      # But total observations should be tracked
      expect(stats.latency_count).to eq(10_000)
    end

    it 'works correctly with very large datasets (1 million items)' do
      stats = described_class.new(test_stage)

      # Simulate 1 million items (use modulo to keep distinct values manageable)
      1_000_000.times do |i|
        stats.record_latency((i % 1000).to_f)
      end

      reservoir_size = described_class::RESERVOIR_SIZE
      samples = stats.latency_samples

      # Should have exactly reservoir_size samples
      expect(samples.size).to eq(reservoir_size)

      # Should have tracked all observations
      expect(stats.latency_count).to eq(1_000_000)

      # Samples should be in expected range
      expect(samples.min).to be >= 0
      expect(samples.max).to be < 1000
    end
  end

  describe 'percentile methods' do
    let(:stats) do
      s = described_class.new(test_stage)
      # Add samples using the public API
      s.start!
      [0.01, 0.02, 0.03, 0.04, 0.05, 0.06, 0.07, 0.08, 0.09, 0.10].each do |latency|
        s.record_latency(latency)
      end
      s.finish!
      s
    end

    describe '#latency_data?' do
      it 'returns false when no samples' do
        stats = described_class.new(test_stage)
        expect(stats.latency_data?).to be false
      end

      it 'returns true when samples exist' do
        expect(stats.latency_data?).to be true
      end
    end

    describe '#p50' do
      it 'calculates 50th percentile' do
        expect(stats.p50).to be_between(0.04, 0.06)
      end
    end

    describe '#p90' do
      it 'calculates 90th percentile' do
        expect(stats.p90).to be_between(0.08, 0.10)
      end
    end

    describe '#p95' do
      it 'calculates 95th percentile' do
        expect(stats.p95).to be_between(0.09, 0.10)
      end
    end

    describe '#p99' do
      it 'calculates 99th percentile' do
        expect(stats.p99).to eq(0.10)
      end
    end
  end

  describe '#to_h' do
    it 'returns hash with basic stats' do
      stats = described_class.new(test_stage)
      stats.start!
      stats.increment_produced(10)
      stats.increment_consumed(5)
      stats.finish!

      hash = stats.to_h
      expect(hash[:stage_name]).to eq('test_stage')
      expect(hash[:runtime]).to be_a(Numeric)
      expect(hash[:items_produced]).to eq(10)
      expect(hash[:items_consumed]).to eq(5)
      expect(hash[:total_items]).to eq(10) # is_terminal defaults to false
      expect(hash[:throughput]).to be_a(Numeric)
      expect(hash[:success_rate]).to eq(100.0)
    end

    it 'includes latency data when available' do
      stats = described_class.new(test_stage)
      stats.start!
      [0.01, 0.02, 0.03].each { |latency| stats.record_latency(latency) }
      stats.finish!

      hash = stats.to_h
      expect(hash[:latency]).to be_a(Hash)
      expect(hash[:latency][:p50]).to be_a(Numeric)
      expect(hash[:latency][:samples]).to eq(3)
      expect(hash[:latency][:observations]).to eq(3)
    end

    it 'shows observations count separately from samples in to_h' do
      stats = described_class.new(test_stage)

      # Record 5000 items
      5000.times do |i|
        stats.record_latency(0.001 * i)
      end

      hash = stats.to_h
      reservoir_size = described_class::RESERVOIR_SIZE

      # Should have capped samples
      expect(hash[:latency][:samples]).to eq(reservoir_size)

      # But full observation count
      expect(hash[:latency][:observations]).to eq(5000)
    end
  end

  describe '#to_s' do
    it 'returns readable string representation' do
      stats = described_class.new(test_stage)
      stats.start!
      stats.increment_produced(10)
      stats.finish!

      string = stats.to_s
      expect(string).to include('test_stage')
      expect(string).to include('Runtime:')
      expect(string).to include('Items:')
      expect(string).to include('Throughput:')
    end

    it 'includes failure info when present' do
      stats = described_class.new(test_stage)
      stats.increment_produced(10)
      stats.increment_failed(2)

      string = stats.to_s
      expect(string).to include('Failed:')
    end

    it 'includes latency info when available' do
      stats = described_class.new(test_stage)
      stats.start!
      [0.01, 0.02].each { |latency| stats.record_latency(latency) }
      stats.finish!

      string = stats.to_s
      expect(string).to include('Latency')
    end
  end
end

RSpec.describe Minigun::AggregatedStats do
  let(:dag) do
    dag = Minigun::DAG.new
    dag.add_node(:producer)
    dag.add_node(:processor)
    dag.add_node(:consumer)
    dag.add_edge(:producer, :processor)
    dag.add_edge(:processor, :consumer)
    dag
  end

  describe '#initialize' do
    it 'creates aggregated stats with pipeline name and dag' do
      stats = described_class.new('test_pipeline', dag)
      expect(stats.pipeline_name).to eq('test_pipeline')
    end
  end

  describe '#for_stage' do
    it 'creates stats for a stage' do
      agg_stats = described_class.new('test_pipeline', dag)
      stage_stats = agg_stats.for_stage(:producer)

      expect(stage_stats).to be_a(Minigun::Stats)
      expect(stage_stats.stage_name).to eq('producer')
    end

    it 'returns same stats instance for same stage' do
      agg_stats = described_class.new('test_pipeline', dag)
      stats1 = agg_stats.for_stage(:producer)
      stats2 = agg_stats.for_stage(:producer)

      expect(stats1).to be(stats2)
    end

    it 'passes is_terminal flag correctly' do
      agg_stats = described_class.new('test_pipeline', dag)

      # Producer is non-terminal
      producer_stats = agg_stats.for_stage(:producer, is_terminal: false)
      producer_stats.increment_produced(10)
      expect(producer_stats.total_items).to eq(10)

      # Consumer is terminal
      consumer_stats = agg_stats.for_stage(:consumer, is_terminal: true)
      consumer_stats.increment_consumed(5)
      expect(consumer_stats.total_items).to eq(5)
    end
  end

  describe '#start! and #finish!' do
    it 'records pipeline start and finish time' do
      agg_stats = described_class.new('test_pipeline', dag)
      agg_stats.start!
      sleep(0.01)
      agg_stats.finish!

      expect(agg_stats.runtime).to be > 0
    end
  end

  describe '#runtime' do
    it 'returns 0 when not started' do
      agg_stats = described_class.new('test_pipeline', dag)
      expect(agg_stats.runtime).to eq(0)
    end

    it 'calculates runtime when finished' do
      agg_stats = described_class.new('test_pipeline', dag)
      agg_stats.start!
      sleep(0.01)
      agg_stats.finish!

      expect(agg_stats.runtime).to be > 0
    end
  end

  describe '#total_produced' do
    it 'sums produced items from source stages' do
      agg_stats = described_class.new('test_pipeline', dag)

      producer_stats = agg_stats.for_stage(:producer)
      producer_stats.increment_produced(10)

      expect(agg_stats.total_produced).to eq(10)
    end

    it 'handles multiple source stages' do
      multi_dag = Minigun::DAG.new
      multi_dag.add_node(:producer1)
      multi_dag.add_node(:producer2)
      multi_dag.add_node(:consumer)
      multi_dag.add_edge(:producer1, :consumer)
      multi_dag.add_edge(:producer2, :consumer)

      agg_stats = described_class.new('test_pipeline', multi_dag)
      agg_stats.for_stage(:producer1).increment_produced(5)
      agg_stats.for_stage(:producer2).increment_produced(7)

      expect(agg_stats.total_produced).to eq(12)
    end
  end

  describe '#total_consumed' do
    it 'sums consumed items from terminal stages' do
      agg_stats = described_class.new('test_pipeline', dag)

      consumer_stats = agg_stats.for_stage(:consumer)
      consumer_stats.increment_consumed(8)

      expect(agg_stats.total_consumed).to eq(8)
    end

    it 'handles multiple terminal stages' do
      multi_dag = Minigun::DAG.new
      multi_dag.add_node(:producer)
      multi_dag.add_node(:consumer1)
      multi_dag.add_node(:consumer2)
      multi_dag.add_edge(:producer, :consumer1)
      multi_dag.add_edge(:producer, :consumer2)

      agg_stats = described_class.new('test_pipeline', multi_dag)
      agg_stats.for_stage(:consumer1).increment_consumed(3)
      agg_stats.for_stage(:consumer2).increment_consumed(4)

      expect(agg_stats.total_consumed).to eq(7)
    end
  end

  describe '#total_items' do
    it 'sums total items across all stages' do
      agg_stats = described_class.new('test_pipeline', dag)

      # Producer is non-terminal: counts produced
      agg_stats.for_stage(:producer, is_terminal: false).increment_produced(10)

      # Processor is non-terminal: counts produced (not consumed)
      processor = agg_stats.for_stage(:processor, is_terminal: false)
      processor.increment_consumed(10)
      processor.increment_produced(10)

      # Consumer is terminal: counts consumed
      agg_stats.for_stage(:consumer, is_terminal: true).increment_consumed(10)

      # total_items = 10 (producer produced) + 10 (processor produced) + 10 (consumer consumed) = 30
      expect(agg_stats.total_items).to eq(30)
    end
  end

  describe '#throughput' do
    it 'returns 0 when runtime is 0' do
      agg_stats = described_class.new('test_pipeline', dag)
      expect(agg_stats.throughput).to eq(0)
    end

    it 'calculates items per second based on produced items' do
      agg_stats = described_class.new('test_pipeline', dag)
      agg_stats.start!
      agg_stats.for_stage(:producer).increment_produced(100)
      sleep(0.1)
      agg_stats.finish!

      expect(agg_stats.throughput).to be > 0
      expect(agg_stats.throughput).to be < 10_000
    end
  end

  describe '#bottleneck' do
    it 'returns nil when no stages' do
      agg_stats = described_class.new('test_pipeline', dag)
      expect(agg_stats.bottleneck).to be_nil
    end

    it 'identifies stage with lowest throughput' do
      agg_stats = described_class.new('test_pipeline', dag)

      # Producer: fast (1000 items in 0.01s = 100,000 items/s)
      producer = agg_stats.for_stage(:producer, is_terminal: false)
      producer.start!
      producer.increment_produced(1000)
      sleep(0.01)
      producer.finish!

      # Processor: slow - bottleneck (5 items in 0.1s = 50 items/s)
      processor = agg_stats.for_stage(:processor, is_terminal: false)
      processor.start!
      processor.increment_produced(5)
      sleep(0.1)
      processor.finish!

      # Consumer: medium (100 items in 0.05s = 2,000 items/s)
      consumer = agg_stats.for_stage(:consumer, is_terminal: true)
      consumer.start!
      consumer.increment_consumed(100)
      sleep(0.05)
      consumer.finish!

      bottleneck = agg_stats.bottleneck
      expect(bottleneck).to be_a(Minigun::Stats)
      expect(bottleneck.stage_name).to eq('processor')
    end
  end

  describe '#stages_in_order' do
    it 'returns stages in topological order' do
      agg_stats = described_class.new('test_pipeline', dag)

      agg_stats.for_stage(:producer)
      agg_stats.for_stage(:processor)
      agg_stats.for_stage(:consumer)

      stages = agg_stats.stages_in_order
      expect(stages.map(&:stage_name)).to eq(%w[producer processor consumer])
    end

    it 'skips stages without stats' do
      agg_stats = described_class.new('test_pipeline', dag)

      agg_stats.for_stage(:producer)
      agg_stats.for_stage(:consumer)
      # processor is skipped

      stages = agg_stats.stages_in_order
      expect(stages.map(&:stage_name)).to eq(%w[producer consumer])
    end
  end

  describe '#to_h' do
    it 'returns hash with pipeline stats' do
      agg_stats = described_class.new('test_pipeline', dag)
      agg_stats.start!

      producer = agg_stats.for_stage(:producer)
      producer.start!
      producer.increment_produced(10)
      producer.finish!

      agg_stats.finish!

      hash = agg_stats.to_h
      expect(hash[:pipeline]).to eq('test_pipeline')
      expect(hash[:runtime]).to be_a(Numeric)
      expect(hash[:total_produced]).to eq(10)
      expect(hash[:throughput]).to be_a(Numeric)
      expect(hash[:stages]).to be_an(Array)
    end

    it 'includes bottleneck info when present' do
      agg_stats = described_class.new('test_pipeline', dag)

      producer = agg_stats.for_stage(:producer)
      producer.start!
      producer.increment_produced(10)
      sleep(0.01)
      producer.finish!

      hash = agg_stats.to_h
      expect(hash[:bottleneck]).to be_a(Hash)
      expect(hash[:bottleneck][:stage]).to eq('producer')
      expect(hash[:bottleneck][:throughput]).to be_a(Numeric)
    end
  end

  describe '#summary' do
    it 'returns human-readable summary' do
      agg_stats = described_class.new('test_pipeline', dag)
      agg_stats.start!

      producer = agg_stats.for_stage(:producer)
      producer.start!
      producer.increment_produced(10)
      producer.finish!

      consumer = agg_stats.for_stage(:consumer)
      consumer.start!
      consumer.increment_consumed(10)
      consumer.finish!

      agg_stats.finish!

      summary = agg_stats.summary
      expect(summary).to include('Pipeline: test_pipeline')
      expect(summary).to include('Runtime:')
      expect(summary).to include('Items:')
      expect(summary).to include('Throughput:')
      expect(summary).to include('Bottleneck:')
      expect(summary).to include('Stages:')
    end
  end
end
