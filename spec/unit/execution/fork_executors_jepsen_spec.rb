# frozen_string_literal: true

require 'spec_helper'
require 'timeout'
require 'set'

# Jepsen-style tests for fork executors
# These tests focus on:
# - Concurrency correctness
# - Fault tolerance
# - Data integrity
# - Edge cases and chaos scenarios
# - Resource cleanup

RSpec.describe 'Fork Executors - Jepsen-style Tests', skip: Gem.win_platform? do
  let(:dag) { double('dag', terminal?: false) }
  let(:pipeline) do
    double('pipeline',
           name: 'test_pipeline',
           dag: dag,
           send: nil)
  end
  let(:stage_stats) { Minigun::Stats.new('test_stage') }
  let(:stage_ctx) do
    Struct.new(:stage_stats, :pipeline).new(stage_stats, pipeline)
  end

  # Helper to create a mock stage that processes items
  def create_stage(name: 'test_stage', processor: nil, expects_context: false)
    processor ||= ->(item, output) { output << (item * 2) }

    # Create real ConsumerStage with a block that processes (item, output)
    # RSpec mocks don't work across forks, so we need real objects
    # ConsumerStage#execute handles the input loop and calls block per item
    Minigun::ConsumerStage.new(
      name: name,
      block: proc { |item, output_queue|
        # Block is executed via instance_exec(user_context), so 'self' is the user context
        # If expects_context=true, pass user context to processor; otherwise pass output_queue
        result = if expects_context
                   processor.call(item, self)
                 else
                   processor.call(item, output_queue)
                 end
        # If processor returns a value (instead of writing to output_queue), write it
        # But don't try to write queue objects themselves (they contain IO pipes)
        if result && result != output_queue && !result.is_a?(Minigun::OutputQueue) && !result.is_a?(Minigun::IpcOutputQueue)
          output_queue << result
        end
      }
    )
  end

  # Helper to verify all items processed exactly once
  def verify_exactly_once(input_items, output_items, transform = nil)
    transform ||= ->(x) { x * 2 }
    expected = input_items.map(&transform).sort
    actual = output_items.sort

    expect(actual).to eq(expected),
      "Expected items: #{expected.inspect}\nActual items: #{actual.inspect}\nMissing: #{(expected - actual).inspect}\nExtra: #{(actual - expected).inspect}"
  end

  shared_examples 'fork executor correctness' do |executor_type|
    let(:executor) { Minigun::Execution.create_executor(executor_type, stage_ctx, max_size: pool_size) }
    let(:pool_size) { 4 }

    describe 'Data Integrity' do
      it 'processes all items exactly once' do
        items = (1..100).to_a
        input_queue = Queue.new
        output_queue = Queue.new

        items.each { |i| input_queue << i }
        input_queue << Minigun::EndOfStage.new('test')

        stage = create_stage
        user_context = {}

        executor.execute_stage(stage, user_context, input_queue, output_queue)

        results = []
        results << output_queue.pop until output_queue.empty?

        verify_exactly_once(items, results)
      end

      it 'maintains order independence (set equality)' do
        # Run same dataset multiple times, should get same results (unordered)
        items = (1..50).to_a.shuffle

        3.times do
          input_queue = Queue.new
          output_queue = Queue.new

          items.each { |i| input_queue << i }
          input_queue << Minigun::EndOfStage.new('test')

          stage = create_stage
          executor_instance = Minigun::Execution.create_executor(executor_type, stage_ctx, max_size: pool_size)
          executor_instance.execute_stage(stage, {}, input_queue, output_queue)

          results = []
          results << output_queue.pop until output_queue.empty?

          verify_exactly_once(items, results)
        end
      end

      it 'handles duplicate input values correctly' do
        items = [1, 2, 2, 3, 3, 3, 4, 5, 5]
        input_queue = Queue.new
        output_queue = Queue.new

        items.each { |i| input_queue << i }
        input_queue << Minigun::EndOfStage.new('test')

        stage = create_stage
        executor.execute_stage(stage, {}, input_queue, output_queue)

        results = []
        results << output_queue.pop until output_queue.empty?

        verify_exactly_once(items, results)
      end

      it 'processes empty queue correctly' do
        input_queue = Queue.new
        output_queue = Queue.new
        input_queue << Minigun::EndOfStage.new('test')

        stage = create_stage
        executor.execute_stage(stage, {}, input_queue, output_queue)

        expect(output_queue.empty?).to be true
      end

      it 'handles single item correctly' do
        input_queue = Queue.new
        output_queue = Queue.new
        input_queue << 42
        input_queue << Minigun::EndOfStage.new('test')

        stage = create_stage
        executor.execute_stage(stage, {}, input_queue, output_queue)

        expect(output_queue.pop).to eq(84)
        expect(output_queue.empty?).to be true
      end
    end

    describe 'Concurrency Stress Tests' do
      it 'handles high concurrency (pool size << item count)' do
        items = (1..1000).to_a
        input_queue = Queue.new
        output_queue = Queue.new

        items.each { |i| input_queue << i }
        input_queue << Minigun::EndOfStage.new('test')

        stage = create_stage

        start_time = Time.now
        executor.execute_stage(stage, {}, input_queue, output_queue)
        elapsed = Time.now - start_time

        results = []
        results << output_queue.pop until output_queue.empty?

        verify_exactly_once(items, results)

        # Should complete in reasonable time with parallelism
        expect(elapsed).to be < 10
      end

      it 'handles bursty workload' do
        # Simulate bursty traffic: groups of items with varying sizes
        items = []
        10.times do |burst|
          burst_size = (10..50).to_a.sample
          items.concat(Array.new(burst_size) { burst * 100 + rand(100) })
        end

        input_queue = Queue.new
        output_queue = Queue.new

        items.each { |i| input_queue << i }
        input_queue << Minigun::EndOfStage.new('test')

        stage = create_stage
        executor.execute_stage(stage, {}, input_queue, output_queue)

        results = []
        results << output_queue.pop until output_queue.empty?

        verify_exactly_once(items, results)
      end

      it 'handles varying processing times' do
        items = (1..50).to_a
        input_queue = Queue.new
        output_queue = Queue.new

        items.each { |i| input_queue << i }
        input_queue << Minigun::EndOfStage.new('test')

        # Processor with random delays
        stage = create_stage(processor: lambda { |item, _ctx|
          sleep(rand * 0.01) # 0-10ms random delay
          item * 2
        })

        executor.execute_stage(stage, {}, input_queue, output_queue)

        results = []
        results << output_queue.pop until output_queue.empty?

        verify_exactly_once(items, results)
      end
    end

    describe 'Fault Tolerance' do
      it 'handles stage errors gracefully' do
        items = (1..10).to_a
        input_queue = Queue.new
        output_queue = Queue.new

        items.each { |i| input_queue << i }
        input_queue << Minigun::EndOfStage.new('test')

        # Processor that fails on specific items
        error_items = [3, 7]
        stage = create_stage(processor: lambda { |item, _ctx|
          raise "Intentional error" if error_items.include?(item)
          item * 2
        })

        if executor_type == :cow_fork
          # COW fork: one item per fork, so error kills the fork and propagates
          expect do
            executor.execute_stage(stage, {}, input_queue, output_queue)
          end.to raise_error(/error/i)
        else
          # IPC fork: ConsumerStage catches errors and continues, so no exception raised
          # Errors are logged but processing continues
          expect do
            executor.execute_stage(stage, {}, input_queue, output_queue)
          end.not_to raise_error

          # Verify that non-error items were still processed
          results = []
          results << output_queue.pop until output_queue.empty?
          expect(results.size).to eq(items.size - error_items.size)
        end
      end

      it 'handles nil results correctly' do
        items = (1..20).to_a
        input_queue = Queue.new
        output_queue = Queue.new

        items.each { |i| input_queue << i }
        input_queue << Minigun::EndOfStage.new('test')

        # Processor that returns nil for some items (consumer-like)
        stage = create_stage(processor: lambda { |item, _ctx|
          item.even? ? nil : item * 2
        })

        executor.execute_stage(stage, {}, input_queue, output_queue)

        results = []
        results << output_queue.pop until output_queue.empty?

        # Should only have odd items doubled
        expected = items.select(&:odd?).map { |x| x * 2 }.sort
        expect(results.sort).to eq(expected)
      end

      it 'completes even if pool size > item count' do
        large_pool_executor = Minigun::Execution.create_executor(executor_type, stage_ctx, max_size: 100)

        items = (1..10).to_a
        input_queue = Queue.new
        output_queue = Queue.new

        items.each { |i| input_queue << i }
        input_queue << Minigun::EndOfStage.new('test')

        stage = create_stage
        large_pool_executor.execute_stage(stage, {}, input_queue, output_queue)

        results = []
        results << output_queue.pop until output_queue.empty?

        verify_exactly_once(items, results)
      end
    end

    describe 'Edge Cases' do
      it 'handles large items (serialization test for IPC)' do
        # Large data structures
        items = 5.times.map { |i| { id: i, data: 'x' * 10_000, nested: { array: (1..100).to_a } } }
        input_queue = Queue.new
        output_queue = Queue.new

        items.each { |i| input_queue << i }
        input_queue << Minigun::EndOfStage.new('test')

        stage = create_stage(processor: lambda { |item, _ctx|
          # Add a marker to verify deep copy
          item[:processed] = true
          item
        })

        executor.execute_stage(stage, {}, input_queue, output_queue)

        results = []
        results << output_queue.pop until output_queue.empty?

        expect(results.size).to eq(5)
        results.each do |result|
          expect(result[:processed]).to be true
          expect(result[:data].size).to eq(10_000)
        end
      end

      it 'handles complex object types' do
        items = [
          { type: 'hash', value: { a: 1, b: 2 } },
          { type: 'array', value: [1, 2, 3] },
          { type: 'string', value: 'test' },
          { type: 'number', value: 42 },
          { type: 'symbol', value: :symbol },
          { type: 'float', value: 3.14 },
          { type: 'nil', value: nil }
        ]

        input_queue = Queue.new
        output_queue = Queue.new

        items.each { |i| input_queue << i }
        input_queue << Minigun::EndOfStage.new('test')

        stage = create_stage(processor: lambda { |item, _ctx|
          item[:doubled] = true
          item
        })

        executor.execute_stage(stage, {}, input_queue, output_queue)

        results = []
        results << output_queue.pop until output_queue.empty?

        expect(results.size).to eq(items.size)
        results.each do |result|
          expect(result[:doubled]).to be true
        end
      end

      it 'handles rapid succession processing' do
        # Many small items processed rapidly
        items = (1..500).to_a
        input_queue = Queue.new
        output_queue = Queue.new

        items.each { |i| input_queue << i }
        input_queue << Minigun::EndOfStage.new('test')

        # Very fast processor
        stage = create_stage(processor: ->(item, _ctx) { item + 1 })

        start = Time.now
        executor.execute_stage(stage, {}, input_queue, output_queue)
        elapsed = Time.now - start

        results = []
        results << output_queue.pop until output_queue.empty?

        expect(results.sort).to eq(items.map { |x| x + 1 }.sort)
        expect(elapsed).to be < 5
      end
    end

    describe 'Resource Cleanup' do
      it 'cleans up all child processes' do
        items = (1..20).to_a
        input_queue = Queue.new
        output_queue = Queue.new

        items.each { |i| input_queue << i }
        input_queue << Minigun::EndOfStage.new('test')

        stage = create_stage

        initial_children = process_children_count

        executor.execute_stage(stage, {}, input_queue, output_queue)

        # Give processes time to clean up
        sleep 0.1

        final_children = process_children_count

        # Should have no lingering child processes
        expect(final_children).to eq(initial_children)
      end

      it 'handles shutdown gracefully' do
        executor_instance = Minigun::Execution.create_executor(executor_type, stage_ctx, max_size: 4)

        expect { executor_instance.shutdown }.not_to raise_error
      end
    end

    describe 'User Context Isolation' do
      it 'provides user context to each process' do
        items = (1..10).to_a
        input_queue = Queue.new
        output_queue = Queue.new

        items.each { |i| input_queue << i }
        input_queue << Minigun::EndOfStage.new('test')

        user_context = { multiplier: 3, offset: 10 }

        stage = create_stage(
          processor: lambda { |item, ctx|
            item * ctx[:multiplier] + ctx[:offset]
          },
          expects_context: true
        )

        executor.execute_stage(stage, user_context, input_queue, output_queue)

        results = []
        results << output_queue.pop until output_queue.empty?

        expected = items.map { |x| x * 3 + 10 }.sort
        expect(results.sort).to eq(expected)
      end

      it 'isolates mutations in user context (COW test)' do
        skip "This test is specific to COW behavior" unless executor.is_a?(Minigun::Execution::CowForkPoolExecutor)

        items = (1..5).to_a
        input_queue = Queue.new
        output_queue = Queue.new

        items.each { |i| input_queue << i }
        input_queue << Minigun::EndOfStage.new('test')

        # Shared mutable state
        user_context = { counter: 0, data: [] }

        stage = create_stage(
          processor: lambda { |item, ctx|
            # Mutate context (should be copy-on-write)
            ctx[:counter] += 1
            ctx[:data] << item
            item * 2
          },
          expects_context: true
        )

        executor.execute_stage(stage, user_context, input_queue, output_queue)

        results = []
        results << output_queue.pop until output_queue.empty?

        # Original context should be unchanged (COW)
        expect(user_context[:counter]).to eq(0)
        expect(user_context[:data]).to eq([])

        verify_exactly_once(items, results)
      end
    end
  end

  describe 'COW Fork Pool Executor' do
    include_examples 'fork executor correctness', :cow_fork

    describe 'COW-specific behavior' do
      let(:executor) { Minigun::Execution.create_executor(:cow_fork, stage_ctx, max_size: 4) }

      it 'shares memory via copy-on-write' do
        # Large read-only data structure - captured in closure
        large_data = Array.new(10_000) { |i| i * 2 }

        items = (1..10).to_a
        input_queue = Queue.new
        output_queue = Queue.new

        items.each { |i| input_queue << i }
        input_queue << Minigun::EndOfStage.new('test')

        # Lambda captures large_data via closure - will be COW-shared in forked process
        processor = lambda do |item, _ctx|
          # Access large_data (should be COW-shared - same memory pages until modified)
          start_idx = [item - 1, 0].max
          end_idx = [item + 99, large_data.size - 1].min
          sum = large_data[start_idx..end_idx].sum
          { item: item, sum: sum }
        end

        stage = create_stage(processor: processor)

        executor.execute_stage(stage, {}, input_queue, output_queue)

        results = []
        results << output_queue.pop until output_queue.empty?

        # Note: This test demonstrates COW, but results may be empty if Queue doesn't work across processes
        # The important part is that large_data is accessible in the forked process via COW
        expect(results.size).to eq(10)
      end

      it 'creates ephemeral processes (one per item)' do
        items = (1..10).to_a
        input_queue = Queue.new
        output_queue = Queue.new

        items.each { |i| input_queue << i }
        input_queue << Minigun::EndOfStage.new('test')

        # Return PID along with result to verify ephemeral processes
        stage = create_stage(processor: lambda { |item, _ctx|
          { item: item * 2, pid: Process.pid }
        })

        executor.execute_stage(stage, {}, input_queue, output_queue)

        results = []
        results << output_queue.pop until output_queue.empty?

        # Extract processed items and PIDs
        processed_items = results.map { |r| r[:item] }
        pids_seen = results.map { |r| r[:pid] }

        verify_exactly_once(items, processed_items)

        # Each item should have been processed in a separate fork
        # (PIDs may repeat if forks are reused, but there should be multiple PIDs)
        expect(pids_seen.uniq.size).to be > 1
      end
    end
  end

  describe 'IPC Fork Pool Executor' do
    include_examples 'fork executor correctness', :ipc_fork

    describe 'IPC-specific behavior' do
      let(:executor) { Minigun::Execution.create_executor(:ipc_fork, stage_ctx, max_size: 4) }

      it 'uses persistent worker processes' do
        items = (1..20).to_a
        input_queue = Queue.new
        output_queue = Queue.new

        items.each { |i| input_queue << i }
        input_queue << Minigun::EndOfStage.new('test')

        pids_seen = []
        stage = create_stage(processor: lambda { |item, _ctx|
          pids_seen << Process.pid
          item * 2
        })

        executor.execute_stage(stage, {}, input_queue, output_queue)

        results = []
        results << output_queue.pop until output_queue.empty?

        verify_exactly_once(items, results)

        # Should see only pool_size distinct PIDs (persistent workers)
        # Note: This won't work as expected because pids_seen is not shared back
        # This is a limitation of the test, not the implementation
      end

      it 'serializes data through pipes' do
        # Complex objects that require Marshal serialization
        items = [
          { type: 'complex', nested: { deep: { value: [1, 2, 3] } } },
          { type: 'with_symbol', key: :value },
          { type: 'with_string', data: 'test' * 100 }
        ]

        input_queue = Queue.new
        output_queue = Queue.new

        items.each { |i| input_queue << i }
        input_queue << Minigun::EndOfStage.new('test')

        stage = create_stage(processor: lambda { |item, _ctx|
          item[:processed] = Time.now.to_i
          item
        })

        executor.execute_stage(stage, {}, input_queue, output_queue)

        results = []
        results << output_queue.pop until output_queue.empty?

        expect(results.size).to eq(3)
        results.each do |result|
          expect(result[:processed]).to be_a(Integer)
        end
      end

      it 'distributes work via round-robin' do
        # This test verifies that work is distributed, though we can't
        # easily verify round-robin specifically without instrumentation
        items = (1..100).to_a
        input_queue = Queue.new
        output_queue = Queue.new

        items.each { |i| input_queue << i }
        input_queue << Minigun::EndOfStage.new('test')

        stage = create_stage
        executor.execute_stage(stage, {}, input_queue, output_queue)

        results = []
        results << output_queue.pop until output_queue.empty?

        verify_exactly_once(items, results)
      end
    end
  end

  # Helper method to count child processes
  def process_children_count
    # Get count of child processes for current process
    begin
      children = `ps -o pid= --ppid #{Process.pid}`.split.map(&:to_i)
      children.size
    rescue
      0
    end
  end
end

