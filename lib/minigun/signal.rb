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
    attr_reader :stage

    def initialize(stage)
      @stage = stage
    end

    def to_s
      "EndOfSource(#{@stage.name})"
    end
  end

  # Signal indicating all upstream sources for a stage have completed
  # Created by InputQueue wrapper when all expected sources send EndOfSource
  class EndOfStage < QueueSignal
    attr_reader :stage

    def initialize(stage)
      @stage = stage
    end

    def to_s
      "EndOfStage(#{@stage.name})"
    end
  end

  # Wrapper for items that carry routing metadata
  # Used in IPC fork contexts to route items to specific nested stages
  class RoutedItem
    attr_reader :target_stage, :item

    def initialize(target_stage, item)
      @target_stage = target_stage
      @item = item
    end

    def to_s
      "RoutedItem(target=#{@target_stage}, item=#{@item})"
    end
  end
end
