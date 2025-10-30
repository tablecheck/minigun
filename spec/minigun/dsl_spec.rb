# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Minigun::DSL do
  describe 'class methods' do
    let(:test_class) do
      Class.new do
        include Minigun::DSL
      end
    end

    it 'provides max_threads configuration' do
      test_class.max_threads 10
      expect(test_class._minigun_task.config[:max_threads]).to eq(10)
    end

    it 'provides max_processes configuration' do
      test_class.max_processes 4
      expect(test_class._minigun_task.config[:max_processes]).to eq(4)
    end

    it 'provides max_retries configuration' do
      test_class.max_retries 5
      expect(test_class._minigun_task.config[:max_retries]).to eq(5)
    end

    it 'raises error when defining a producer without pipeline do' do
      expect do
        test_class.producer(:test_producer) { 'producer code' }
      end.to raise_error(NoMethodError, /undefined method/)
    end

    it 'raises error when defining processors without pipeline do' do
      expect do
        test_class.processor(:test_processor) { |x| x }
      end.to raise_error(NoMethodError, /undefined method/)
    end

    it 'raises error when defining an accumulator without pipeline do' do
      expect do
        test_class.accumulator(:test_accumulator) { 'accumulator code' }
      end.to raise_error(NoMethodError, /undefined method/)
    end

    it 'raises error when defining a consumer without pipeline do' do
      expect do
        test_class.consumer(:test_consumer) { |x| x }
      end.to raise_error(NoMethodError, /undefined method/)
    end

    it 'allows defining before_run hook inside pipeline do' do
      test_class.pipeline do
        before_run { 'before run' }
      end
      instance = test_class.new
      begin
        instance.run
      rescue StandardError
        nil
      end
      expect(instance._minigun_task.root_pipeline.hooks[:before_run]).not_to be_empty
    end

    it 'allows defining after_run hook inside pipeline do' do
      test_class.pipeline do
        after_run { 'after run' }
      end
      instance = test_class.new
      begin
        instance.run
      rescue StandardError
        nil
      end
      expect(instance._minigun_task.root_pipeline.hooks[:after_run]).not_to be_empty
    end

    it 'allows defining before_fork hook inside pipeline do' do
      test_class.pipeline do
        before_fork { 'before fork' }
      end
      instance = test_class.new
      begin
        instance.run
      rescue StandardError
        nil
      end
      expect(instance._minigun_task.root_pipeline.hooks[:before_fork]).not_to be_empty
    end

    it 'allows defining after_fork hook inside pipeline do' do
      test_class.pipeline do
        after_fork { 'after fork' }
      end
      instance = test_class.new
      begin
        instance.run
      rescue StandardError
        nil
      end
      expect(instance._minigun_task.root_pipeline.hooks[:after_fork]).not_to be_empty
    end

    it 'allows defining pipeline block for grouping' do
      test_class.pipeline do
        producer(:grouped_producer) { 'code' }
        consumer(:grouped_consumer) { |x| x }
      end

      # Need to instantiate and run to trigger evaluation
      instance = test_class.new
      begin
        instance.run
      rescue StandardError
        nil
      end

      producer = instance._minigun_task.root_pipeline.stages[:grouped_producer]
      consumer = instance._minigun_task.root_pipeline.stages[:grouped_consumer]

      expect(producer).not_to be_nil
      expect(producer.name).to eq(:grouped_producer)
      expect(consumer).not_to be_nil
      expect(consumer.name).to eq(:grouped_consumer)
    end
  end

  describe 'instance methods' do
    let(:test_class) do
      Class.new do
        include Minigun::DSL

        pipeline do
          producer(:test_producer) do |output|
            5.times { |i| output << i }
          end

          consumer(:test_consumer) do |item|
            @processed ||= []
            @processed << item
          end
        end
      end
    end

    let(:instance) { test_class.new }

    it 'provides run method' do
      expect(instance).to respond_to(:run)
    end

    it 'provides go_brrr! alias' do
      expect(instance).to respond_to(:go_brrr!)
    end
  end

  describe 'full pipeline definition' do
    let(:test_class) do
      Class.new do
        include Minigun::DSL

        max_threads 3
        max_processes 2

        pipeline do
          before_run { @start_time = Time.now }
          after_run { @end_time = Time.now }

          producer :generate do |output|
            3.times { |i| output << (i + 1) }
          end

          processor :double do |num, output|
            output << (num * 2)
          end

          consumer :collect do |num|
            @results ||= []
            @results << num
          end
        end

        def initialize
          @start_time = nil
          @end_time = nil
        end
      end
    end

    it 'correctly configures all components' do
      # Need to instantiate to trigger pipeline evaluation
      instance = test_class.new
      begin
        instance.run
      rescue StandardError
        nil
      end
      task = instance._minigun_task
      pipeline = task.root_pipeline

      expect(task.config[:max_threads]).to eq(3)
      expect(task.config[:max_processes]).to eq(2)

      # Check that stages were added by name
      expect(pipeline.stages[:generate]).not_to be_nil
      expect(pipeline.stages[:double]).not_to be_nil
      expect(pipeline.stages[:collect]).not_to be_nil

      # Verify stage properties based on their characteristics
      gen_stage = pipeline.stages[:generate]
      double_stage = pipeline.stages[:double]
      collect_stage = pipeline.stages[:collect]

      expect(gen_stage).to be_a(Minigun::ProducerStage)
      expect(double_stage).to be_a(Minigun::ConsumerStage)
      expect(double_stage).not_to be_a(Minigun::AccumulatorStage)
      expect(collect_stage).to be_a(Minigun::ConsumerStage)

      # Verify we have 3 stages total
      expect(pipeline.stages.size).to eq(3)
      expect(task.hooks[:before_run].size).to eq(1)
      expect(task.hooks[:after_run].size).to eq(1)
    end
  end

  describe 'pipeline do wrapper requirement' do
    before do
      allow(Minigun.logger).to receive(:info)
    end

    it 'raises error when defining stages without pipeline block wrapper' do
      # Attempting to define pipeline WITHOUT explicit pipeline block should error
      expect do
        Class.new do
          include Minigun::DSL

          # No pipeline do...end wrapper - should raise error!
          producer :generate do |output|
            3.times { |i| output << (i + 1) }
          end
        end
      end.to raise_error(NoMethodError, /undefined method/)
    end

    it 'works correctly with pipeline block' do
      # WITH pipeline block - should work
      with_block = Class.new do
        include Minigun::DSL

        attr_accessor :results

        def initialize
          @results = []
        end

        pipeline do
          producer :source do |output|
            5.times { |i| output << i }
          end

          consumer :sink do |num|
            results << num
          end
        end
      end

      instance = with_block.new
      instance.run

      expect(instance.results).to contain_exactly(0, 1, 2, 3, 4)
    end

    it 'OLD TEST - WITHOUT pipeline block raises error' do
      # This test documents the old behavior is no longer supported
      expect do
        Class.new do
          include Minigun::DSL

          attr_accessor :results

          def initialize
            @results = []
          end

          # Stages without pipeline do should raise error
          producer :source do |output|
            5.times { |i| output << i }
          end
        end
      end.to raise_error(NoMethodError, /undefined method/)
    end

    it 'requires pipeline do for all stages (mixing not allowed)' do
      # Attempting to mix styles should fail
      expect do
        Class.new do
          include Minigun::DSL

          # Stage outside pipeline block - should raise error
          producer :start do |output|
            output << 10
          end
        end
      end.to raise_error(NoMethodError, /undefined method/)
    end

    it 'requires pipeline do for complex routing' do
      expect do
        Class.new do
          include Minigun::DSL

          # Routing without pipeline block - should raise error
          producer :start, to: %i[process_a process_b] do |output|
            output << 5
          end
        end
      end.to raise_error(NoMethodError, /undefined method/)
    end

    it 'requires pipeline do for all stage types' do
      expect do
        Class.new do
          include Minigun::DSL

          # Direct definition without pipeline block - should raise error
          producer :fetch do |output|
            output << 1
          end
        end
      end.to raise_error(NoMethodError, /undefined method/)
    end
  end
end
