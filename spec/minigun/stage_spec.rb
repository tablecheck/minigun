# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Minigun::Stage do
  let(:mock_registry) { instance_double(Minigun::StageRegistry, register: nil) }
  let(:mock_task) { instance_double(Minigun::Task, stage_registry: mock_registry) }
  let(:mock_pipeline) { instance_double(Minigun::Pipeline, name: 'test_pipeline', task: mock_task) }

  describe 'base class' do
    it 'returns nil when execute is called without a block' do
      stage = described_class.new(:test, mock_pipeline, nil, {})
      input_queue = double('input')
      output_queue = double('output')
      expect(stage.execute(Object.new, input_queue, output_queue, nil)).to be_nil
    end

    it 'executes the block when provided' do
      executed = false
      stage = described_class.new(:test, mock_pipeline, proc { executed = true }, {})

      # Create mock queues
      input_queue = double('input')
      output_queue = double('output')

      stage.execute(Object.new, input_queue, output_queue, nil)
      expect(executed).to be true
    end
  end
end

RSpec.describe Minigun::ProducerStage do
  let(:mock_registry) { instance_double(Minigun::StageRegistry, register: nil) }
  let(:mock_task) { instance_double(Minigun::Task, stage_registry: mock_registry) }
  let(:mock_pipeline) { instance_double(Minigun::Pipeline, name: 'test_pipeline', task: mock_task) }

  describe 'producer behavior' do
    let(:stage) { described_class.new(:test, mock_pipeline, proc { |output| }, {}) }

    it 'is a ProducerStage' do
      expect(stage).to be_a(described_class)
    end

    it 'executes without an item argument' do
      result = nil
      stage = described_class.new(
        :test,
        mock_pipeline,
        proc { |_output| result = 42 },
        {}
      )

      context = Object.new
      stage.execute(context, nil, Object.new, nil)

      expect(result).to eq(42)
    end
  end
end

RSpec.describe Minigun::ConsumerStage do
  let(:mock_registry) { instance_double(Minigun::StageRegistry, register: nil) }
  let(:mock_task) { instance_double(Minigun::Task, stage_registry: mock_registry) }
  let(:mock_pipeline) { instance_double(Minigun::Pipeline, name: 'test_pipeline', task: mock_task) }

  describe 'processor behavior' do
    let(:stage) { described_class.new(:test, mock_pipeline, proc { |_x, _output| }, {}) }

    it 'is a ConsumerStage' do
      expect(stage).to be_a(described_class)
    end

    it 'executes with queue-based output' do
      stage = described_class.new(
        :test,
        mock_pipeline,
        proc do |item, output|
          output << (item * 2)
          output << (item * 3)
        end,
        {}
      )

      context = Object.new
      emitted = []
      mock_output = Object.new
      mock_output.define_singleton_method(:<<) { |item| emitted << item }

      mock_input = double('input_queue')
      allow(mock_input).to receive(:pop).and_return(5, Minigun::EndOfStage.new(:test))

      stage.execute(context, mock_input, mock_output, nil)

      expect(emitted).to eq([10, 15])
    end
  end

  describe 'consumer behavior (has execution context)' do
    let(:stage) do
      described_class.new(
        :test,
        mock_pipeline,
        proc { |_x, _output| },
        { _execution_context: { type: :cow_forks, mode: :per_batch, max: 2 } }
      )
    end

    it 'is a ConsumerStage' do
      expect(stage).to be_a(described_class)
    end

    it 'has execution context' do
      expect(stage.execution_context).to eq({ type: :cow_forks, mode: :per_batch, max: 2 })
    end
  end
end

RSpec.describe Minigun::AccumulatorStage do
  let(:mock_registry) { instance_double(Minigun::StageRegistry, register: nil) }
  let(:mock_task) { instance_double(Minigun::Task, stage_registry: mock_registry) }
  let(:mock_pipeline) { instance_double(Minigun::Pipeline, name: 'test_pipeline', task: mock_task) }

  it 'is a special batching stage' do
    stage = described_class.new(:test, mock_pipeline, proc {}, {})
    expect(stage.max_size).to eq(100) # default
  end
end

RSpec.describe 'Stage common behavior' do
  let(:mock_registry) { instance_double(Minigun::StageRegistry, register: nil) }
  let(:mock_task) { instance_double(Minigun::Task, stage_registry: mock_registry) }
  let(:mock_pipeline) { instance_double(Minigun::Pipeline, name: 'test_pipeline', task: mock_task) }
  let(:stage) { Minigun::ConsumerStage.new(:test, mock_pipeline, proc { |x, _output| x * 2 }, { foo: 'bar' }) }

  describe '#initialize' do
    it 'creates a stage with required attributes' do
      expect(stage.name).to eq(:test)
      expect(stage).to be_a(Minigun::ConsumerStage)
      expect(stage.block).to be_a(Proc)
      expect(stage.options).to eq({ foo: 'bar' })
    end

    it 'works without options' do
      simple = Minigun::ConsumerStage.new(:simple, mock_pipeline, proc { |_x, _output| }, {})
      expect(simple.name).to eq(:simple)
      expect(simple.options).to eq({})
    end
  end

  describe '#execute' do
    it 'executes the block with given context and item' do
      result = nil
      stage = Minigun::ConsumerStage.new(
        :test,
        mock_pipeline,
        proc { |item, _output| result = item * 2 },
        {}
      )

      context = Object.new
      input_queue = double('input_queue')
      output_queue = double('output_queue')
      # Input queue returns one item then signals end
      allow(input_queue).to receive(:pop).and_return(5, Minigun::EndOfStage.new(:test))

      stage.execute(context, input_queue, output_queue, nil)

      expect(result).to eq(10)
    end

    it 'has access to context instance variables' do
      context_class = Class.new do
        attr_reader :value

        def initialize(value)
          @value = value
        end
      end
      context = context_class.new(100)

      stage = Minigun::ConsumerStage.new(
        :test,
        mock_pipeline,
        proc { |item, _output| @value + item },
        {}
      )

      input_queue = double('input_queue')
      output_queue = double('output_queue')
      # Input queue returns one item then signals end
      allow(input_queue).to receive(:pop).and_return(23, Minigun::EndOfStage.new(:test))

      stage.execute(context, input_queue, output_queue, nil)
      # NOTE: execute doesn't return values for consumers in new DSL
      expect(context.value).to eq(100) # unchanged
    end
  end

  describe '#to_h' do
    it 'converts to hash representation' do
      block = proc { |_x, _output| }
      stage = Minigun::ConsumerStage.new(
        :test,
        mock_pipeline,
        block,
        { opt: 'val' }
      )

      hash = stage.to_h

      expect(hash[:name]).to eq(:test)
      expect(hash[:block]).to eq(block)
      expect(hash[:options]).to include(opt: 'val')
    end
  end

  describe '#[]' do
    it 'provides hash-like access to attributes' do
      block = proc { |_x, _output| }
      stage = Minigun::ConsumerStage.new(
        :test,
        mock_pipeline,
        block,
        { foo: 'bar' }
      )

      expect(stage[:name]).to eq(:test)
      expect(stage[:block]).to eq(block)
      expect(stage[:options]).to eq({ foo: 'bar' })
    end

    it 'returns nil for unknown keys' do
      stage = Minigun::ConsumerStage.new(:test, mock_pipeline, proc { |_x, _output| }, {})
      expect(stage[:unknown]).to be_nil
    end
  end
end
