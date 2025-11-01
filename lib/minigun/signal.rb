# frozen_string_literal: true

module Minigun
  # Base class for all pipeline queue signals
  # Queue signals are special marker objects that flow through queues to coordinate pipeline state
  class QueueSignal
    def to_s
      'QueueSignal'
    end

    def inspect
      to_s
    end
  end

  # Signal indicating one upstream source has completed
  # Flows through raw queues, consumed by InputQueue wrapper
  class EndOfSource < QueueSignal
    attr_reader :source  # Stage object

    def initialize(source)
      @source = source
    end

    def to_s
      name = @source.is_a?(Stage) ? @source.name : @source
      "EndOfSource(#{name})"
    end
  end

  # Signal indicating all upstream sources for a stage have completed
  # Created by InputQueue wrapper when all expected sources send EndOfSource
  class EndOfStage < QueueSignal
    attr_reader :stage  # Stage object

    def initialize(stage)
      @stage = stage
    end

    # Backward compat: stage_name returns the name
    def stage_name
      @stage.is_a?(Stage) ? @stage.name : @stage
    end

    def to_s
      "EndOfStage(#{stage_name})"
    end
  end
end
