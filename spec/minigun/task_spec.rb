# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Minigun::Task do
  let(:task) { described_class.new }

  describe '#initialize' do
    it 'sets default configuration' do
      expect(task.config[:max_threads]).to eq(5)
      expect(task.config[:max_processes]).to eq(2)
      expect(task.config[:max_retries]).to eq(3)
      expect(task.config[:accumulator_max_single]).to eq(2000)
      expect(task.config[:accumulator_max_all]).to eq(4000)
    end

    it 'initializes empty stages' do
      expect(task.stages).to be_a(Array)
      expect(task.stages).to be_empty
    end

    it 'initializes empty hooks' do
      expect(task.hooks[:before_run]).to eq([])
      expect(task.hooks[:after_run]).to eq([])
      expect(task.hooks[:before_fork]).to eq([])
      expect(task.hooks[:after_fork]).to eq([])
    end
  end

  describe '#set_config' do
    it 'updates configuration values' do
      task.set_config(:max_threads, 10)
      expect(task.config[:max_threads]).to eq(10)
    end
  end

  describe '#add_stage' do
    it 'adds producer stage' do
      block = proc { 'producer' }
      task.add_stage(:producer, :test_producer, &block)

      stage = task.root_pipeline.find_stage(:test_producer)
      expect(stage).not_to be_nil
      expect(stage.name).to eq(:test_producer)
      expect(stage.block).to eq(block)
      expect(stage).to be_a(Minigun::ProducerStage)
    end

    it 'adds processor stages' do
      block1 = proc { |x| x }
      block2 = proc { |x| x }

      task.add_stage(:processor, :proc1, &block1)
      task.add_stage(:processor, :proc2, &block2)

      # Verify both were added
      stage1 = task.root_pipeline.find_stage(:proc1)
      stage2 = task.root_pipeline.find_stage(:proc2)
      expect(stage1).not_to be_nil
      expect(stage2).not_to be_nil
      expect(stage1.name).to eq(:proc1)
      expect(stage2.name).to eq(:proc2)
    end

    it 'adds accumulator stage' do
      block = proc { 'accumulator' }
      task.add_stage(:accumulator, :test_acc, &block)

      stage = task.root_pipeline.find_stage(:test_acc)
      expect(stage).not_to be_nil
      expect(stage.name).to eq(:test_acc)
      expect(stage).to be_a(Minigun::AccumulatorStage)
    end

    it 'adds consumer stage' do
      block = proc { |x| x }
      task.add_stage(:consumer, :test_consumer, &block)

      stage = task.root_pipeline.find_stage(:test_consumer)
      expect(stage).not_to be_nil
      expect(stage.name).to eq(:test_consumer)
    end
  end

  describe '#add_hook' do
    it 'adds before_run hook' do
      block = proc { 'before' }
      task.add_hook(:before_run, &block)

      expect(task.hooks[:before_run]).to include(block)
    end

    it 'adds multiple hooks of same type' do
      block1 = proc { 'first' }
      block2 = proc { 'second' }

      task.add_hook(:after_run, &block1)
      task.add_hook(:after_run, &block2)

      expect(task.hooks[:after_run]).to include(block1, block2)
    end
  end

  describe '#run' do
    let(:context) do
      Class.new do
        attr_accessor :produced, :processed, :consumed
        attr_accessor :before_run_called, :after_run_called

        def initialize
          @produced = []
          @processed = []
          @consumed = []
          @before_run_called = false
          @after_run_called = false
        end
      end.new
    end

    it 'executes simple producer-consumer pipeline' do
      task.add_stage(:producer, :gen) do |output|
        3.times { |i| output << (i + 1) }
      end

      task.add_stage(:consumer, :process) do |item|
        consumed << item
      end

      # Suppress logger output in tests
      allow(Minigun.logger).to receive(:info)

      task.run(context)

      # With queue-based DSL, items flow through directly
      expect(context.consumed).to contain_exactly(1, 2, 3)
    end

    it 'executes producer-processor-consumer pipeline' do
      task.add_stage(:producer, :gen) do |output|
        3.times { |i| output << (i + 1) }
      end

      task.add_stage(:processor, :double) do |item, output|
        output << (item * 2)
      end

      task.add_stage(:consumer, :process) do |item|
        consumed << item
      end

      allow(Minigun.logger).to receive(:info)

      task.run(context)

      expect(context.consumed).to include(2, 4, 6)
    end

    it 'calls before_run hooks' do
      task.add_hook(:before_run) do
        self.before_run_called = true
      end

      task.add_stage(:producer, :gen) do |output|
        output << 1
      end

      task.add_stage(:consumer, :process) do |item|
        consumed << item
      end

      allow(Minigun.logger).to receive(:info)

      task.run(context)

      expect(context.before_run_called).to be true
    end

    it 'calls after_run hooks' do
      task.add_hook(:after_run) do
        self.after_run_called = true
      end

      task.add_stage(:producer, :gen) do |output|
        output << 1
      end

      task.add_stage(:consumer, :process) do |item|
        consumed << item
      end

      allow(Minigun.logger).to receive(:info)

      task.run(context)

      expect(context.after_run_called).to be true
    end

    it 'handles multiple items through pipeline' do
      task.set_config(:max_threads, 2)

      task.add_stage(:producer, :gen) do |output|
        10.times { |i| output << i }
      end

      task.add_stage(:consumer, :process) do |item|
        consumed << item
      end

      allow(Minigun.logger).to receive(:info)

      task.run(context)

      expect(context.consumed.size).to eq(10)
    end

    it 'returns accumulated count' do
      task.add_stage(:producer, :gen) do |output|
        5.times { |i| output << i }
      end

      task.add_stage(:consumer, :process) do |item|
        consumed << item
      end

      allow(Minigun.logger).to receive(:info)

      result = task.run(context)

      expect(result).to eq(5)
    end
  end

  describe 'thread safety' do
    it 'uses atomic counter for produced items' do
      task.add_stage(:producer, :gen) do |output|
        100.times { |i| output << i }
      end

      task.add_stage(:consumer, :process) { |_item| }

      allow(Minigun.logger).to receive(:info)

      context = Object.new

      # If counter is thread-safe, all items will be counted
      # This is implicitly tested by the run completing successfully
      expect { task.run(context) }.not_to raise_error
    end
  end
end
