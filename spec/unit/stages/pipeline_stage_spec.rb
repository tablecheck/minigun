# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Minigun::PipelineStage do
  let(:config) { { max_threads: 2, max_processes: 1 } }
  let(:mock_context) { Object.new }
  let(:mock_registry) { instance_double(Minigun::StageRegistry, register: nil) }
  let(:mock_task) { instance_double(Minigun::Task, stage_registry: mock_registry) }
  let(:mock_pipeline) { instance_double(Minigun::Pipeline, name: 'test_pipeline', context: mock_context, task: mock_task) }

  describe '#initialize' do
    it 'creates a PipelineStage with a nested pipeline' do
      nested = Minigun::Pipeline.new(:nested, nil, nil, config)
      stage = described_class.new(:my_pipeline, mock_pipeline, nested, nil, {})
      expect(stage.name).to eq(:my_pipeline)
      expect(stage.nested_pipeline).to eq(nested)
    end
  end

  describe '#run_mode' do
    it 'returns :composite' do
      nested = Minigun::Pipeline.new(:nested, nil, nil, config)
      stage = described_class.new(:my_pipeline, mock_pipeline, nested, nil, {})
      expect(stage.run_mode).to eq(:composite)
    end
  end


  describe '#run_stage' do
    it 'returns early if no pipeline is set' do
      stage = described_class.new( :my_pipeline, nil, nil, {})
      stage_ctx = instance_double(Minigun::StageContext,
                                  pipeline: mock_pipeline,
                                  stage: stage,
                                  sources_expected: Set.new,
                                  input_queue: Queue.new,
                                  dag: instance_double(Minigun::DAG, downstream: []),
                                  stage_input_queues: {},
                                  runtime_edges: {},
                                  stage_name: :my_pipeline)

      # Should not raise, just return
      expect { stage.run_stage(stage_ctx) }.not_to raise_error
    end

    it 'runs the nested pipeline when pipeline is set' do
      context = Object.new
      root_pipeline_mock = instance_double(Minigun::Pipeline, context: context)
      nested_pipeline = instance_double(Minigun::Pipeline, context: context)
      stage = described_class.new(:my_pipeline, root_pipeline_mock, nested_pipeline, nil, {})

      stage_ctx = instance_double(Minigun::StageContext,
                                  pipeline: root_pipeline_mock,
                                  root_pipeline: root_pipeline_mock,
                                  stage: stage,
                                  sources_expected: Set.new,
                                  input_queue: Queue.new,
                                  dag: instance_double(Minigun::DAG, downstream: []),
                                  stage_input_queues: {},
                                  runtime_edges: {},
                                  stage_name: :my_pipeline)

      # Mock the output queue creation
      allow(stage).to receive(:create_output_queue).and_return(Queue.new)
      allow(stage).to receive(:send_end_signals)

      # Expect nested_pipeline.run to be called
      expect(nested_pipeline).to receive(:run).with(context)

      stage.run_stage(stage_ctx)
    end

    it 'sets input_queues when stage has upstream sources' do
      context = Object.new
      nested_pipeline = instance_double(Minigun::Pipeline, context: context)
      stage = described_class.new(:my_pipeline, mock_pipeline, nested_pipeline, nil, {})

      input_queue = Queue.new
      sources = Set.new([:upstream])
      stage_ctx = instance_double(Minigun::StageContext,
                                  pipeline: mock_pipeline,
                                  root_pipeline: mock_pipeline,
                                  stage: stage,
                                  sources_expected: sources,
                                  input_queue: input_queue,
                                  dag: instance_double(Minigun::DAG, downstream: []),
                                  stage_input_queues: {},
                                  runtime_edges: {},
                                  stage_name: :my_pipeline)

      allow(stage).to receive(:create_output_queue).and_return(Queue.new)
      allow(stage).to receive(:send_end_signals)
      allow(nested_pipeline).to receive(:run)

      # Expect input_queues to be set on the nested pipeline with sources_expected
      expect(nested_pipeline).to receive(:instance_variable_set).with(
        :@input_queues,
        { input: input_queue, sources_expected: sources }
      )
      expect(nested_pipeline).to receive(:instance_variable_set).with(:@output_queues, anything)

      stage.run_stage(stage_ctx)
    end

    it 'always sets output_queues' do
      context = Object.new
      nested_pipeline = instance_double(Minigun::Pipeline, context: context)
      stage = described_class.new(:my_pipeline, mock_pipeline, nested_pipeline, nil, {})

      output_queue = Queue.new
      stage_ctx = instance_double(Minigun::StageContext,
                                  pipeline: mock_pipeline,
                                  root_pipeline: mock_pipeline,
                                  stage: stage,
                                  sources_expected: Set.new,
                                  input_queue: Queue.new,
                                  dag: instance_double(Minigun::DAG, downstream: []),
                                  stage_input_queues: {},
                                  runtime_edges: {},
                                  stage_name: :my_pipeline)

      allow(stage).to receive(:create_output_queue).and_return(output_queue)
      allow(stage).to receive(:send_end_signals)
      allow(nested_pipeline).to receive(:run)

      # Expect output_queues to be set on the nested pipeline
      expect(nested_pipeline).to receive(:instance_variable_set).with(:@output_queues, { output: output_queue })

      stage.run_stage(stage_ctx)
    end

    it 'sends end signals to downstream stages after pipeline completes' do
      context = Object.new
      nested_pipeline = instance_double(Minigun::Pipeline, context: context)
      stage = described_class.new(:my_pipeline, mock_pipeline, nested_pipeline, nil, {})

      stage_ctx = instance_double(Minigun::StageContext,
                                  pipeline: mock_pipeline,
                                  root_pipeline: mock_pipeline,
                                  stage: stage,
                                  sources_expected: Set.new,
                                  input_queue: Queue.new,
                                  dag: instance_double(Minigun::DAG, downstream: []),
                                  stage_input_queues: {},
                                  runtime_edges: {},
                                  stage_name: :my_pipeline)

      allow(stage).to receive(:create_output_queue).and_return(Queue.new)
      allow(nested_pipeline).to receive(:instance_variable_set)
      allow(nested_pipeline).to receive(:run)

      # Expect send_end_signals to be called after pipeline runs
      expect(stage).to receive(:send_end_signals).with(stage_ctx)

      stage.run_stage(stage_ctx)
    end

    it 'sends end signals even if pipeline raises an error' do
      context = Object.new
      nested_pipeline = instance_double(Minigun::Pipeline, context: context)
      stage = described_class.new(:my_pipeline, mock_pipeline, nested_pipeline, nil, {})

      stage_ctx = instance_double(Minigun::StageContext,
                                  pipeline: mock_pipeline,
                                  root_pipeline: mock_pipeline,
                                  stage: stage,
                                  sources_expected: Set.new,
                                  input_queue: Queue.new,
                                  dag: instance_double(Minigun::DAG, downstream: []),
                                  stage_input_queues: {},
                                  runtime_edges: {},
                                  stage_name: :my_pipeline)

      allow(stage).to receive(:create_output_queue).and_return(Queue.new)
      allow(nested_pipeline).to receive(:instance_variable_set)
      allow(nested_pipeline).to receive(:run).and_raise(StandardError, 'test error')

      # Expect send_end_signals to be called even on error
      expect(stage).to receive(:send_end_signals).with(stage_ctx)

      expect { stage.run_stage(stage_ctx) }.to raise_error(StandardError, 'test error')
    end
  end
end
