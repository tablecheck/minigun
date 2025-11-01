# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Isolated Pipelines' do
  describe 'multiple pipelines without to: connections' do
    it 'does not route items between pipelines' do
      test_class = Class.new do
        include Minigun::DSL

        attr_accessor :pipeline_a_results, :pipeline_b_results

        def initialize
          @pipeline_a_results = []
          @pipeline_b_results = []
          @mutex = Mutex.new
        end

        # Pipeline A - standalone
        pipeline do
          pipeline :pipeline_a do
            producer :source_a do |output|
              3.times { |i| output << "A#{i}" }
            end

            consumer :collect_a do |item|
              @mutex.synchronize { @pipeline_a_results << item }
            end
          end
        end

        # Pipeline B - standalone (no connection to A)
        pipeline :pipeline_b do
          producer :source_b do |output|
            2.times { |i| output << "B#{i}" }
          end

          consumer :collect_b do |item|
            @mutex.synchronize { @pipeline_b_results << item }
          end
        end
      end

      instance = test_class.new
      instance.run

      # Each pipeline should only have its own items
      expect(instance.pipeline_a_results.sort).to eq(%w[A0 A1 A2])
      expect(instance.pipeline_b_results.sort).to eq(%w[B0 B1])

      # No cross-contamination
      expect(instance.pipeline_a_results).not_to include('B0', 'B1')
      expect(instance.pipeline_b_results).not_to include('A0', 'A1', 'A2')
    end

    it 'each pipeline operates independently' do
      test_class = Class.new do
        include Minigun::DSL

        attr_accessor :results_x, :results_y, :results_z

        def initialize
          @results_x = []
          @results_y = []
          @results_z = []
          @mutex = Mutex.new
        end

        pipeline :x do
          producer :gen_x do |output|
            output << 10
          end

          consumer :collect_x do |item|
            @mutex.synchronize { @results_x << item }
          end
        end

        pipeline :y do
          producer :gen_y do |output|
            output << 20
          end

          consumer :collect_y do |item|
            @mutex.synchronize { @results_y << item }
          end
        end

        pipeline :z do
          producer :gen_z do |output|
            output << 30
          end

          consumer :collect_z do |item|
            @mutex.synchronize { @results_z << item }
          end
        end
      end

      instance = test_class.new
      instance.run

      # Each pipeline gets only its own item
      expect(instance.results_x).to eq([10])
      expect(instance.results_y).to eq([20])
      expect(instance.results_z).to eq([30])
    end

    it 'does not add :_input node when no to: connection exists' do
      test_class = Class.new do
        include Minigun::DSL

        attr_accessor :results

        def initialize
          @results = []
        end

        pipeline :standalone do
          producer :source do |output|
            output << 1
          end

          consumer :sink do |item|
            @results << item
          end
        end
      end

      instance = test_class.new
      instance.run

      # Verify the pipeline ran successfully
      expect(instance.results).to eq([1])

      # Get the PipelineStage object from instance task
      task = instance._minigun_task
      pipeline_stage = task.root_pipeline.find_stage(:standalone)

      # Verify it's a PipelineStage (nested pipeline)
      expect(pipeline_stage).to be_a(Minigun::PipelineStage)

      # The inner pipeline should not have :_input since no upstream connection
      inner_pipeline = pipeline_stage.nested_pipeline
      expect(inner_pipeline.dag.nodes).not_to include(:_input)
    end
  end
end
