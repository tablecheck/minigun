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

  # Helper to strip dynamic values (numbers, times, rates) for structural comparison
  def strip_dynamic(text)
    text.gsub(/[⠀⠁⠃⠇⠏⠟⠿⡿⣿]/, '│')              # Animation chars -> static vertical
        .gsub(/\d+\.\d+[KM]? i\/s/, 'X.XX i/s')   # Item rates (with space)
        .gsub(/\d+\.\d+[KM]? i$/, 'X.XX i')       # Item rates (end of line)
        .gsub(/\d+\.\d+[KM]?\/s/, 'X.XX/s')       # Throughput rates
        .gsub(/\d+\.\d+ms/, 'X.Xms')              # Latency
        .gsub(/\d+\.\d+s/, 'X.Xs')                # Runtime
        .gsub(/:\s+\d+/, ': X')                   # Counts like "Produced: 5"
        .gsub(/\s+\d+\s+/, '   X   ')             # Column values like "  5  "
  end

  describe 'Standard Terminal Size (120x30)' do
    it 'renders complete HUD with both panels' do
      expected = strip_ascii(<<-ASCII)
┌─ FLOW DIAGRAM ───────────────────────────────┐┌─ PROCESS STATISTICS ─────────────────────────────────────────────────┐
│                                              ││                                                                      │
│                ┌────────────┐                ││ Runtime:     X.Xs | Throughput:      X.XX i
│                │ ▶ generate │                ││ Produced: X | Consumed: X│
│                └────────────┘                ││                                                                      │
│                       │                      ││ STAGE                    ITEMS      THRU       P50       P99         │
│                       │                      ││ ──────────────────────────────────────────────────────────────────   │
│                ┌────────────┐                ││ ▶ generate          ⚡   X   X.XX/s         -         -         │
│                │ ◀ process  │                ││ ◀ process           ⚠   X   X.XX/s    X.Xms    X.Xms         │
│                └────────────┘                ││                                                                      │
│                                              ││                                                                      │
│                                              ││                                                                      │
│                                              ││                                                                      │
│                                              ││                                                                      │
│                                              ││                                                                      │
│                                              ││                                                                      │
│                                              ││                                                                      │
│                                              ││                                                                      │
│                                              ││                                                                      │
│                                              ││                                                                      │
│                                              ││                                                                      │
│                                              ││                                                                      │
│                                              ││                                                                      │
│                                              ││                                                                      │
│                                              ││                                                                      │
│                                              ││                                                                      │
│                                              ││                                                                      │
└──────────────────────────────────────────────┘└──────────────────────────────────────────────────────────────────────┘
 RUNNING | Pipeline: default                             [h] Help [q] Quit [space] Pause
ASCII

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
      actual = normalize_output(buffer)

      # Strip dynamic values and assert full ASCII layout
      expect(strip_ascii(strip_dynamic(actual))).to eq(expected)
    end
  end

  describe 'Below Minimum Size' do
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
      actual = normalize_output(buffer)

      # Just check the error message is present
      expect(strip_ascii(actual)).to include('Terminal too small! Minimum: 60x10, Current: 50x8')
    end
  end

  describe 'Status Bar States' do
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
      sleep 0.1
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
      sleep 0.1
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
      sleep 0.1
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
end
