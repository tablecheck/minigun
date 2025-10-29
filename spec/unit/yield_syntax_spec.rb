# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Yield Syntax Support' do
  describe 'ProducerStage with yield' do
    it 'supports call method with output parameter' do
      class YieldProducerWithOutput < Minigun::ProducerStage
        def call(output)
          3.times { |i| yield i }
        end
      end

      results = []
      mutex = Mutex.new

      example_class = Class.new do
        include Minigun::DSL

        define_method(:results) { results }
        define_method(:mutex) { mutex }

        pipeline do
          custom_stage(YieldProducerWithOutput, :generate)
          consumer :collect do |item|
            mutex.synchronize { results << item }
          end
        end
      end

      example_class.new.run
      expect(results.sort).to eq([0, 1, 2])
    end

    it 'supports call method without parameters (arity 0)' do
      class YieldProducerNoParams < Minigun::ProducerStage
        def call
          3.times { |i| yield i }
        end
      end

      results = []
      mutex = Mutex.new

      example_class = Class.new do
        include Minigun::DSL

        define_method(:results) { results }
        define_method(:mutex) { mutex }

        pipeline do
          custom_stage(YieldProducerNoParams, :generate)
          consumer :collect do |item|
            mutex.synchronize { results << item }
          end
        end
      end

      example_class.new.run
      expect(results.sort).to eq([0, 1, 2])
    end
  end

  describe 'ConsumerStage with yield' do
    it 'supports call method with item and output parameters' do
      class YieldConsumerWithBoth < Minigun::ConsumerStage
        def call(item, output)
          yield(item * 2)
        end
      end

      results = []
      mutex = Mutex.new

      example_class = Class.new do
        include Minigun::DSL

        define_method(:results) { results }
        define_method(:mutex) { mutex }

        pipeline do
          producer :generate do |output|
            3.times { |i| output << i }
          end
          custom_stage(YieldConsumerWithBoth, :transform)
          consumer :collect do |item|
            mutex.synchronize { results << item }
          end
        end
      end

      example_class.new.run
      expect(results.sort).to eq([0, 2, 4])
    end

    it 'supports call method with only item parameter (arity 1)' do
      class YieldConsumerItemOnly < Minigun::ConsumerStage
        def call(item)
          yield(item * 2)
        end
      end

      results = []
      mutex = Mutex.new

      example_class = Class.new do
        include Minigun::DSL

        define_method(:results) { results }
        define_method(:mutex) { mutex }

        pipeline do
          producer :generate do |output|
            3.times { |i| output << i }
          end
          custom_stage(YieldConsumerItemOnly, :transform)
          consumer :collect do |item|
            mutex.synchronize { results << item }
          end
        end
      end

      example_class.new.run
      expect(results.sort).to eq([0, 2, 4])
    end

    it 'supports terminal consumer with only item parameter' do
      class YieldTerminalConsumer < Minigun::ConsumerStage
        attr_reader :items_received

        def initialize(**args)
          super(**args)
          @items_received = []
          @mutex = Mutex.new
        end

        def call(item)
          @mutex.synchronize { @items_received << item }
        end
      end

      terminal_stage = YieldTerminalConsumer.new(name: :terminal)

      example_class = Class.new do
        include Minigun::DSL

        define_method(:terminal_stage) { terminal_stage }

        pipeline do
          producer :generate do |output|
            3.times { |i| output << i }
          end
          custom_stage(terminal_stage.class, :terminal)
        end
      end

      instance = example_class.new
      instance.run

      # Get the actual stage instance from the pipeline
      actual_stage = instance._minigun_task.root_pipeline.stages[:terminal]
      expect(actual_stage.items_received.sort).to eq([0, 1, 2])
    end
  end

  describe 'Base Stage with yield' do
    it 'supports loop-based stage with call method' do
      class YieldLoopStage < Minigun::Stage
        def call(input_queue, output_queue)
          loop do
            item = input_queue.pop
            break if item.is_a?(Minigun::AllUpstreamsDone)
            yield(item * 3)
          end
        end
      end

      results = []
      mutex = Mutex.new

      example_class = Class.new do
        include Minigun::DSL

        define_method(:results) { results }
        define_method(:mutex) { mutex }

        pipeline do
          producer :generate do |output|
            3.times { |i| output << i }
          end
          custom_stage(YieldLoopStage, :transform)
          consumer :collect do |item|
            mutex.synchronize { results << item }
          end
        end
      end

      example_class.new.run
      expect(results.sort).to eq([0, 3, 6])
    end
  end

  describe 'yield with routing' do
    # Known limitation: stages with only dynamically-routed inputs don't wait for input
    # This is tracked separately as a general dynamic routing limitation
    xit 'supports yield(item, to: :stage_name)' do
      class YieldRouterStage < Minigun::ConsumerStage
        def call(item, output)
          if item.even?
            yield(item, to: :even_processor)
          else
            yield(item, to: :odd_processor)
          end
        end
      end

      class YieldEvenProcessor < Minigun::ConsumerStage
        def call(item)
          yield(item * 2)
        end
      end

      class YieldOddProcessor < Minigun::ConsumerStage
        def call(item)
          yield(item * 3)
        end
      end

      even_results = []
      odd_results = []
      mutex = Mutex.new

      example_class = Class.new do
        include Minigun::DSL

        define_method(:even_results) { even_results }
        define_method(:odd_results) { odd_results }
        define_method(:mutex) { mutex }

        pipeline do
          producer :generate do |output|
            5.times { |i| output << i }
          end
          custom_stage(YieldRouterStage, :router)
          custom_stage(YieldEvenProcessor, :even_processor)
          custom_stage(YieldOddProcessor, :odd_processor)
          consumer :collect_even, from: :even_processor do |item|
            mutex.synchronize { even_results << item }
          end
          consumer :collect_odd, from: :odd_processor do |item|
            mutex.synchronize { odd_results << item }
          end
        end
      end

      example_class.new.run
      expect(even_results.sort).to eq([0, 4, 8])
      expect(odd_results.sort).to eq([3, 9, 15])
    end
  end

  describe 'mixed block and class-based stages' do
    it 'allows mixing block-based and class-based stages' do
      class YieldMixedProcessor < Minigun::ConsumerStage
        def call(item)
          yield(item * 2)
        end
      end

      results = []
      mutex = Mutex.new

      example_class = Class.new do
        include Minigun::DSL

        define_method(:results) { results }
        define_method(:mutex) { mutex }

        pipeline do
          # Block-based producer
          producer :generate do |output|
            3.times { |i| output << i }
          end
          # Class-based processor with yield
          custom_stage(YieldMixedProcessor, :transform)
          # Block-based consumer
          consumer :collect do |item|
            mutex.synchronize { results << item }
          end
        end
      end

      example_class.new.run
      expect(results.sort).to eq([0, 2, 4])
    end
  end
end

