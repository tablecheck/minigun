# frozen_string_literal: true

require_relative 'hud/terminal'
require_relative 'hud/theme'
require_relative 'hud/keyboard'
require_relative 'hud/flow_diagram'
require_relative 'hud/process_list'
require_relative 'hud/stats_aggregator'
require_relative 'hud/controller'

module Minigun
  module HUD
    # Launch HUD for a pipeline
    # Can be run in a separate thread or process
    #
    # Usage:
    #   # In a separate thread
    #   hud_thread = Thread.new { Minigun::HUD.launch(pipeline) }
    #   pipeline.run(context)
    #   hud_thread.kill
    #
    #   # Or with explicit start/stop
    #   hud = Minigun::HUD::Controller.new(pipeline)
    #   Thread.new { hud.start }
    #   pipeline.run(context)
    #   hud.stop
    def self.launch(pipeline)
      controller = Controller.new(pipeline)
      controller.start
    end

    # Attach HUD to a task and run it
    # This will run the pipeline with HUD monitoring in parallel
    #
    # Usage:
    #   Minigun::HUD.run_with_hud(task)
    def self.run_with_hud(task)
      # Create task instance if class given
      task_instance = task.is_a?(Class) ? task.new : task

      # Get the pipeline from the task
      # Assuming task responds to :pipelines or :pipeline
      pipeline = if task_instance.respond_to?(:pipelines)
                   task_instance.pipelines.first
                 elsif task_instance.respond_to?(:pipeline)
                   task_instance.pipeline
                 else
                   raise ArgumentError, "Task must have a pipeline or pipelines method"
                 end

      # Start HUD in a separate thread
      hud = Controller.new(pipeline)
      hud_thread = Thread.new do
        begin
          hud.start
        rescue => e
          warn "HUD error: #{e.message}"
          warn e.backtrace.join("\n")
        end
      end

      # Run the task
      begin
        task_instance.run
      ensure
        # Stop HUD
        hud.stop
        hud_thread.join(timeout: 1)
        hud_thread.kill if hud_thread.alive?
      end
    end
  end
end
