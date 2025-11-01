# frozen_string_literal: true

module Minigun
  # Task orchestrates one or more pipelines
  # Supports both single-pipeline (implicit) and multi-pipeline modes
  class Task
    attr_reader :config, :root_pipeline

    def initialize(config: nil, root_pipeline: nil)
      @config = config || {
        max_threads: 5,
        max_processes: 2,
        max_retries: 3,
        accumulator_max_single: 2000,
        accumulator_max_all: 4000,
        accumulator_check_interval: 100,
        use_ipc: false
      }

      # Root pipeline - all stages and nested pipelines live here
      @root_pipeline = root_pipeline || Pipeline.new(:default, @config)
    end

    # Set config value (applies to all pipelines)
    def set_config(key, value)
      @config[key] = value

      # Update root pipeline config
      @root_pipeline.config[key] = value

      # Update all nested pipelines
      pipelines.each_value do |pipeline|
        pipeline.config[key] = value
      end
    end

    # Get all named pipelines (composite stages in root_pipeline)
    def pipelines
      @root_pipeline.stages.select { |stage| stage.run_mode == :composite }
                    .to_h { |stage| [stage.name, stage.pipeline] }
    end

    # Get the DAG for pipeline-level routing
    def pipeline_dag
      @root_pipeline.dag
    end

    # Add a stage to the implicit pipeline (for backward compatibility)
    def add_stage(type, stage_name, options = {}, &)
      @root_pipeline.add_stage(type, stage_name, options, &)
    end

    # Add a hook to the implicit pipeline (for backward compatibility)
    def add_hook(type, &)
      @root_pipeline.add_hook(type, &)
    end

    # Add a nested pipeline as a stage within the implicit pipeline
    def add_nested_pipeline(name, options = {}, &)
      # Create a PipelineStage and configure it (pipeline-first positional style)
      pipeline_stage = PipelineStage.new(@root_pipeline, name, nil, options)

      # Create the actual Pipeline instance for this nested pipeline
      nested_pipeline = Pipeline.new(name, @config)
      pipeline_stage.pipeline = nested_pipeline

      # Add stages to the nested pipeline via block
      if block_given?
        dsl = Minigun::DSL::PipelineDSL.new(nested_pipeline)
        dsl.instance_eval(&)
      end

      # Add the pipeline stage to the implicit pipeline
      @root_pipeline.stages << pipeline_stage
      @root_pipeline.stage_order << pipeline_stage  # Use object for stage_order
      @root_pipeline.dag.add_node(pipeline_stage)

      # Extract routing if specified - resolve or defer edges
      to_targets = options[:to]
      if to_targets
        Array(to_targets).each do |target|
          target_stage = target.is_a?(Stage) ? target : @root_pipeline.find_stage(target)
          if target_stage
            @root_pipeline.dag.add_edge(pipeline_stage, target_stage)
          else
            # Forward reference - defer until target is created
            @root_pipeline.instance_variable_get(:@deferred_edges) << { from: pipeline_stage, to: target }
          end
        end
      end

      # Process any deferred edges that now have both endpoints
      @root_pipeline.send(:process_deferred_edges!)

      pipeline_stage
    end

    # Define a named pipeline with routing
    # Pipelines are just PipelineStage objects in root_pipeline
    def define_pipeline(name, options = {})
      # Check if already exists
      pipeline_stage = @root_pipeline.find_stage(name)

      if pipeline_stage
        raise Minigun::Error, "Stage #{name} already exists as a non-composite stage" unless pipeline_stage.run_mode == :composite

        pipeline = pipeline_stage.pipeline
      else
        # Create new PipelineStage and add to root_pipeline (pipeline-first positional style)
        pipeline_stage = PipelineStage.new(@root_pipeline, name, nil, options)
        pipeline = Pipeline.new(name, @config)
        pipeline_stage.pipeline = pipeline

        @root_pipeline.stages << pipeline_stage
        @root_pipeline.stage_order << pipeline_stage  # Use object for stage_order
        @root_pipeline.dag.add_node(pipeline_stage)
      end

      # Handle routing in root_pipeline DAG - resolve or defer edges
      # TODO: This should probably be better delegated to root pipeline;
      # The logic is redundant with pipeline
      to_targets = options[:to]
      if to_targets
        Array(to_targets).each do |target|
          if (target_stage = @root_pipeline.find_stage(target))
            @root_pipeline.dag.add_edge(pipeline_stage, target_stage)
          else
            # Forward reference - defer until target is created
            @root_pipeline.instance_variable_get(:@deferred_edges) << { from: pipeline_stage, to: target }
          end
        end
      end

      from_sources = options[:from]
      if from_sources
        Array(from_sources).each do |source|
          if (source_stage = @root_pipeline.find_stage(source))
            @root_pipeline.dag.add_edge(source_stage, pipeline_stage)
          else
            # Forward reference - defer until source is created
            @root_pipeline.instance_variable_get(:@deferred_edges) << { from: source, to: pipeline_stage }
          end
        end
      end

      # Process any deferred edges that now have both endpoints
      @root_pipeline.send(:process_deferred_edges!)

      # Execute block in context of pipeline definition
      yield pipeline if block_given?

      pipeline
    end

    # Run the task with full lifecycle management (signal handling, job ID, stats)
    # Use this for production execution
    def run(context)
      runner = Minigun::Runner.new(self, context)
      runner.run
    end

    # Direct pipeline execution without Runner overhead
    # Use this for testing or embedding in other systems
    def perform(context)
      # Just run the root pipeline - it handles all stages transparently
      @root_pipeline.run(context)
    end

    # Access stages for backward compatibility
    def stages
      @root_pipeline.stages
    end

    # Access hooks for backward compatibility
    def hooks
      @root_pipeline.hooks
    end

    # Access DAG for backward compatibility (stage-level DAG)
    def dag
      @root_pipeline.dag
    end
  end
end
