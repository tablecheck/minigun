# frozen_string_literal: true

module Minigun
  # Unified registry for stage management across the entire Task hierarchy
  # Handles name-based lookups with proper scoping
  #
  # Design principles:
  # 1. Stages and pipelines are stored as Ruby objects (no ID/name strings)
  # 2. Names are optional and scoped to pipelines (user-friendly)
  # 3. Name resolution follows: local → children → global
  # 4. Ambiguous names raise errors at resolution time
  class StageRegistry
    def initialize
      @global_names = Hash.new { |h, k| h[k] = [] } # { name_string => [Stage, Stage, ...] }
      @pipeline_stages = {} # { Pipeline object => { name_string => Stage } }
      @all_stages = [] # All stage objects for iteration
      @mutex = Mutex.new
    end

    # Register a stage with the stage_registry
    # @param pipeline [Pipeline] The pipeline object this stage belongs to
    # @param stage [Stage] The stage object to register
    def register(pipeline, stage)
      @mutex.synchronize do
        # Always add stage to the all_stages list
        @all_stages << stage

        # If stage has a name (and it's not :output), register it in the name indices
        name = stage.name
        if name && name != :output
          name_str = normalize_name(name)

          # Register in pipeline's local namespace (must be unique per pipeline)
          if pipeline
            @pipeline_stages[pipeline] ||= {}
            if @pipeline_stages[pipeline].key?(name_str)
              existing_stage = @pipeline_stages[pipeline][name_str]
              raise StageNameConflict,
                    "Stage name '#{name}' already exists in pipeline '#{pipeline.name}' " \
                    "(existing: #{existing_stage.inspect}, new: #{stage.inspect})"
            end
            @pipeline_stages[pipeline][name_str] = stage
          end

          # Register in global namespace (multiple stages can have same name)
          @global_names[name_str] << stage unless @global_names[name_str].include?(stage)
        end
      end
    end

    # Find stage by name from a specific pipeline's perspective
    # Uses 3-level routing strategy: local → children → global
    # Raises AmbiguousRoutingError if multiple matches found at any level
    # from_pipeline is a Pipeline object, not a name
    def find_by_name(name, from_pipeline:)
      return nil unless name

      name_str = normalize_name(name)

      # Level 1: Local neighbors (stages in same pipeline)
      if @pipeline_stages[from_pipeline]&.key?(name_str)
        return @pipeline_stages[from_pipeline][name_str]
      end

      # Level 2: Children (stages in nested pipelines)
      children_stages = find_in_children(from_pipeline, name_str)
      if children_stages.size > 1
        raise AmbiguousRoutingError,
              "Stage name '#{name}' is ambiguous - found #{children_stages.size} matches in nested pipelines"
      end
      return children_stages.first if children_stages.size == 1

      # Level 3: Global (any stage anywhere)
      global_stages = @global_names[name_str]
      if global_stages.size > 1
        raise AmbiguousRoutingError,
              "Stage name '#{name}' is ambiguous - found #{global_stages.size} matches globally: " \
              "#{global_stages.map(&:inspect).join(', ')}"
      end
      return global_stages.first if global_stages.size == 1

      nil
    end

    # Find stage by name from a pipeline's perspective
    # This is the main entry point for all lookups
    def find(identifier, from_pipeline:)
      return nil unless identifier

      # Try name lookup with scoping
      find_by_name(identifier, from_pipeline: from_pipeline)
    end

    # Get all stages (for debugging/inspection)
    def all_stages
      @all_stages
    end

    # Get all registered names (for debugging/inspection)
    def all_names
      @global_names.keys
    end

    # Clear everything (for testing)
    def clear
      @mutex.synchronize do
        @global_names.clear
        @pipeline_stages.clear
        @all_stages.clear
      end
    end

    private

    # Normalize name to string (symbols and strings both work)
    def normalize_name(name)
      return nil if name.nil?
      name.to_s
    end

    # Recursively find all stages with given name in pipeline's nested children
    # Uses visited set to prevent infinite loops from circular references
    # pipeline parameter is a Pipeline object
    def find_in_children(pipeline, name_str, visited = Set.new)
      # Prevent infinite recursion from circular pipeline references
      return [] if visited.include?(pipeline.object_id)
      visited.add(pipeline.object_id)

      results = []

      # pipeline.stages is an Array of Stage objects
      pipeline.stages.each do |stage|
        next unless stage.run_mode == :composite
        next unless stage.respond_to?(:nested_pipeline) && stage.nested_pipeline

        nested_pipeline = stage.nested_pipeline

        # Check nested pipeline's local namespace using pipeline object as key
        if @pipeline_stages[nested_pipeline]&.key?(name_str)
          results << @pipeline_stages[nested_pipeline][name_str]
        end

        # Recurse into nested pipeline's children (with visited tracking)
        results.concat(find_in_children(nested_pipeline, name_str, visited))
      end

      results
    end
  end
end
