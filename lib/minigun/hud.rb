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

      # Evaluate pipeline blocks if using DSL
      if task_instance.respond_to?(:_evaluate_pipeline_blocks!, true)
        task_instance.send(:_evaluate_pipeline_blocks!)
      end

      # Get the pipeline from the task
      pipeline = if task_instance.respond_to?(:_minigun_task, true)
                   # DSL-based task
                   task_instance.instance_variable_get(:@_minigun_task)&.root_pipeline
                 elsif task_instance.respond_to?(:pipelines)
                   task_instance.pipelines.first
                 elsif task_instance.respond_to?(:pipeline)
                   task_instance.pipeline
                 elsif task_instance.respond_to?(:root_pipeline)
                   task_instance.root_pipeline
                 else
                   raise ArgumentError, "Task must have a pipeline accessible via _minigun_task, pipelines, pipeline, or root_pipeline"
                 end

      raise ArgumentError, "No pipeline found in task" unless pipeline

      # Flag to track if user quit via HUD
      user_quit = false

      # Start HUD in a separate thread
      hud = Controller.new(pipeline, on_quit: -> { user_quit = true })
      hud_thread = Thread.new do
        begin
          hud.start
        rescue => e
          warn "\nHUD error: #{e.message}"
          warn e.backtrace.join("\n")
        end
      end

      # Give HUD time to initialize
      sleep 0.1

      # Run the task in a separate thread so we can monitor for HUD quit
      task_thread = Thread.new do
        begin
          task_instance.run
        rescue Interrupt
          # Gracefully handle Ctrl+C
        end
      end

      # Monitor for user quit
      loop do
        if user_quit
          # User pressed 'q' in HUD - exit immediately
          task_thread.kill if task_thread.alive?
          break
        end

        break unless task_thread.alive?
        sleep 0.1
      end

      # Cleanup
      hud.stop
      hud_thread.join(1)
      hud_thread.kill if hud_thread.alive?
      task_thread.join(0.5) if task_thread.alive?
    end
  end
end
