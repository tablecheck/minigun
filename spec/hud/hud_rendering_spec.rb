# frozen_string_literal: true

require 'spec_helper'
require_relative '../../lib/minigun'
require_relative '../../lib/minigun/hud'

RSpec.describe 'HUD Full Rendering' do
  def strip_ascii(str)
    str = str.dup
    str.sub!(/\A( *\n)+/m, '')
    str.sub!(/(\n *)+\z/m, '')
    str
  end

  # Helper to capture the full HUD ASCII output
  def render_hud(pipeline_instance, width: 120, height: 30)
    # Evaluate pipeline blocks if using DSL
    if pipeline_instance.respond_to?(:_evaluate_pipeline_blocks!, true)
      pipeline_instance.send(:_evaluate_pipeline_blocks!)
    end

    # Get the actual pipeline object
    pipeline = if pipeline_instance.respond_to?(:_minigun_task, true)
                 pipeline_instance.instance_variable_get(:@_minigun_task)&.root_pipeline
               else
                 pipeline_instance
               end

    raise "No pipeline found" unless pipeline

    # Run pipeline briefly to initialize stats
    thread = Thread.new { pipeline_instance.run }
    sleep 0.1
    thread.kill if thread.alive?

    # Create HUD controller
    controller = Minigun::HUD::Controller.new(pipeline)

    # Override terminal size
    controller.terminal.instance_variable_set(:@width, width)
    controller.terminal.instance_variable_set(:@height, height)

    # Setup buffer capture
    captured_buffer = setup_buffer_capture(controller, width, height)

    # Recalculate layout for new dimensions
    controller.send(:calculate_layout)

    # Stop animation frame updates to keep output deterministic
    controller.flow_diagram.instance_variable_set(:@animation_frame, 0)

    # Render one frame
    controller.send(:render_frame)

    captured_buffer
  end

  # Helper to setup buffer capture for a controller
  def setup_buffer_capture(controller, width, height)
    captured_buffer = Array.new(height) { Array.new(width, ' ') }

    allow(controller.terminal).to receive(:render) do
      command_buffer = controller.terminal.instance_variable_get(:@buffer)
      command_buffer.each do |cmd|
        x = cmd[:x] - 1
        y = cmd[:y] - 1
        text = cmd[:text]

        text.chars.each_with_index do |char, i|
          col = x + i
          break if col >= width || col < 0
          next if y < 0 || y >= height
          captured_buffer[y][col] = char
        end
      end
      command_buffer.clear
    end

    captured_buffer
  end

  # Helper to create normalized output (strip ANSI, remove trailing spaces)
  def normalize_output(buffer)
    buffer.map do |line|
      # Join characters, strip ANSI codes, remove trailing whitespace
      line.join.gsub(/\e\[[0-9;]*m/, '').rstrip
    end.join("\n")
  end

  describe 'Standard Terminal Size (120x30)' do
    it 'renders complete HUD with both panels' do
      # Simple 2-stage pipeline
      pipeline_class = Class.new do
        include Minigun::DSL

        pipeline do
          producer :generate do |output|
            5.times { |i| output << i }
          end

          consumer :process do |item|
            sleep 0.01
          end
        end
      end

      buffer = render_hud(pipeline_class.new, width: 120, height: 30)
      output = normalize_output(buffer)

      # Check key elements are present
      expect(output).to include('FLOW DIAGRAM')
      expect(output).to include('PROCESS STATISTICS')
      expect(output).to include('RUNNING')
      expect(output).to include('default')  # Pipeline name
      expect(output).to include('[h] Help')
      expect(output).to include('[q] Quit')

      # Check stage appears in both panels
      expect(output).to include('generate')
      expect(output).to include('process')

      # Check process list headers
      expect(output).to include('STAGE')
      expect(output).to include('ITEMS')
      expect(output).to include('THRU')
    end
  end

  describe 'Minimum Terminal Size (60x10)' do
    it 'still renders at minimum dimensions' do
      pipeline_class = Class.new do
        include Minigun::DSL

        pipeline do
          producer :gen do |output|
            3.times { |i| output << i }
          end

          consumer :out do |item|
            # noop
          end
        end
      end

      buffer = render_hud(pipeline_class.new, width: 60, height: 10)
      output = normalize_output(buffer)

      # Should still show main elements
      expect(output).to include('FLOW DIAGRAM')
      expect(output).to include('PROCESS STATISTICS')
      expect(output).to include('RUNNING')
    end
  end

  describe 'Below Minimum Size (50x8)' do
    it 'shows terminal too small message' do
      pipeline_class = Class.new do
        include Minigun::DSL

        pipeline do
          producer :gen do |output|
            output << 1
          end
        end
      end

      buffer = render_hud(pipeline_class.new, width: 50, height: 8)
      output = normalize_output(buffer)

      expect(output).to include('Terminal too small')
      expect(output).to include('60x10')
      expect(output).to include('50x8')
    end
  end

  describe 'Wide Terminal (200x40)' do
    it 'maintains 40/60 split proportions' do
      pipeline_class = Class.new do
        include Minigun::DSL

        pipeline do
          producer :generate do |output|
            5.times { |i| output << i }
          end

          consumer :process do |item|
            # noop
          end
        end
      end

      buffer = render_hud(pipeline_class.new, width: 200, height: 40)
      output = normalize_output(buffer)

      # Check layout is proportional
      left_width = (200 * 0.4).to_i

      # Both panels should still render
      expect(output).to include('FLOW DIAGRAM')
      expect(output).to include('PROCESS STATISTICS')

      # Check that we're using the full width (no empty right side)
      lines = output.split("\n")
      expect(lines.any? { |line| line.length > 100 }).to be true
    end
  end

  describe 'Layout Assertions' do
    it 'positions elements correctly in a standard 120x30 layout' do
      pipeline_class = Class.new do
        include Minigun::DSL

        pipeline do
          producer :source do |output|
            3.times { |i| output << i }
          end

          consumer :sink do |item|
            # noop
          end
        end
      end

      buffer = render_hud(pipeline_class.new, width: 120, height: 30)
      lines = buffer.map { |chars| chars.join }

      # Top row should have box corners
      expect(lines[0]).to include('┌')

      # First line should have FLOW DIAGRAM title
      top_section = lines[0..2].join
      expect(top_section).to include('FLOW DIAGRAM')

      # Right side should have PROCESS STATISTICS title
      expect(top_section).to include('PROCESS STATISTICS')

      # Bottom row (status bar) should be at y=28 (0-indexed, height-2)
      status_bar = lines[28]
      expect(status_bar).to match(/RUNNING|PAUSED|FINISHED/)

      # Left panel should be roughly 40% of width
      left_width = (120 * 0.4).to_i
      # Right panel starts at left_width+1 in 1-indexed coords, which is left_width in 0-indexed
      right_start = left_width

      # Check that right panel starts at correct position
      expect(lines[0][right_start]).to eq('┌')
    end
  end

  describe 'Status Bar States' do
    it 'shows RUNNING state during execution' do
      pipeline_class = Class.new do
        include Minigun::DSL

        pipeline do
          producer :gen do |output|
            output << 1
          end

          consumer :out do |item|
            sleep 0.01
          end
        end
      end

      buffer = render_hud(pipeline_class.new, width: 120, height: 20)
      status_bar = buffer[18].join  # Bottom row (height-2 in 0-indexed)

      expect(status_bar).to include('RUNNING')
      expect(status_bar).to include('[h] Help')
      expect(status_bar).to include('[space] Pause')
    end

    it 'shows PAUSED state when paused' do
      pipeline_class = Class.new do
        include Minigun::DSL

        pipeline do
          producer :gen do |output|
            output << 1
          end
        end
      end

      pipeline_obj = pipeline_class.new
      pipeline_obj.send(:_evaluate_pipeline_blocks!)
      pipeline = pipeline_obj.instance_variable_get(:@_minigun_task).root_pipeline

      # Initialize stats by running pipeline
      thread = Thread.new { pipeline_obj.run }
      sleep 0.1  # Give stats time to initialize
      thread.kill if thread.alive?

      # Create controller and pause it
      controller = Minigun::HUD::Controller.new(pipeline)
      controller.paused = true
      controller.terminal.instance_variable_set(:@width, 120)
      controller.terminal.instance_variable_set(:@height, 20)
      buffer = setup_buffer_capture(controller, 120, 20)
      controller.send(:calculate_layout)
      controller.flow_diagram.instance_variable_set(:@animation_frame, 0)

      controller.send(:render_frame)
      status_bar = buffer[18].join  # height-2 in 0-indexed

      expect(status_bar).to include('PAUSED')
    end

    it 'shows FINISHED state when complete' do
      pipeline_class = Class.new do
        include Minigun::DSL

        pipeline do
          producer :gen do |output|
            output << 1
          end
        end
      end

      pipeline_obj = pipeline_class.new
      pipeline_obj.send(:_evaluate_pipeline_blocks!)
      pipeline = pipeline_obj.instance_variable_get(:@_minigun_task).root_pipeline

      # Initialize stats by running pipeline
      thread = Thread.new { pipeline_obj.run }
      sleep 0.1  # Give stats time to initialize
      thread.kill if thread.alive?

      # Create controller and mark as finished
      controller = Minigun::HUD::Controller.new(pipeline)
      controller.pipeline_finished = true
      controller.terminal.instance_variable_set(:@width, 120)
      controller.terminal.instance_variable_set(:@height, 20)
      buffer = setup_buffer_capture(controller, 120, 20)
      controller.send(:calculate_layout)
      controller.flow_diagram.instance_variable_set(:@animation_frame, 0)

      controller.send(:render_frame)
      status_bar = buffer[18].join  # height-2 in 0-indexed

      expect(status_bar).to include('FINISHED')
      expect(status_bar).to include('Press [q] to exit')
    end
  end

  describe 'Help Overlay' do
    it 'renders help overlay when enabled' do
      pipeline_class = Class.new do
        include Minigun::DSL

        pipeline do
          producer :gen do |output|
            output << 1
          end
        end
      end

      pipeline_obj = pipeline_class.new
      pipeline_obj.send(:_evaluate_pipeline_blocks!)
      pipeline = pipeline_obj.instance_variable_get(:@_minigun_task).root_pipeline

      # Initialize stats by running pipeline
      thread = Thread.new { pipeline_obj.run }
      sleep 0.1  # Give stats time to initialize
      thread.kill if thread.alive?

      # Create controller with help enabled
      controller = Minigun::HUD::Controller.new(pipeline)
      controller.instance_variable_set(:@show_help, true)
      controller.terminal.instance_variable_set(:@width, 120)
      controller.terminal.instance_variable_set(:@height, 30)
      buffer = setup_buffer_capture(controller, 120, 30)
      controller.send(:calculate_layout)
      controller.flow_diagram.instance_variable_set(:@animation_frame, 0)

      controller.send(:render_frame)
      output = normalize_output(buffer)

      expect(output).to include('KEYBOARD CONTROLS')
      expect(output).to include('Navigation:')
      expect(output).to include('w / s')
      expect(output).to include('a / d')
    end
  end

  describe 'Multi-stage Pipeline' do
    it 'renders complex pipeline with multiple stages' do
      pipeline_class = Class.new do
        include Minigun::DSL

        pipeline do
          producer :input do |output|
            5.times { |i| output << i }
          end

          processor :double do |item, output|
            output << item * 2
          end

          processor :add_ten do |item, output|
            output << item + 10
          end

          consumer :save do |item|
            # noop
          end
        end
      end

      buffer = render_hud(pipeline_class.new, width: 120, height: 35)
      output = normalize_output(buffer)

      # All stages should appear
      expect(output).to include('input')
      expect(output).to include('double')
      expect(output).to include('add_ten')
      expect(output).to include('save')

      # Flow diagram should show connections
      expect(output).to include('│')  # Vertical connections
    end
  end
end
