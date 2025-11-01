# frozen_string_literal: true

require 'spec_helper'
require 'minigun/queue_wrappers'

RSpec.describe Minigun::OutputQueue do
  # Create mock Stage objects
  let(:test_stage) { double('test_stage', name: :test_stage) }
  let(:stage_a) { double('stage_a', name: :stage_a) }
  let(:stage_b) { double('stage_b', name: :stage_b) }
  let(:stage_c) { double('stage_c', name: :stage_c) }

  let(:downstream_queues) { [Queue.new, Queue.new] }
  let(:all_stage_queues) { { stage_a => Queue.new, stage_b => Queue.new, stage_c => Queue.new } }
  let(:runtime_edges) { Hash.new { |h, k| h[k] = Set.new } }
  let(:stage_stats) { double('stage_stats', increment_produced: nil) }

  # Mock pipeline that can find stages by name
  let(:pipeline) do
    double('pipeline').tap do |p|
      allow(p).to receive(:find_stage).with(:stage_a).and_return(stage_a)
      allow(p).to receive(:find_stage).with(:stage_b).and_return(stage_b)
      allow(p).to receive(:find_stage).with(:stage_c).and_return(stage_c)
      allow(p).to receive(:find_stage).with(:unknown_stage).and_return(nil)
    end
  end

  let(:output_queue) do
    described_class.new(
      test_stage,
      downstream_queues,
      all_stage_queues,
      runtime_edges,
      pipeline: pipeline,
      stage_stats: stage_stats
    )
  end

  describe '#<<' do
    it 'sends item to all downstream queues' do
      output_queue << 42

      expect(downstream_queues[0].size).to eq(1)
      expect(downstream_queues[0].pop).to eq(42)
      expect(downstream_queues[1].size).to eq(1)
      expect(downstream_queues[1].pop).to eq(42)
    end

    it 'increments produced count in stats' do
      expect(stage_stats).to receive(:increment_produced).once

      output_queue << 42
    end

    it 'returns self for chaining' do
      expect(output_queue << 42).to eq(output_queue)
    end
  end

  describe '#to' do
    it 'returns an OutputQueue for the target stage' do
      result = output_queue.to(:stage_a)

      expect(result).to be_a(described_class)
    end

    it 'raises error for unknown stage' do
      expect do
        output_queue.to(:unknown_stage)
      end.to raise_error(ArgumentError, /Unknown target stage/)
    end

    it 'tracks runtime edge' do
      output_queue.to(:stage_a)

      expect(runtime_edges[test_stage]).to include(stage_a)
    end

    context 'memoization' do
      it 'returns the same OutputQueue instance for the same target' do
        first_call = output_queue.to(:stage_a)
        second_call = output_queue.to(:stage_a)
        third_call = output_queue.to(:stage_a)

        expect(first_call).to be(second_call) # Same object (object_id)
        expect(second_call).to be(third_call)
      end

      it 'returns different OutputQueue instances for different targets' do
        queue_a = output_queue.to(:stage_a)
        queue_b = output_queue.to(:stage_b)
        queue_c = output_queue.to(:stage_c)

        expect(queue_a).not_to be(queue_b)
        expect(queue_b).not_to be(queue_c)
        expect(queue_a).not_to be(queue_c)
      end

      it 'caches even when called in different contexts' do
        # Simulate different code paths calling .to()
        queue_from_branch_a = output_queue.to(:stage_a)

        queue_from_branch_b = output_queue.to(:stage_a)

        expect(queue_from_branch_a).to be(queue_from_branch_b)
      end
    end

    context 'routed OutputQueue behavior' do
      it 'sends items only to the target queue' do
        routed_queue = output_queue.to(:stage_a)
        routed_queue << 42

        # Check that only stage_a received the item
        expect(all_stage_queues[stage_a].size).to eq(1)
        expect(all_stage_queues[stage_a].pop).to eq(42)

        # Other stages should not have received it
        expect(all_stage_queues[stage_b].size).to eq(0)
        expect(all_stage_queues[stage_c].size).to eq(0)
      end

      it 'shares the same stats object' do
        routed_queue = output_queue.to(:stage_a)

        expect(stage_stats).to receive(:increment_produced).once
        routed_queue << 42
      end

      it 'tracks runtime edges for END signal handling' do
        # Initially no runtime edges
        expect(runtime_edges[test_stage]).to be_empty

        # Call .to() to create runtime edge
        output_queue.to(:stage_a)

        # Runtime edge should be tracked
        expect(runtime_edges[test_stage]).to include(stage_a)

        # Multiple .to() calls to same stage don't duplicate
        output_queue.to(:stage_a)
        expect(runtime_edges[test_stage].size).to eq(1)

        # Different targets are tracked separately
        output_queue.to(:stage_b)
        expect(runtime_edges[test_stage]).to include(stage_a, stage_b)
        expect(runtime_edges[test_stage].size).to eq(2)
      end
    end
  end

  describe 'performance: memoization benefit' do
    it 'demonstrates significant performance improvement with memoization' do
      iterations = 10_000

      # Measure time with memoization (current implementation)
      time_with_cache = Benchmark.realtime do
        iterations.times do
          output_queue.to(:stage_a)
        end
      end

      # Measure time without memoization (simulated by creating new instances)
      time_without_cache = Benchmark.realtime do
        iterations.times do
          described_class.new(
            test_stage,
            [all_stage_queues[stage_a]],
            all_stage_queues,
            runtime_edges,
            pipeline: pipeline,
            stage_stats: stage_stats
          )
        end
      end

      # With memoization should be at least 5x faster
      speedup = time_without_cache / time_with_cache

      puts "\n  Performance comparison (#{iterations} iterations):"
      puts "    Without memoization: #{(time_without_cache * 1000).round(2)}ms"
      puts "    With memoization:    #{(time_with_cache * 1000).round(2)}ms"
      puts "    Speedup:             #{speedup.round(2)}x"

      expect(speedup).to be > 5.0
    end

    it 'maintains constant object allocations with memoization' do
      # Track object_ids to verify we're reusing objects
      object_ids = Set.new

      100.times do
        object_ids << output_queue.to(:stage_a).object_id
      end

      # All calls should return the same object
      expect(object_ids.size).to eq(1)
    end
  end
