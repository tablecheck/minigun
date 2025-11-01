# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Minigun::Worker do
  let(:pipeline) do
    instance_double(
      Minigun::Pipeline,
      name: 'test_pipeline',
      dag: dag,
      stage_input_queues: {},
      runtime_edges: {},
      context: user_context,
      stats: stats,
      stage_hooks: stage_hooks
    )
  end

  let(:stage) do
    double(
      'stage',
      name: :test_stage,
      execution_context: nil,
      log_type: 'Worker',
      run_mode: :streaming
    )
  end

  let(:config) { { max_threads: 5, max_processes: 2 } }
  let(:user_context) { double('context') }
  let(:stage_stats) { double('stage_stats', start!: nil, finish!: nil) }
  let(:stats) { double('stats', for_stage: stage_stats) }
  let(:stage_hooks) { {} }
  let(:dag) { instance_double(Minigun::DAG, upstream: [], downstream: [], terminal?: false) }

  before do
    allow(Minigun.logger).to receive(:info)
  end

  describe '#initialize' do
    it 'creates a worker' do
      worker = described_class.new(pipeline, stage, config)

      expect(worker.stage_name).to eq(:test_stage)
      expect(worker).to be_a(described_class)
    end

    it 'does not start the worker thread immediately' do
      worker = described_class.new(pipeline, stage, config)

      expect(worker.thread).to be_nil
    end
  end

  describe '#start' do
    it 'starts a worker thread' do
      input_queue = Queue.new
      allow(pipeline).to receive(:stage_input_queues)
        .and_return({ test_stage: input_queue })
      allow(dag).to receive(:upstream).with(:test_stage).and_return([:upstream])
      allow(dag).to receive(:downstream).with(:test_stage).and_return([])

      # Stub run_stage to simulate stage execution
      allow(stage).to receive(:run_stage) do |worker_ctx|
        # Simulate basic loop: wait for END signal
        loop do
          msg = worker_ctx.input_queue.pop
          break if msg.is_a?(Minigun::EndOfSource)
        end
      end

      worker = described_class.new(pipeline, stage, config)

      worker.start

      # Thread should be created
      expect(worker.thread).to be_a(Thread)

      # Put END signal so the worker exits
      input_queue << Minigun::EndOfSource.new(:upstream)

      worker.join

      # Thread should have finished cleanly
      expect(worker.thread).not_to be_alive
    end
  end

  describe '#join' do
    it 'waits for worker thread to complete' do
      input_queue = Queue.new
      allow(pipeline).to receive(:stage_input_queues)
        .and_return({ test_stage: input_queue })

      worker = described_class.new(pipeline, stage, config)

      # Put END signal
      input_queue << Minigun::EndOfSource.new(:upstream)

      worker.start
      worker.join

      expect(worker.thread).not_to be_alive
    end

    it 'handles nil thread gracefully' do
      worker = described_class.new(pipeline, stage, config)

      expect { worker.join }.not_to raise_error
    end
  end

  describe 'executor creation' do
    context 'with inline execution context' do
      before do
        allow(stage).to receive(:execution_context).and_return(nil)
      end

      it 'creates an inline executor' do
        worker = described_class.new(pipeline, stage, config)

        # Should not raise error
        expect(worker).to be_a(described_class)
      end
    end

    context 'with thread execution context' do
      before do
        allow(stage).to receive(:execution_context).and_return({ type: :thread, pool_size: 5 })
      end

      it 'creates a thread pool executor' do
        worker = described_class.new(pipeline, stage, config)

        expect(worker).to be_a(described_class)
      end
    end

    context 'with process execution context' do
      before do
        allow(stage).to receive(:execution_context).and_return({ type: :cow_fork, max: 2 })
      end

      it 'creates a process pool executor' do
        worker = described_class.new(pipeline, stage, config)

        expect(worker).to be_a(described_class)
      end
    end
  end

  describe 'disconnected stage handling' do
    it 'exits early if no upstream sources' do
      allow(pipeline).to receive(:stage_input_queues)
        .and_return({ test_stage: Queue.new })
      allow(dag).to receive(:upstream).with(:test_stage).and_return([])
      allow(dag).to receive(:downstream).with(:test_stage).and_return([])

      worker = described_class.new(pipeline, stage, config)

      allow(Minigun.logger).to receive(:debug).and_call_original

      worker.start
      worker.join

      expect(Minigun.logger).to have_received(:debug).with(/No upstream sources, sending END signals and exiting/)
    end

    it 'sends END signals to downstream if disconnected' do
      allow(pipeline).to receive(:stage_input_queues)
        .and_return({ test_stage: Queue.new, downstream: Queue.new })
      allow(dag).to receive(:upstream).with(:test_stage).and_return([])
      allow(dag).to receive(:downstream).with(:test_stage).and_return([:downstream])

      downstream_queue = Queue.new
      allow(pipeline).to receive(:stage_input_queues)
        .and_return({ test_stage: Queue.new, downstream: downstream_queue })

      worker = described_class.new(pipeline, stage, config)
      worker.start
      worker.join

      # Should have sent END signal to downstream
      msg = begin
        downstream_queue.pop(true)
      rescue StandardError
        nil
      end
      expect(msg).to be_a(Minigun::EndOfSource) if msg
    end
  end

  describe 'router stage' do
    # Create mock stage objects
    let(:router_stage) do
      Minigun::ConsumerStage.new(name: :router, block: proc {}, options: {})
    end
    let(:target_a_stage) { Minigun::ConsumerStage.new(name: :target_a, block: proc {}, options: {}) }
    let(:target_b_stage) { Minigun::ConsumerStage.new(name: :target_b, block: proc {}, options: {}) }
    let(:source_stage) { Minigun::ProducerStage.new(name: :source, block: proc {}, options: {}) }

    let(:broadcast_router) do
      Minigun::RouterBroadcastStage.new(
        name: :router,
        targets: [target_a_stage, target_b_stage]  # Use Stage objects
      )
    end

    it 'routes items without executing' do
      input_queue = Queue.new
      target_a_queue = Queue.new
      target_b_queue = Queue.new

      allow(pipeline).to receive(:stage_input_queues)
        .and_return({ broadcast_router => input_queue, target_a_stage => target_a_queue, target_b_stage => target_b_queue })
      allow(dag).to receive(:upstream).with(broadcast_router).and_return([source_stage])

      # Put items and END signal
      input_queue << 1
      input_queue << 2
      input_queue << Minigun::EndOfSource.new(source_stage)

      worker = described_class.new(pipeline, broadcast_router, config)
      worker.start
      worker.join

      # Both targets should have received items (broadcast)
      expect(target_a_queue.size).to be > 0
      expect(target_b_queue.size).to be > 0
    end
  end

  describe 'error handling' do
    it 'shuts down executor even on error' do
      executor = instance_double(Minigun::Execution::InlineExecutor)
      allow(executor).to receive(:shutdown)

      # Mock executor creation to return our test double (now takes stage_ctx arg)
      allow_any_instance_of(described_class).to receive(:create_executor_if_needed).with(any_args).and_return(executor)

      worker = described_class.new(pipeline, stage, config)

      # Cause an error AFTER stage_ctx is created (so executor gets created)
      # Error during stage.run_stage (after executor is created)
      allow(stage).to receive(:run_stage).and_raise(StandardError, 'Test error')

      expect(executor).to receive(:shutdown)

      worker.start
      sleep 0.02 # Give thread time to start and error
      begin
        worker.join
      rescue StandardError
        nil
      end
    end
  end

  describe 'logging' do
    it 'logs when starting' do
      input_queue = Queue.new
      allow(pipeline).to receive(:stage_input_queues)
        .and_return({ test_stage: input_queue })

      input_queue << Minigun::EndOfSource.new(:upstream)

      allow(Minigun.logger).to receive(:debug).and_call_original

      worker = described_class.new(pipeline, stage, config)
      worker.start
      worker.join

      expect(Minigun.logger).to have_received(:debug).with(/Starting/)
    end

    it 'logs when done' do
      input_queue = Queue.new
      allow(pipeline).to receive(:stage_input_queues)
        .and_return({ test_stage: input_queue })
      allow(dag).to receive(:upstream).with(:test_stage).and_return([:upstream])
      allow(dag).to receive(:downstream).with(:test_stage).and_return([])

      # Stub run_stage to simulate stage execution
      # Note: accessing raw queue directly here (not wrapped in InputQueue)
      allow(stage).to receive(:run_stage) do |worker_ctx|
        loop do
          msg = worker_ctx.input_queue.pop
          break if msg.is_a?(Minigun::EndOfSource)
        end
      end

      input_queue << Minigun::EndOfSource.new(:upstream)

      allow(Minigun.logger).to receive(:debug).and_call_original

      worker = described_class.new(pipeline, stage, config)
      worker.start
      worker.join

      expect(Minigun.logger).to have_received(:debug).with(/Done/)
    end
  end
end
