# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Minigun::PipelineStage do
  let(:config) { { max_threads: 2, max_processes: 1 } }
  let(:mock_context) { Object.new }
  let(:mock_pipeline) { instance_double(Minigun::Pipeline, name: 'test_pipeline', context: mock_context) }

  describe '#initialize' do
    it 'creates a PipelineStage without a pipeline initially' do
      stage = described_class.new(mock_pipeline, :my_pipeline, nil, {})
      expect(stage.name).to eq(:my_pipeline)
      expect(stage.nested_pipeline).to be_nil
    end
  end

  describe '#run_mode' do
    it 'returns :composite' do
      stage = described_class.new(mock_pipeline, :my_pipeline, nil, {})
      expect(stage.run_mode).to eq(:composite)
    end
  end

  describe '#nested_pipeline=' do
    it 'sets the nested pipeline' do
      stage = described_class.new(mock_pipeline, :my_pipeline, nil, {})
      pipeline = Minigun::Pipeline.new(nil, :test, config)

      stage.nested_pipeline = pipeline

      expect(stage.nested_pipeline).to eq(pipeline)
    end

    it 'allows setting nested pipeline to nil' do
      stage = described_class.new(mock_pipeline, :my_pipeline, nil, {})
      pipeline = Minigun::Pipeline.new(nil, :test, config)
      stage.nested_pipeline = pipeline

      stage.nested_pipeline = nil

      expect(stage.nested_pipeline).to be_nil
    end
  end

  describe '#run_stage' do
    it 'returns early if no pipeline is set' do
      stage = described_class.new(mock_pipeline, :my_pipeline, nil, {})
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
      stage = described_class.new(mock_pipeline, :my_pipeline, nil, {})
      context = Object.new
      root_pipeline_mock = instance_double(Minigun::Pipeline, context: context)
      pipeline = instance_double(Minigun::Pipeline, context: context)
      stage.nested_pipeline = pipeline

      stage_ctx = instance_double(Minigun::StageContext,
                                  pipeline: pipeline,
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

      # Expect pipeline.run to be called
      expect(pipeline).to receive(:run).with(context)

      stage.run_stage(stage_ctx)
    end

    it 'sets input_queues when stage has upstream sources' do
      stage = described_class.new(mock_pipeline, :my_pipeline, nil, {})
      context = Object.new
      pipeline = instance_double(Minigun::Pipeline, context: context)
      stage.nested_pipeline = pipeline

      input_queue = Queue.new
      sources = Set.new([:upstream])
      stage_ctx = instance_double(Minigun::StageContext,
                                  pipeline: pipeline,
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
      allow(pipeline).to receive(:run)

      # Expect input_queues to be set on the nested pipeline with sources_expected
      expect(pipeline).to receive(:instance_variable_set).with(
        :@input_queues,
        { input: input_queue, sources_expected: sources }
      )
      expect(pipeline).to receive(:instance_variable_set).with(:@output_queues, anything)

      stage.run_stage(stage_ctx)
    end

    it 'always sets output_queues' do
      stage = described_class.new(mock_pipeline, :my_pipeline, nil, {})
      context = Object.new
      pipeline = instance_double(Minigun::Pipeline, context: context)
      stage.nested_pipeline = pipeline

      output_queue = Queue.new
      stage_ctx = instance_double(Minigun::StageContext,
                                  pipeline: pipeline,
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
      allow(pipeline).to receive(:run)

      # Expect output_queues to be set on the nested pipeline
      expect(pipeline).to receive(:instance_variable_set).with(:@output_queues, { output: output_queue })

      stage.run_stage(stage_ctx)
    end

    it 'sends end signals to downstream stages after pipeline completes' do
      stage = described_class.new(mock_pipeline, :my_pipeline, nil, {})
      context = Object.new
      pipeline = instance_double(Minigun::Pipeline, context: context)
      stage.nested_pipeline = pipeline

      stage_ctx = instance_double(Minigun::StageContext,
                                  pipeline: pipeline,
                                  root_pipeline: mock_pipeline,
                                  stage: stage,
                                  sources_expected: Set.new,
                                  input_queue: Queue.new,
                                  dag: instance_double(Minigun::DAG, downstream: []),
                                  stage_input_queues: {},
                                  runtime_edges: {},
                                  stage_name: :my_pipeline)

      allow(stage).to receive(:create_output_queue).and_return(Queue.new)
      allow(pipeline).to receive(:instance_variable_set)
      allow(pipeline).to receive(:run)

      # Expect send_end_signals to be called after pipeline runs
      expect(stage).to receive(:send_end_signals).with(stage_ctx)

      stage.run_stage(stage_ctx)
    end

    it 'sends end signals even if pipeline raises an error' do
      stage = described_class.new(mock_pipeline, :my_pipeline, nil, {})
      context = Object.new
      pipeline = instance_double(Minigun::Pipeline, context: context)
      stage.nested_pipeline = pipeline

      stage_ctx = instance_double(Minigun::StageContext,
                                  pipeline: pipeline,
                                  root_pipeline: mock_pipeline,
                                  stage: stage,
                                  sources_expected: Set.new,
                                  input_queue: Queue.new,
                                  dag: instance_double(Minigun::DAG, downstream: []),
                                  stage_input_queues: {},
                                  runtime_edges: {},
                                  stage_name: :my_pipeline)

      allow(stage).to receive(:create_output_queue).and_return(Queue.new)
      allow(pipeline).to receive(:instance_variable_set)
      allow(pipeline).to receive(:run).and_raise(StandardError, 'test error')

      # Expect send_end_signals to be called even on error
      expect(stage).to receive(:send_end_signals).with(stage_ctx)

      expect { stage.run_stage(stage_ctx) }.to raise_error(StandardError, 'test error')
    end
  end
end
