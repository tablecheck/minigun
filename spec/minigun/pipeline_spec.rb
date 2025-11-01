# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Minigun::Pipeline do
  let(:config) { { max_threads: 3, max_processes: 2 } }
  let(:pipeline) { described_class.new(:test_pipeline, config) }

  describe '#initialize' do
    it 'creates a pipeline with a name' do
      expect(pipeline.name).to eq(:test_pipeline)
    end

    it 'accepts configuration options' do
      expect(pipeline.config[:max_threads]).to eq(3)
      expect(pipeline.config[:max_processes]).to eq(2)
    end

    it 'uses default config for missing options' do
      default_pipeline = described_class.new(:default)
      expect(default_pipeline.config[:max_threads]).to eq(5)
    end

    it 'initializes empty stages' do
      expect(pipeline.stages).to be_a(Minigun::StagesCollection)
      expect(pipeline.stages).to be_empty
    end

    it 'initializes a DAG for stage routing' do
      expect(pipeline.dag).to be_a(Minigun::DAG)
    end
  end

  describe '#add_stage' do
    it 'adds a producer stage' do
      pipeline.add_stage(:producer, :fetch) { 'fetch data' }
      expect(pipeline.stages[:fetch]).to be_a(Minigun::ProducerStage)
      expect(pipeline.stages[:fetch].name).to eq(:fetch)
    end

    it 'adds multiple processor stages' do
      pipeline.add_stage(:processor, :transform) { |item| item }
      pipeline.add_stage(:processor, :validate) { |item| item }

      # Verify both stages were added by name
      expect(pipeline.stages[:transform]).not_to be_nil
      expect(pipeline.stages[:validate]).not_to be_nil
      expect(pipeline.stages[:transform].name).to eq(:transform)
      expect(pipeline.stages[:validate].name).to eq(:validate)
    end

    it 'adds a consumer stage' do
      pipeline.add_stage(:consumer, :save) { |item| puts item }
      expect(pipeline.stages[:save]).not_to be_nil
      expect(pipeline.stages[:save].name).to eq(:save)
    end

    it 'handles stage routing with :to option' do
      pipeline.add_stage(:producer, :source, to: :transform) { 'data' }
      pipeline.add_stage(:processor, :transform, to: :save) { |item| item }
      pipeline.add_stage(:consumer, :save) { |item| puts item }

      source = pipeline.find_stage(:source)
      transform = pipeline.find_stage(:transform)
      save = pipeline.find_stage(:save)

      expect(pipeline.dag.downstream(source)).to include(transform)
      expect(pipeline.dag.downstream(transform)).to include(save)
    end

    it 'raises error on duplicate stage name' do
      pipeline.add_stage(:producer, :fetch) { |output| output << 'first' }

      expect do
        pipeline.add_stage(:producer, :fetch) { |output| output << 'second' }
      end.to raise_error(Minigun::Error, /Stage name collision.*fetch/)
    end

    it 'raises error on duplicate stage name across different types' do
      pipeline.add_stage(:producer, :my_stage) { |output| output << 'data' }

      expect do
        pipeline.add_stage(:consumer, :my_stage) { |item| puts item }
      end.to raise_error(Minigun::Error, /Stage name collision.*my_stage/)
    end
  end

  describe '#add_hook' do
    it 'adds before_run hooks' do
      pipeline.add_hook(:before_run) { puts 'starting' }
      expect(pipeline.hooks[:before_run].size).to eq(1)
    end

    it 'adds multiple hooks of the same type' do
      pipeline.add_hook(:before_run) { puts 'hook 1' }
      pipeline.add_hook(:before_run) { puts 'hook 2' }
      expect(pipeline.hooks[:before_run].size).to eq(2)
    end
  end

  describe '#run' do
    before do
      allow(Minigun.logger).to receive(:info)
    end

    it 'executes a simple pipeline' do
      context = Class.new do
        attr_accessor :results

        def initialize
          @results = []
        end
      end.new

      pipeline.add_stage(:producer, :source) do |output|
        output << 1
        output << 2
      end

      pipeline.add_stage(:consumer, :sink) do |item|
        results << item
      end

      pipeline.run(context)
      expect(context.results).to contain_exactly(1, 2)
    end

    it 'executes hooks in order' do
      context = Class.new do
        attr_accessor :events

        def initialize
          @events = []
        end
      end.new

      pipeline.add_hook(:before_run) { events << :before }
      pipeline.add_hook(:after_run) { events << :after }

      pipeline.add_stage(:producer, :source) { |output| output << 1 }
      pipeline.add_stage(:consumer, :sink) { |_item| events << :process }

      pipeline.run(context)
      expect(context.events.first).to eq(:before)
      expect(context.events.last).to eq(:after)
      expect(context.events).to include(:process)
    end

    it 'processes items through processors' do
      context = Class.new do
        attr_accessor :results

        def initialize
          @results = []
        end
      end.new

      pipeline.add_stage(:producer, :source) do |output|
        output << 5
      end

      pipeline.add_stage(:processor, :double) do |item, output|
        output << (item * 2)
      end

      pipeline.add_stage(:consumer, :sink) do |item|
        results << item
      end

      pipeline.run(context)
      expect(context.results).to eq([10])
    end
  end

  describe '#find_all_producers' do
    it 'finds AtomicStage producers' do
      pipeline.add_stage(:producer, :source) { output << 1 }
      pipeline.add_stage(:consumer, :sink) { |item| item }

      producers = pipeline.send(:find_all_producers)

      expect(producers.size).to eq(1)
      expect(producers.first.name).to eq(:source)
    end

    it 'finds PipelineStages with no upstream as producers' do
      # Add a PipelineStage (positional constructor style)
      pipeline_stage = Minigun::PipelineStage.new(pipeline, :nested, nil, {})
      nested_pipeline = described_class.new(:nested, config)
      pipeline_stage.pipeline = nested_pipeline
      pipeline.stages[:nested] = pipeline_stage

      # Add to DAG with no upstream (use stage object)
      pipeline.dag.add_node(pipeline_stage)
      pipeline.stage_order.clear
      pipeline.stage_order << pipeline_stage

      producers = pipeline.send(:find_all_producers)

      expect(producers).to include(pipeline_stage)
    end

    it 'does not include PipelineStages with upstream' do
      # Add a regular producer
      pipeline.add_stage(:producer, :source) { output << 1 }

      # Add a PipelineStage with upstream (positional constructor style)
      pipeline_stage = Minigun::PipelineStage.new(pipeline, :nested, nil, {})
      nested_pipeline = described_class.new(:nested, config)
      pipeline_stage.pipeline = nested_pipeline
      pipeline.stages[:nested] = pipeline_stage
      pipeline.stage_order << pipeline_stage  # Use object

      # Add to DAG with upstream from source
      source = pipeline.find_stage(:source)
      pipeline.dag.add_node(pipeline_stage)  # Use object
      pipeline.dag.add_edge(source, pipeline_stage)  # Use objects

      producers = pipeline.send(:find_all_producers)

      expect(producers).not_to include(pipeline_stage)
      expect(producers.map(&:name)).to eq([:source])
    end

    it 'finds both AtomicStage and PipelineStage producers' do
      # Add atomic producer
      pipeline.add_stage(:producer, :atomic_source) { output << 1 }

      # Add PipelineStage producer
      pipeline_stage = Minigun::PipelineStage.new(pipeline, :pipeline_source, nil, {})
      nested_pipeline = described_class.new(:nested, config)
      pipeline_stage.pipeline = nested_pipeline
      pipeline.stages[:pipeline_source] = pipeline_stage
      pipeline.stage_order << :pipeline_source
      pipeline.dag.add_node(:pipeline_source)

      producers = pipeline.send(:find_all_producers)

      expect(producers.size).to eq(2)
      expect(producers.map(&:name)).to contain_exactly(:atomic_source, :pipeline_source)
    end
  end

  describe '#handle_multiple_producers_routing!' do
    it 'connects single producer to next stage' do
      pipeline.add_stage(:producer, :source) { output << 1 }
      pipeline.add_stage(:consumer, :sink) { |item| item }

      pipeline.send(:build_dag_routing!)

      source = pipeline.find_stage(:source)
      sink = pipeline.find_stage(:sink)
      expect(pipeline.dag.downstream(source)).to include(sink)
    end

    it 'connects each producer to its next sequential non-producer' do
      pipeline.add_stage(:producer, :source_a) { output << 1 }
      pipeline.add_stage(:processor, :process_a) { |item| output << (item * 10) }
      pipeline.add_stage(:producer, :source_b) { output << 2 }
      pipeline.add_stage(:processor, :process_b) { |item| output << (item * 20) }

      pipeline.send(:build_dag_routing!)

      source_a = pipeline.find_stage(:source_a)
      process_a = pipeline.find_stage(:process_a)
      source_b = pipeline.find_stage(:source_b)
      process_b = pipeline.find_stage(:process_b)

      # source_a should connect to process_a
      expect(pipeline.dag.downstream(source_a)).to include(process_a)
      # source_b should connect to process_b
      expect(pipeline.dag.downstream(source_b)).to include(process_b)
    end

    it 'does not connect producers that already have explicit routing' do
      pipeline.add_stage(:producer, :source_a) { output << 1 }
      pipeline.add_stage(:processor, :process_a, from: :source_a) { |item| output << (item * 10) }
      pipeline.add_stage(:producer, :source_b) { output << 2 }
      pipeline.add_stage(:processor, :process_b) { |item| output << (item * 20) }

      pipeline.send(:build_dag_routing!)

      source_a = pipeline.find_stage(:source_a)
      process_a = pipeline.find_stage(:process_a)
      source_b = pipeline.find_stage(:source_b)
      process_b = pipeline.find_stage(:process_b)

      # source_a already has explicit routing to process_a
      expect(pipeline.dag.downstream(source_a)).to eq([process_a])
      # source_b should still get sequential routing
      expect(pipeline.dag.downstream(source_b)).to include(process_b)
    end

    it 'handles producers at the end with no following stage' do
      pipeline.add_stage(:producer, :source_a) { output << 1 }
      pipeline.add_stage(:consumer, :sink) { |item| item }
      pipeline.add_stage(:producer, :source_b) { output << 2 }

      # source_b has no stage after it, so no automatic routing
      expect { pipeline.send(:build_dag_routing!) }.not_to raise_error

      source_a = pipeline.find_stage(:source_a)
      sink = pipeline.find_stage(:sink)
      source_b = pipeline.find_stage(:source_b)

      # source_a routes to sink, source_b has no downstream
      expect(pipeline.dag.downstream(source_a)).to include(sink)
      expect(pipeline.dag.downstream(source_b)).to be_empty
    end

    it 'connects multiple producers to different stages, not all to first' do
      pipeline.add_stage(:producer, :source_a) { output << 1 }
      pipeline.add_stage(:processor, :process_a) { |item| output << (item * 10) }
      pipeline.add_stage(:producer, :source_b) { output << 2 }
      pipeline.add_stage(:processor, :process_b) { |item| output << (item * 20) }
      pipeline.add_stage(:producer, :source_c) { output << 3 }
      pipeline.add_stage(:consumer, :sink) { |item| item }

      pipeline.send(:build_dag_routing!)

      source_a = pipeline.find_stage(:source_a)
      process_a = pipeline.find_stage(:process_a)
      source_b = pipeline.find_stage(:source_b)
      process_b = pipeline.find_stage(:process_b)
      source_c = pipeline.find_stage(:source_c)
      sink = pipeline.find_stage(:sink)

      # Each producer connects to its next stage
      expect(pipeline.dag.downstream(source_a)).to include(process_a)
      expect(pipeline.dag.downstream(source_b)).to include(process_b)
      expect(pipeline.dag.downstream(source_c)).to include(sink)
    end

    it 'handles mixed AtomicStage and PipelineStage producers' do
      # Atomic producer
      pipeline.add_stage(:producer, :atomic_source) { output << 1 }
      pipeline.add_stage(:processor, :process_atomic) { |item| output << (item * 10) }

      # PipelineStage producer
      pipeline_stage = Minigun::PipelineStage.new(pipeline, :pipeline_source, nil, {})
      nested_pipeline = described_class.new(:nested, config)
      pipeline_stage.pipeline = nested_pipeline
      pipeline.stages[:pipeline_source] = pipeline_stage
      pipeline.stage_order << pipeline_stage  # Use object
      pipeline.dag.add_node(pipeline_stage)    # Use object

      pipeline.add_stage(:consumer, :sink) { |item| item }

      pipeline.send(:build_dag_routing!)

      atomic_source = pipeline.find_stage(:atomic_source)
      process_atomic = pipeline.find_stage(:process_atomic)
      sink = pipeline.find_stage(:sink)

      # Atomic routes to process_atomic
      expect(pipeline.dag.downstream(atomic_source)).to include(process_atomic)
      # Pipeline routes to sink
      expect(pipeline.dag.downstream(pipeline_stage)).to include(sink)
    end
  end

  describe 'unified execution' do
    before do
      allow(Minigun.logger).to receive(:info)
    end

    it 'executes PipelineStages as producers' do
      context = Class.new do
        attr_accessor :results

        def initialize
          @results = []
        end
      end.new

      # Create PipelineStage that acts as a producer
      pipeline_stage = Minigun::PipelineStage.new(pipeline, :source_pipeline, nil, {})
      source_pipeline = described_class.new(:source, config)
      pipeline_stage.pipeline = source_pipeline
      source_pipeline.add_stage(:producer, :gen) { |output| 3.times { |i| output << i } }
      source_pipeline.add_stage(:processor, :double) { |item, output| output << (item * 2) }

      pipeline.stages << pipeline_stage  # Use Stage object
      pipeline.stage_order.unshift(pipeline_stage)  # Use Stage object
      pipeline.dag.add_node(pipeline_stage)  # Use Stage object

      # Add consumer to main pipeline
      sink_stage = pipeline.add_stage(:consumer, :sink) { |item| results << item }
      pipeline.dag.add_edge(pipeline_stage, pipeline.find_stage(:sink))  # Use Stage objects

      pipeline.run(context)

      # PipelineStage producer should emit: 0*2=0, 1*2=2, 2*2=4
      expect(context.results.sort).to eq([0, 2, 4])
    end

    it 'executes PipelineStages as processors' do
      context = Class.new do
        attr_accessor :results

        def initialize
          @results = []
        end
      end.new

      # Regular producer
      pipeline.add_stage(:producer, :source) { |output| 3.times { |i| output << i } }

      # PipelineStage as processor
      pipeline_stage = Minigun::PipelineStage.new(pipeline, :processor_pipeline, nil, {})
      proc_pipeline = described_class.new(:processor, config)
      pipeline_stage.pipeline = proc_pipeline
      proc_pipeline.add_stage(:processor, :multiply) { |item, output| output << (item * 10) }
      proc_pipeline.add_stage(:processor, :add_one) { |item, output| output << (item + 1) }

      pipeline.stages << pipeline_stage  # Use Stage object
      pipeline.stage_order << pipeline_stage  # Use Stage object
      pipeline.dag.add_node(pipeline_stage)  # Use Stage object
      source_stage = pipeline.find_stage(:source)
      pipeline.dag.add_edge(source_stage, pipeline_stage)  # Use Stage objects

      # Consumer
      pipeline.add_stage(:consumer, :sink) { |item| results << item }
      sink_stage = pipeline.find_stage(:sink)
      pipeline.dag.add_edge(pipeline_stage, sink_stage)  # Use Stage objects

      pipeline.run(context)

      # Items: 0,1,2 -> *10+1 -> 1,11,21
      expect(context.results.sort).to eq([1, 11, 21])
    end

    it 'handles multiple PipelineStage producers with different outputs' do
      context = Class.new do
        attr_accessor :results

        def initialize
          @results = []
        end
      end.new

      # First PipelineStage producer
      ps1 = Minigun::PipelineStage.new(pipeline, :pipeline_a, nil, {})
      p1 = described_class.new(:pa, config)
      ps1.pipeline = p1
      p1.add_stage(:producer, :gen) { |output| output << 10 }
      p1.add_stage(:processor, :double) { |item, output| output << (item * 2) }

      pipeline.stages << ps1  # Use Stage object
      pipeline.stage_order << ps1  # Use Stage object
      pipeline.dag.add_node(ps1)  # Use Stage object

      # Second PipelineStage producer
      ps2 = Minigun::PipelineStage.new(pipeline, :pipeline_b, nil, {})
      p2 = described_class.new(:pb, config)
      ps2.pipeline = p2
      p2.add_stage(:producer, :gen) { |output| output << 5 }
      p2.add_stage(:processor, :triple) { |item, output| output << (item * 3) }

      pipeline.stages << ps2  # Use Stage object
      pipeline.stage_order << ps2  # Use Stage object
      pipeline.dag.add_node(ps2)  # Use Stage object

      # Consumer
      pipeline.add_stage(:consumer, :sink) { |item| results << item }
      sink_stage = pipeline.find_stage(:sink)
      pipeline.dag.add_edge(ps1, sink_stage)  # Use Stage objects
      pipeline.dag.add_edge(ps2, sink_stage)  # Use Stage objects

      pipeline.run(context)

      # pipeline_a: 10*2=20, pipeline_b: 5*3=15
      expect(context.results.sort).to eq([15, 20])
    end
  end
end
