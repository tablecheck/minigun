# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Minigun::StageRegistry do
  let(:registry) { described_class.new }

  # Helper to create a mock pipeline
  def mock_pipeline(name, stages = [])
    double('Pipeline', name: name, stages: stages)
  end

  # Helper to create a mock stage
  def mock_stage(name, run_mode: :streaming)
    double('Stage', name: name, run_mode: run_mode, inspect: "Stage<#{name}>")
  end

  # Helper to create a mock composite stage (PipelineStage)
  def mock_composite_stage(name, nested_pipeline = nil)
    double('PipelineStage',
      name: name,
      run_mode: :composite,
      nested_pipeline: nested_pipeline,
      inspect: "PipelineStage<#{name}>"
    )
  end

  describe '#initialize' do
    it 'initializes empty registries' do
      expect(registry.all_stages).to be_empty
      expect(registry.all_names).to be_empty
    end
  end

  describe '#register' do
    let(:pipeline) { mock_pipeline(:main) }
    let(:stage) { mock_stage(:my_stage) }

    context 'with a named stage' do
      it 'registers the stage in global namespace' do
        registry.register(pipeline, stage)
        expect(registry.all_names).to include('my_stage')
      end

      it 'registers the stage in pipeline-local namespace' do
        registry.register(pipeline, stage)
        found = registry.find_by_name(:my_stage, from_pipeline: pipeline)
        expect(found).to eq(stage)
      end

      it 'works with both symbols and strings' do
        stage_sym = mock_stage(:sym_stage)
        stage_str = mock_stage('str_stage')

        registry.register(pipeline, stage_sym)
        registry.register(pipeline, stage_str)

        expect(registry.find_by_name(:sym_stage, from_pipeline: pipeline)).to eq(stage_sym)
        expect(registry.find_by_name('str_stage', from_pipeline: pipeline)).to eq(stage_str)
      end
    end

    context 'with unnamed stage' do
      it 'does not register stages without names' do
        unnamed_stage = double('Stage', run_mode: :streaming, inspect: "Stage<unnamed>")
        allow(unnamed_stage).to receive(:name).and_return(nil)

        registry.register(pipeline, unnamed_stage)
        expect(registry.all_stages).to include(unnamed_stage)
        expect(registry.all_names).to be_empty
      end
    end

    context 'with :output stage' do
      it 'does not register :output stages in name indices' do
        output_stage = double('Stage', run_mode: :streaming, inspect: "Stage<output>")
        allow(output_stage).to receive(:name).and_return(:output)

        registry.register(pipeline, output_stage)
        expect(registry.all_stages).to include(output_stage)
        expect(registry.all_names).not_to include('output')
      end
    end

    context 'duplicate names' do
      it 'raises StageNameConflict when registering duplicate name in same pipeline' do
        stage1 = mock_stage(:duplicate)
        stage2 = mock_stage(:duplicate)

        registry.register(pipeline, stage1)

        expect do
          registry.register(pipeline, stage2)
        end.to raise_error(Minigun::StageNameConflict, /Stage name 'duplicate' already exists/)
      end

      it 'allows same name in different pipelines' do
        pipeline1 = mock_pipeline(:pipeline1)
        pipeline2 = mock_pipeline(:pipeline2)
        stage1 = mock_stage(:shared_name)
        stage2 = mock_stage(:shared_name)

        expect do
          registry.register(pipeline1, stage1)
          registry.register(pipeline2, stage2)
        end.not_to raise_error

        expect(registry.find_by_name(:shared_name, from_pipeline: pipeline1)).to eq(stage1)
        expect(registry.find_by_name(:shared_name, from_pipeline: pipeline2)).to eq(stage2)
      end
    end
  end

  describe '#find_by_name - 3-level lookup strategy' do
    let(:root_pipeline) { mock_pipeline(:root) }
    let(:nested_pipeline1) { mock_pipeline(:nested1) }
    let(:nested_pipeline2) { mock_pipeline(:nested2) }
    let(:other_pipeline) { mock_pipeline(:other) }

    context 'Level 1: Local neighbors (same pipeline)' do
      it 'finds stage in the same pipeline' do
        local_stage = mock_stage(:local)
        registry.register(root_pipeline, local_stage)

        found = registry.find_by_name(:local, from_pipeline: root_pipeline)
        expect(found).to eq(local_stage)
      end

      it 'prioritizes local stage over global stages with same name' do
        local_stage = mock_stage(:priority)
        global_stage = mock_stage(:priority)

        registry.register(root_pipeline, local_stage)
        registry.register(other_pipeline, global_stage)

        # Looking from root_pipeline, should find local_stage first
        found = registry.find_by_name(:priority, from_pipeline: root_pipeline)
        expect(found).to eq(local_stage)

        # Looking from other_pipeline, should find global_stage
        found_other = registry.find_by_name(:priority, from_pipeline: other_pipeline)
        expect(found_other).to eq(global_stage)
      end
    end

    context 'Level 2: Children (nested pipelines)' do
      it 'finds stage in nested pipeline when not found locally' do
        nested_stage = mock_stage(:nested)
        pipeline_stage = mock_composite_stage(:pipeline_stage, nested_pipeline1)

        # Set up nested pipeline relationship (stages is an Array)
        allow(root_pipeline).to receive(:stages).and_return([pipeline_stage])

        registry.register(nested_pipeline1, nested_stage)

        # Search from root should find it in children
        found = registry.find_by_name(:nested, from_pipeline: root_pipeline)
        expect(found).to eq(nested_stage)
      end

      it 'raises AmbiguousRoutingError when multiple nested pipelines have same stage name' do
        nested_stage1 = mock_stage(:ambiguous)
        nested_stage2 = mock_stage(:ambiguous)
        pipeline_stage1 = mock_composite_stage(:ps1, nested_pipeline1)
        pipeline_stage2 = mock_composite_stage(:ps2, nested_pipeline2)

        # Set up two nested pipelines with same stage name (stages is an Array)
        allow(root_pipeline).to receive(:stages).and_return([
          pipeline_stage1,
          pipeline_stage2
        ])

        registry.register(nested_pipeline1, nested_stage1)
        registry.register(nested_pipeline2, nested_stage2)

        expect do
          registry.find_by_name(:ambiguous, from_pipeline: root_pipeline)
        end.to raise_error(Minigun::AmbiguousRoutingError, /found 2 matches in nested pipelines/)
      end

      it 'handles deeply nested pipelines' do
        deep_stage = mock_stage(:deep)
        deep_pipeline = mock_pipeline(:deep)
        ps2 = mock_composite_stage(:ps2, deep_pipeline)
        ps1 = mock_composite_stage(:ps1, nested_pipeline1)

        # root -> nested1 -> deep (stages is an Array)
        allow(root_pipeline).to receive(:stages).and_return([ps1])
        allow(nested_pipeline1).to receive(:stages).and_return([ps2])

        registry.register(deep_pipeline, deep_stage)

        found = registry.find_by_name(:deep, from_pipeline: root_pipeline)
        expect(found).to eq(deep_stage)
      end

      it 'prevents infinite recursion with circular pipeline references' do
        circular_stage = mock_stage(:circular)
        ps2 = mock_composite_stage(:ps2, root_pipeline) # Circular reference!
        ps1 = mock_composite_stage(:ps1, nested_pipeline1)

        # Create circular reference: root -> nested1 -> root (stages is an Array)
        allow(root_pipeline).to receive(:stages).and_return([ps1])
        allow(nested_pipeline1).to receive(:stages).and_return([ps2])

        registry.register(nested_pipeline1, circular_stage)

        # Should not hang, should find the stage
        expect do
          found = registry.find_by_name(:circular, from_pipeline: root_pipeline)
          expect(found).to eq(circular_stage)
        end.not_to raise_error
      end
    end

    context 'Level 3: Global (any stage anywhere)' do
      it 'finds stage globally when not found locally or in children' do
        global_stage = mock_stage(:global)
        registry.register(other_pipeline, global_stage)

        # Empty root pipeline
        allow(root_pipeline).to receive(:stages).and_return({})

        # Should find it globally
        found = registry.find_by_name(:global, from_pipeline: root_pipeline)
        expect(found).to eq(global_stage)
      end

      it 'raises AmbiguousRoutingError when multiple pipelines have same stage name globally' do
        stage1 = mock_stage(:global_ambiguous)
        stage2 = mock_stage(:global_ambiguous)
        pipeline1 = mock_pipeline(:p1)
        pipeline2 = mock_pipeline(:p2)
        search_pipeline = mock_pipeline(:search)

        registry.register(pipeline1, stage1)
        registry.register(pipeline2, stage2)

        # Empty search pipeline with no local or nested stages
        allow(search_pipeline).to receive(:stages).and_return({})

        expect do
          registry.find_by_name(:global_ambiguous, from_pipeline: search_pipeline)
        end.to raise_error(Minigun::AmbiguousRoutingError, /found 2 matches globally/)
      end

      it 'returns the stage when only one global match exists' do
        unique_stage = mock_stage(:unique)
        registry.register(other_pipeline, unique_stage)

        allow(root_pipeline).to receive(:stages).and_return({})

        found = registry.find_by_name(:unique, from_pipeline: root_pipeline)
        expect(found).to eq(unique_stage)
      end
    end

    context 'not found' do
      it 'returns nil when stage name does not exist anywhere' do
        allow(root_pipeline).to receive(:stages).and_return({})

        found = registry.find_by_name(:nonexistent, from_pipeline: root_pipeline)
        expect(found).to be_nil
      end

      it 'returns nil for nil name' do
        found = registry.find_by_name(nil, from_pipeline: root_pipeline)
        expect(found).to be_nil
      end
    end
  end

  describe '#find' do
    let(:pipeline) { mock_pipeline(:main) }
    let(:stage) { mock_stage(:my_stage) }

    it 'delegates to find_by_name' do
      registry.register(pipeline, stage)

      found = registry.find(:my_stage, from_pipeline: pipeline)
      expect(found).to eq(stage)
    end

    it 'returns nil for nil identifier' do
      found = registry.find(nil, from_pipeline: pipeline)
      expect(found).to be_nil
    end
  end

  describe '#all_stages' do
    it 'returns all registered stages' do
      pipeline1 = mock_pipeline(:p1)
      pipeline2 = mock_pipeline(:p2)
      stage1 = mock_stage(:stage1)
      stage2 = mock_stage(:stage2)
      stage3 = mock_stage(:stage3)

      registry.register(pipeline1, stage1)
      registry.register(pipeline1, stage2)
      registry.register(pipeline2, stage3)

      stages = registry.all_stages
      expect(stages).to contain_exactly(stage1, stage2, stage3)
    end

    it 'returns unique stages even if registered in multiple places' do
      pipeline1 = mock_pipeline(:p1)
      stage = mock_stage(:shared)

      registry.register(pipeline1, stage)

      # all_stages should return unique stages
      expect(registry.all_stages.count(stage)).to eq(1)
    end
  end

  describe '#all_names' do
    it 'returns all registered stage names' do
      pipeline = mock_pipeline(:main)
      stage1 = mock_stage(:alpha)
      stage2 = mock_stage(:beta)

      registry.register(pipeline, stage1)
      registry.register(pipeline, stage2)

      names = registry.all_names
      expect(names).to contain_exactly('alpha', 'beta')
    end

    it 'normalizes names to strings' do
      pipeline = mock_pipeline(:main)
      stage = mock_stage(:symbol_name)

      registry.register(pipeline, stage)

      expect(registry.all_names).to include('symbol_name')
    end
  end

  describe '#clear' do
    it 'clears all registrations' do
      pipeline = mock_pipeline(:main)
      stage = mock_stage(:test)

      registry.register(pipeline, stage)
      expect(registry.all_stages).not_to be_empty

      registry.clear

      expect(registry.all_stages).to be_empty
      expect(registry.all_names).to be_empty
      expect(registry.find_by_name(:test, from_pipeline: pipeline)).to be_nil
    end
  end

  describe 'pipeline object identity' do
    it 'distinguishes pipelines by object identity, not by name' do
      # Two different pipeline objects with the same name
      pipeline1 = mock_pipeline(:same_name)
      pipeline2 = mock_pipeline(:same_name)
      stage1 = mock_stage(:stage1)
      stage2 = mock_stage(:stage2)

      registry.register(pipeline1, stage1)
      registry.register(pipeline2, stage2)

      # Should find different stages based on which pipeline object we use (local lookup)
      found1 = registry.find_by_name(:stage1, from_pipeline: pipeline1)
      found2 = registry.find_by_name(:stage2, from_pipeline: pipeline2)

      expect(found1).to eq(stage1)
      expect(found2).to eq(stage2)

      # Cross-lookup will find stages globally (since not in local scope)
      # This demonstrates that pipelines are distinguished by object, not by name
      allow(pipeline1).to receive(:stages).and_return({})
      allow(pipeline2).to receive(:stages).and_return({})

      expect(registry.find_by_name(:stage1, from_pipeline: pipeline2)).to eq(stage1)  # Found globally
      expect(registry.find_by_name(:stage2, from_pipeline: pipeline1)).to eq(stage2)  # Found globally
    end

    it 'uses the actual pipeline object as hash key' do
      pipeline = mock_pipeline(:main)
      stage = mock_stage(:test)

      registry.register(pipeline, stage)

      # Even if we create a new double with same name, it won't find it
      different_pipeline = mock_pipeline(:main)
      found = registry.find_by_name(:test, from_pipeline: different_pipeline)

      # Should not find in local scope (different object)
      # But might find in global scope
      expect(found).to eq(stage) # Found globally since no local match
    end
  end
end
