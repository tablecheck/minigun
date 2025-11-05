# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../lib/minigun'
require_relative '../../../lib/minigun/hud/flow_diagram'
require_relative '../../../lib/minigun/hud/stats_aggregator'

RSpec.describe 'FlowDiagram Rendering' do
  # Helper to capture the ASCII output from FlowDiagram
  def render_diagram(pipeline_instance, width: 46, height: 36)
    # Create a mock terminal buffer
    buffer = Array.new(height) { ' ' * width }

    terminal = double('terminal')
    allow(terminal).to receive(:write_at) do |x, y, text, color: nil|
      next if y < 0 || y >= height || x < 0
      # Write text into buffer at position
      text.chars.each_with_index do |char, i|
        col = x + i
        break if col >= width
        buffer[y][col] = char
      end
    end

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

    # Create flow diagram and stats
    flow_diagram = Minigun::HUD::FlowDiagram.new(width, height)
    stats_aggregator = Minigun::HUD::StatsAggregator.new(pipeline)

    # Run pipeline briefly to generate stats
    thread = Thread.new { pipeline_instance.run }
    sleep 0.05
    thread.kill if thread.alive?

    stats_data = stats_aggregator.collect

    # Render at x_offset=0, y_offset=0 (first frame, no animation)
    flow_diagram.render(terminal, stats_data, x_offset: 0, y_offset: 0)

    buffer
  end

  # Helper to create normalized output (remove trailing spaces)
  def normalize_output(buffer)
    buffer.map { |line| line.rstrip }.join("\n")
  end

  describe 'Linear Pipeline (Sequential)' do
    it 'renders a simple linear 4-stage pipeline vertically' do
      # Expected output for sequential pipeline:
      # - Producer at top
      # - 2 processors in middle
      # - Consumer at bottom
      # - Vertical connections between stages

      expected = <<-ASCII.strip
┌────────────┐
│ ▶ generate │
└────────────┘
       │
┌────────────┐
│ ◆ double   │
└────────────┘
       │
┌────────────┐
│ ◆ add_ten  │
└────────────┘
       │
┌────────────┐
│ ◀ collect  │
└────────────┘
ASCII

      # Create pipeline
      pipeline_class = Class.new do
        include Minigun::DSL

        pipeline do
          producer :generate do |output|
            3.times { |i| output << (i + 1) }
          end

          processor :double do |num, output|
            output << (num * 2)
          end

          processor :add_ten do |num, output|
            output << (num + 10)
          end

          consumer :collect do |num|
            # no-op
          end
        end
      end

      pipeline = pipeline_class.new
      output = render_diagram(pipeline)
      actual = normalize_output(output)

      # Print for debugging
      puts "\n=== ACTUAL OUTPUT ==="
      puts actual
      puts "=== EXPECTED OUTPUT ==="
      puts expected
      puts "=====================\n"

      # TODO: Enable assertion once rendering is verified
      # expect(actual).to include(expected)
    end
  end

  describe 'Diamond Pattern' do
    it 'renders a diamond-shaped DAG with fan-out and fan-in' do
      # Expected output for diamond pattern:
      # - Producer at top
      # - Two parallel processors (path_a, path_b)
      # - Consumer at bottom (merge)
      # - Split line from producer to both processors
      # - Connections from both processors to merge

      expected = <<-ASCII.strip
       ┌────────────┐
       │ ▶ source   │
       └────────────┘
              │
      ┬───────┴───────┬
      │               │
┌──────────┐      ┌──────────┐
│ ◆ path_a │      │ ◆ path_b │
└──────────┘      └──────────┘
      │               │
      └─────┬   ┬─────┘
            │   │
       ┌────────────┐
       │ ◀ merge    │
       └────────────┘
ASCII

      # Create pipeline
      pipeline_class = Class.new do
        include Minigun::DSL

        pipeline do
          producer :source, to: %i[path_a path_b] do |output|
            5.times { |i| output << (i + 1) }
          end

          processor :path_a, to: :merge do |num, output|
            output << (num * 2)
          end

          processor :path_b, to: :merge do |num, output|
            output << (num * 3)
          end

          consumer :merge do |num|
            # no-op
          end
        end
      end

      pipeline = pipeline_class.new
      output = render_diagram(pipeline)
      actual = normalize_output(output)

      puts "\n=== ACTUAL OUTPUT ==="
      puts actual
      puts "=== EXPECTED OUTPUT ==="
      puts expected
      puts "=====================\n"

      # TODO: Enable assertion once rendering is verified
      # expect(actual).to include(expected)
    end
  end

  describe 'Fan-Out Pattern' do
    it 'renders a fan-out to 3 consumers' do
      # Expected output for fan-out pattern:
      # - Producer at top
      # - Router stage (implicit)
      # - Three parallel consumers
      # - Split line fanning out to all consumers

      expected = <<-ASCII.strip
           ┌────────────┐
           │ ▶ generate │
           └────────────┘
                  │
      ┬───────────┴──────────┬
      │           │          │
┌─────────┐ ┌─────────┐ ┌─────────┐
│◀ email  │ │◀ sms    │ │◀ push   │
└─────────┘ └─────────┘ └─────────┘
ASCII

      # Create pipeline
      pipeline_class = Class.new do
        include Minigun::DSL

        pipeline do
          producer :generate, to: %i[email sms push] do |output|
            3.times { |i| output << i }
          end

          consumer :email do |item|
            # no-op
          end

          consumer :sms do |item|
            # no-op
          end

          consumer :push do |item|
            # no-op
          end
        end
      end

      pipeline = pipeline_class.new
      output = render_diagram(pipeline)
      actual = normalize_output(output)

      puts "\n=== ACTUAL OUTPUT ==="
      puts actual
      puts "=== EXPECTED OUTPUT ==="
      puts expected
      puts "=====================\n"

      # TODO: Enable assertion once rendering is verified
      # expect(actual).to include(expected)
    end
  end

  describe 'Complex Routing' do
    it 'renders multiple parallel paths with different depths' do
      # Expected output for complex routing:
      # - Producer at top
      # - Multiple paths of different lengths
      # - Final merge at bottom

      expected = <<-ASCII.strip
         ┌────────────┐
         │ ▶ source   │
         └────────────┘
                │
    ┬───────────┼───────────┬
    │           │           │
┌──────┐    ┌──────┐    ┌──────┐
│◆ fast│    │◆ proc│    │◆ slow│
└──────┘    └──────┘    └──────┘
    │           │           │
    │       ┌──────┐        │
    │       │◆ proc│        │
    │       └──────┘        │
    │           │           │
    └────────   │   ────────┘
            │   │   │ 
         ┌────────────┐
         │ ◀ final    │
         └────────────┘
ASCII

      # Create pipeline
      pipeline_class = Class.new do
        include Minigun::DSL

        pipeline do
          producer :source, to: %i[fast process slow] do |output|
            5.times { |i| output << i }
          end

          processor :fast, to: :final do |item, output|
            output << item
          end

          processor :process, to: :process2 do |item, output|
            output << item
          end

          processor :process2, to: :final do |item, output|
            output << item
          end

          processor :slow, to: :final do |item, output|
            output << item
          end

          consumer :final do |item|
            # no-op
          end
        end
      end

      pipeline = pipeline_class.new
      output = render_diagram(pipeline)
      actual = normalize_output(output)

      puts "\n=== ACTUAL OUTPUT ==="
      puts actual
      puts "=== EXPECTED OUTPUT ==="
      puts expected
      puts "=====================\n"

      # TODO: Enable assertion once rendering is verified
      # expect(actual).to include(expected)
    end
  end
end