end

RSpec.describe Minigun::InputQueue do
  let(:raw_queue) { Queue.new }
  let(:test_stage) { double('test_stage', name: :test_stage) }
  let(:source_a) { double('source_a', name: :source_a) }
  let(:source_b) { double('source_b', name: :source_b) }
  let(:sources_expected) { Set.new([source_a, source_b]) }

  let(:input_queue) do
    described_class.new(raw_queue, test_stage, sources_expected)
  end

  describe '#pop' do
    it 'returns items from the raw queue' do
      raw_queue << 42
      raw_queue << 84

      expect(input_queue.pop).to eq(42)
      expect(input_queue.pop).to eq(84)
    end

    it 'tracks EndOfSource signals from sources and returns EndOfStage' do
      # Add EndOfSource signals from all sources
      raw_queue << Minigun::EndOfSource.new(source_a)
      raw_queue << Minigun::EndOfSource.new(source_b)

      # First pop processes all EndOfSource signals and returns EndOfStage
      result = input_queue.pop

      expect(result).to be_a(Minigun::EndOfStage)
      expect(result.stage).to eq(test_stage)
    end

    it 'returns EndOfStage when all sources are done' do
      sources_expected.each do |source|
        raw_queue << Minigun::EndOfSource.new(source)
      end

      # Pop automatically consumes all EndOfSource signals and returns EndOfStage
      expect(input_queue.pop).to be_a(Minigun::EndOfStage)
    end

    it 'handles mixed items and EndOfSource signals' do
      raw_queue << 1
      raw_queue << Minigun::EndOfSource.new(source_a)
      raw_queue << 2
      raw_queue << Minigun::EndOfSource.new(source_b)

      # Pop returns regular items, automatically consuming EndOfSource signals
      expect(input_queue.pop).to eq(1)
      expect(input_queue.pop).to eq(2) # EndOfSource signal from source_a is auto-consumed

      # After both items, both EndOfSource signals are consumed, returns EndOfStage
      expect(input_queue.pop).to be_a(Minigun::EndOfStage)
    end
  end
end
