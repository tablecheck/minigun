# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Yield Syntax Support' do
  describe 'ProducerStage with yield' do
    it 'supports call method with output parameter' do
      producer_stage = Class.new(Minigun::ProducerStage) do
        def call(_output)
          3.times { |i| yield i }
        end
      end

      results = []
      mutex = Mutex.new

      example_class = Class.new do
        include Minigun::DSL

        define_method(:results) { results }
        define_method(:mutex) { mutex }
        define_method(:producer_stage) { producer_stage }

        pipeline do
          custom_stage(producer_stage, :generate)
          consumer :collect do |item|
            mutex.synchronize { results << item }
          end
        end
      end

      example_class.new.run
      expect(results.sort).to eq([0, 1, 2])
    end

    it 'supports call method without parameters (arity 0)' do
      producer_stage = Class.new(Minigun::ProducerStage) do
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
        define_method(:producer_stage) { producer_stage }

        pipeline do
          custom_stage(producer_stage, :generate)
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
      consumer_stage = Class.new(Minigun::ConsumerStage) do
        def call(item, _output)
          yield(item * 2)
        end
      end

      results = []
      mutex = Mutex.new

      example_class = Class.new do
        include Minigun::DSL

        define_method(:results) { results }
        define_method(:mutex) { mutex }
        define_method(:consumer_stage) { consumer_stage }

        pipeline do
          producer :generate do |output|
            3.times { |i| output << i }
          end
          custom_stage(consumer_stage, :transform)
          consumer :collect do |item|
            mutex.synchronize { results << item }
          end
        end
      end

      example_class.new.run
      expect(results.sort).to eq([0, 2, 4])
    end

    it 'supports call method with only item parameter (arity 1)' do
      consumer_stage = Class.new(Minigun::ConsumerStage) do
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
        define_method(:consumer_stage) { consumer_stage }

        pipeline do
          producer :generate do |output|
            3.times { |i| output << i }
          end
          custom_stage(consumer_stage, :transform)
          consumer :collect do |item|
            mutex.synchronize { results << item }
          end
        end
      end

      example_class.new.run
      expect(results.sort).to eq([0, 2, 4])
    end

    it 'supports terminal consumer with only item parameter' do
      terminal_stage_class = Class.new(Minigun::ConsumerStage) do
        attr_reader :items_received

        def initialize(pipeline, name, block, options = {})
          super
          @items_received = []
          @mutex = Mutex.new
        end

        def call(item)
          @mutex.synchronize { @items_received << item }
        end
      end

      example_class = Class.new do
        include Minigun::DSL

        define_method(:terminal_stage_class) { terminal_stage_class }

        pipeline do
          producer :generate do |output|
            3.times { |i| output << i }
          end
          custom_stage(terminal_stage_class, :terminal)
        end
      end

      instance = example_class.new
      instance.run

      # Get the actual stage instance from the pipeline
      actual_stage = instance._minigun_task.root_pipeline.find_stage(:terminal)
      expect(actual_stage.items_received.sort).to eq([0, 1, 2])
    end
  end

  describe 'Base Stage with yield' do
    it 'supports loop-based stage with call method' do
      loop_stage = Class.new(Minigun::Stage) do
        def call(input_queue, _output_queue)
          loop do
            item = input_queue.pop
            break if item.is_a?(Minigun::EndOfStage)

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
        define_method(:loop_stage) { loop_stage }

        pipeline do
          producer :generate do |output|
            3.times { |i| output << i }
          end
          custom_stage(loop_stage, :transform)
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
    it 'supports yield(item, to: :stage_name) - known limitation with dynamic routing', skip: 'Known limitation with dynamic routing' do
      router_stage = Class.new(Minigun::ConsumerStage) do
        def call(item, _output)
          if item.even?
            yield(item, to: :even_processor)
          else
            yield(item, to: :odd_processor)
          end
        end
      end

      even_processor_stage = Class.new(Minigun::ConsumerStage) do
        def call(item)
          yield(item * 2)
        end
      end

      odd_processor_stage = Class.new(Minigun::ConsumerStage) do
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
        define_method(:router_stage) { router_stage }
        define_method(:even_processor_stage) { even_processor_stage }
        define_method(:odd_processor_stage) { odd_processor_stage }

        pipeline do
          producer :generate do |output|
            5.times { |i| output << i }
          end
          custom_stage(router_stage, :router)
          custom_stage(even_processor_stage, :even_processor)
          custom_stage(odd_processor_stage, :odd_processor)
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
      processor_stage = Class.new(Minigun::ConsumerStage) do
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
        define_method(:processor_stage) { processor_stage }

        pipeline do
          # Block-based producer
          producer :generate do |output|
            3.times { |i| output << i }
          end
          # Class-based processor with yield
          custom_stage(processor_stage, :transform)
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
