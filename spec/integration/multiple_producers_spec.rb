# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Multiple Producers' do
  describe 'pipeline with multiple producer stages' do
    it 'runs all producers concurrently' do
      test_class = Class.new do
        include Minigun::DSL

        attr_accessor :results

        def initialize
          @results = []
          @mutex = Mutex.new
        end

        pipeline do
          producer :source_a do |output|
            5.times do |i|
              output << "A#{i}"
            end
          end

          producer :source_b do |output|
            5.times do |i|
              output << "B#{i}"
            end
          end

          consumer :collect do |item|
            @mutex.synchronize { @results << item }
          end
        end
      end

      instance = test_class.new
      instance.run

      # Should have items from both producers
      expect(instance.results.size).to eq(10)
      expect(instance.results.count { |i| i.start_with?('A') }).to eq(5)
      expect(instance.results.count { |i| i.start_with?('B') }).to eq(5)
    end

    it 'routes each producer to different downstream stages' do
      test_class = Class.new do
        include Minigun::DSL

        attr_accessor :results_x, :results_y

        def initialize
          @results_x = []
          @results_y = []
          @mutex = Mutex.new
        end

        pipeline do
          producer :source_x, to: :process_x do |output|
            3.times do |i|
              output << i
            end
          end

          producer :source_y, to: :process_y do |output|
            3.times do |i|
              output << (i + 100)
            end
          end

          processor :process_x, to: :collect_x do |item, output|
            output << (item * 10)
          end

          processor :process_y, to: :collect_y do |item, output|
            output << (item * 2)
          end

          consumer :collect_x do |item, _output|
            @mutex.synchronize { @results_x << item }
          end

          consumer :collect_y do |item, _output|
            @mutex.synchronize { @results_y << item }
          end
        end
      end

      instance = test_class.new
      instance.run

      # Source X: 0,1,2 -> *10 = 0,10,20
      expect(instance.results_x.sort).to eq([0, 10, 20])

      # Source Y: 100,101,102 -> *2 = 200,202,204
      expect(instance.results_y.sort).to eq([200, 202, 204])
    end

    it 'tracks statistics for each producer separately' do
      test_class = Class.new do
        include Minigun::DSL

        attr_accessor :results

        def initialize
          @results = []
        end

        pipeline do
          producer :fast_producer do |output|
            10.times { |i| output << i }
          end

          producer :slow_producer do |output|
            5.times { |i| output << (i + 100) }
          end

          consumer :collect do |item|
            @results << item
          end
        end
      end

      instance = test_class.new
      instance.run

      # Get stats from instance task (not class task)
      task = instance._minigun_task
      pipeline = task.root_pipeline
      stats = pipeline.stats

      # Should have stats for both producers (look up by stage object)
      fast_producer = pipeline.find_stage(:fast_producer)
      slow_producer = pipeline.find_stage(:slow_producer)
      
      fast_stats = stats.stage_stats[fast_producer]
      slow_stats = stats.stage_stats[slow_producer]

      expect(fast_stats).not_to be_nil
      expect(slow_stats).not_to be_nil

      expect(fast_stats.items_produced).to eq(10)
      expect(slow_stats.items_produced).to eq(5)

      # Total produced should be sum of both
      expect(stats.total_produced).to eq(15)
    end

    it 'handles producer errors gracefully' do
      test_class = Class.new do
        include Minigun::DSL

        attr_accessor :results

        def initialize
          @results = []
          @mutex = Mutex.new
        end

        pipeline do
          producer :good_producer do |output|
            3.times { |i| output << i }
          end

          producer :bad_producer do |_output|
            raise StandardError, 'Producer error'
          end

          consumer :collect do |item|
            @mutex.synchronize { @results << item }
          end
        end
      end

      instance = test_class.new

      # Should still process items from good producer
      expect { instance.run }.not_to raise_error

      # Should have items from the good producer
      expect(instance.results.size).to eq(3)
    end
  end

  describe 'pipeline with single producer (backward compatibility)' do
    it 'still works correctly with one producer' do
      test_class = Class.new do
        include Minigun::DSL

        attr_accessor :results

        def initialize
          @results = []
        end

        pipeline do
          producer :source do |output|
            5.times { |i| output << i }
          end

          consumer :collect do |item|
            @results << item
          end
        end
      end

      instance = test_class.new
      instance.run

      expect(instance.results.size).to eq(5)
    end
  end
end
