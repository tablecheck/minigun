# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Await Stages' do
  describe 'await: true stages' do
    it 'should not be auto-connected in DAG' do
      results = []

      klass = Class.new do
        include Minigun::DSL

        pipeline do
          producer :gen do |output|
            output << 1
            output << 2
          end

          processor :router do |item, output|
            if item == 1
              output.to(:target_a) << item
            else
              output.to(:target_b) << item
            end
          end

          # These should NOT be auto-connected to router
          processor :target_a, await: true do |item, output|
            output << item
          end

          processor :target_b, await: true do |item, output|
            output << item * 10
          end

          # Explicitly connect collectors
          consumer :collect, from: [:target_a, :target_b] do |item|
            results << item
          end
        end

        define_method(:results) { results }
      end

      instance = klass.new
      # Run to build task and pipeline
      instance.run

      # Now verify DAG structure was correct
      task = instance._minigun_task
      pipeline = task.root_pipeline
      dag = pipeline.instance_variable_get(:@dag)

      # router should not be connected to target_a or target_b in DAG
      router = pipeline.instance_variable_get(:@stages).find { |s| s.name == :router }
      target_a = pipeline.instance_variable_get(:@stages).find { |s| s.name == :target_a }
      target_b = pipeline.instance_variable_get(:@stages).find { |s| s.name == :target_b }

      expect(dag.downstream(router)).not_to include(target_a)
      expect(dag.downstream(router)).not_to include(target_b)

      # target_a should be connected to collect via explicit from:
      collect = pipeline.instance_variable_get(:@stages).find { |s| s.name == :collect }
      expect(dag.upstream(collect)).to include(target_a)

      # target_a and target_b should not be connected to each other
      expect(dag.downstream(target_a)).not_to include(target_b)
      expect(dag.upstream(target_b)).not_to include(target_a)

      # Verify results: item 1 -> target_a (1), item 2 -> target_b (20)
      expect(instance.results.sort).to eq([1, 20])
    end

    it 'should receive items only via dynamic routing' do
      results = []

      klass = Class.new do
        include Minigun::DSL

        pipeline do
          producer :gen do |output|
            3.times { |i| output << i + 1 }
          end

          processor :router do |item, output|
            if item.even?
              output.to(:even_handler) << item
            else
              output.to(:odd_handler) << item
            end
          end

          processor :even_handler, await: true do |item, output|
            output << { item: item, type: :even }
          end

          processor :odd_handler, await: true do |item, output|
            output << { item: item, type: :odd }
          end

          consumer :collect, from: [:even_handler, :odd_handler] do |item|
            results << item
          end
        end

        define_method(:results) { results }
      end

      instance = klass.new
      instance.run

      expect(instance.results.size).to eq(3)
      expect(instance.results.select { |r| r[:type] == :even }.map { |r| r[:item] }).to eq([2])
      expect(instance.results.select { |r| r[:type] == :odd }.map { |r| r[:item] }.sort).to eq([1, 3])
    end

    it 'should work with IPC fork executors' do
      skip 'Forking not supported' unless Minigun.fork?

      results = []
      results_file = "/tmp/minigun_await_ipc_test_#{Process.pid}.txt"

      klass = Class.new do
        include Minigun::DSL

        pipeline do
          producer :gen do |output|
            4.times { |i| output << i + 1 }
          end

          processor :router do |item, output|
            output.to(:ipc_processor) << item
          end

          ipc_fork(2) do
            processor :ipc_processor, await: true do |item, output|
              output << item * 10
            end
          end

          consumer :collect, from: :ipc_processor do |item|
            File.open(results_file, 'a') do |f|
              f.flock(File::LOCK_EX)
              f.puts item.to_s
              f.flock(File::LOCK_UN)
            end
          end
        end
      end

      begin
        instance = klass.new
        instance.run

        if File.exist?(results_file)
          results = File.readlines(results_file).map(&:strip).map(&:to_i).sort
        end

        expect(results).to eq([10, 20, 30, 40])
      ensure
        File.unlink(results_file) if File.exist?(results_file)
      end
    end

    it 'should work with COW fork executors' do
      skip 'Forking not supported' unless Minigun.fork?

      results = []
      results_file = "/tmp/minigun_await_cow_test_#{Process.pid}.txt"

      klass = Class.new do
        include Minigun::DSL

        pipeline do
          producer :gen do |output|
            4.times { |i| output << i + 1 }
          end

          processor :router do |item, output|
            output.to(:cow_processor) << item
          end

          cow_fork(2) do
            processor :cow_processor, await: true do |item, output|
              output << item * 100
            end
          end

          consumer :collect, from: :cow_processor do |item|
            File.open(results_file, 'a') do |f|
              f.flock(File::LOCK_EX)
              f.puts item.to_s
              f.flock(File::LOCK_UN)
            end
          end
        end
      end

      begin
        instance = klass.new
        instance.run

        if File.exist?(results_file)
          results = File.readlines(results_file).map(&:strip).map(&:to_i).sort
        end

        expect(results).to eq([100, 200, 300, 400])
      ensure
        File.unlink(results_file) if File.exist?(results_file)
      end
    end

    it 'should support multiple await stages routing to each other' do
      results = []

      klass = Class.new do
        include Minigun::DSL

        pipeline do
          producer :gen do |output|
            output << 5
          end

          processor :router do |item, output|
            output.to(:stage_a) << item
          end

          processor :stage_a, await: true do |item, output|
            output.to(:stage_b) << item * 2
          end

          processor :stage_b, await: true do |item, output|
            output << item + 3
          end

          consumer :collect, from: :stage_b do |item|
            results << item
          end
        end

        define_method(:results) { results }
      end

      instance = klass.new
      instance.run

      # 5 -> stage_a (5*2=10) -> stage_b (10+3=13)
      expect(instance.results).to eq([13])
    end

  end

  describe 'await: false stages' do
    it 'should terminate immediately when disconnected' do
      # await: false is the default for disconnected stages
      started = []
      completed = []

      klass = Class.new do
        include Minigun::DSL

        pipeline do
          producer :gen do |output|
            started << :gen
            output << 1
          end

          processor :router do |item, output|
            started << :router
            # Don't route to disconnected stage
          end

          # This stage has no upstream and await defaults to false
          # It should start and immediately finish
          processor :disconnected do |item, output|
            started << :disconnected
            output << item
          end

          consumer :collect, from: :router do |item|
            completed << item
          end
        end

        define_method(:started) { started }
        define_method(:completed) { completed }
      end

      instance = klass.new
      instance.run

      # disconnected stage should NOT have started because it has no DAG connections
      # and await: false causes it to shut down immediately
      expect(instance.started).not_to include(:disconnected)
    end
  end

  describe 'mixed await behavior' do
    it 'should support mix of await: true and normal stages' do
      results = { a: [], b: [], c: [] }

      klass = Class.new do
        include Minigun::DSL

        pipeline do
          producer :gen do |output|
            6.times { |i| output << i + 1 }
          end

          # Normal stage - auto-connected
          processor :process do |item, output|
            output << item * 2
          end

          # Router stage - connected to process, makes routing decisions
          processor :router do |item, output|
            if item < 5
              # Route small items to await_stage
              output.to(:await_stage) << item
            else
              # Pass large items through to normal DAG flow
              output << item
            end
          end

          # Disconnected await stage
          processor :await_stage, await: true do |item, output|
            output << { value: item, processed: :await }
          end

          # Normal collection (auto-connected to router)
          # Will receive items that pass through router
          consumer :collect_normal, from: :router do |item|
            results[:c] << item unless item.is_a?(Hash)
          end

          # Explicit collection from await stage
          consumer :collect_await, from: :await_stage do |item|
            results[:a] << item
          end
        end

        define_method(:results) { results }
      end

      instance = klass.new
      instance.run

      # await_stage should receive 2, 4, 6, 8 (doubled values 1,2,3,4 which are < 5 after doubling)
      # Actually: gen produces 1-6, process doubles to 2,4,6,8,10,12
      # router checks if item < 5: only 2, 4 are < 5
      expect(instance.results[:a].size).to eq(2)
      expect(instance.results[:a].map { |r| r[:value] }.sort).to eq([2, 4])

      # collect_normal should receive items >= 5 that pass through: 6, 8, 10, 12
      expect(instance.results[:c].sort).to eq([6, 8, 10, 12])
    end
  end
end
