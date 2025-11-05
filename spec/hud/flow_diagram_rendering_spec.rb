# frozen_string_literal: true

require 'spec_helper'
require_relative '../../lib/minigun'
require_relative '../../lib/minigun/hud/flow_diagram'
require_relative '../../lib/minigun/hud/stats_aggregator'

RSpec.describe 'FlowDiagram Rendering' do
  def strip_ascii(str)
    str = str.dup
    str.sub!(/\A( *\n)+/m, '')
    str.sub!(/(\n *)+\z/m, '')
    str
  end

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

    # Run pipeline briefly to generate DAG structure
    thread = Thread.new { pipeline_instance.run }
    sleep 0.05
    thread.kill if thread.alive?

    stats_data = stats_aggregator.collect

    # Stub dynamic elements for deterministic output:
    # 1. Zero out throughput so connections render as static (not animated)
    stats_data[:stages].each { |s| s[:throughput] = 0 }
    # 2. Reset animation frame to 0
    flow_diagram.instance_variable_set(:@animation_frame, 0)

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
      # Expected: Clean layout (left-aligned, static connections)
      expected = strip_ascii(<<-ASCII)
┌────────────┐
│ ▶ generate │
└────────────┘
       │
       │
┌────────────┐
│  ◀ double  │
└────────────┘
       │
       │
┌────────────┐
│ ◀ add_ten  │
└────────────┘
       │
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

      # Literal assertion of ASCII layout
      expect(strip_ascii(actual)).to eq(expected)
    end
  end

  describe 'Diamond Pattern' do
    it 'renders a diamond-shaped DAG with fan-out and fan-in' do
      # Expected: Diamond pattern with fan-out and fan-in
      expected = strip_ascii(<<-ASCII)
        ┌────────────┐
        │  ▶ source  │
        └────────────┘
               │
       ┌───────┴───────┐
┌────────────┐  ┌────────────┐
│  ◀ path_b  │  │  ◀ path_a  │
└────────────┘  └────────────┘
       │               │
       └───────┬───────┘
        ┌────────────┐
        │  ◀ merge   │
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

      # Literal assertion of ASCII layout
      expect(strip_ascii(actual)).to eq(expected)
    end
  end

  describe 'Fan-Out Pattern' do
    it 'renders a fan-out to 3 consumers' do
      # Expected: Producer centered above 3 consumers
      expected = strip_ascii(<<-ASCII)
                ┌────────────┐
                │ ▶ generate │
                └────────────┘
                       │
       ┌───────────────┼───────────────┐
┌────────────┐  ┌────────────┐  ┌────────────┐
│   ◀ push   │  │   ◀ sms    │  │  ◀ email   │
└────────────┘  └────────────┘  └────────────┘
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

      puts "\n=== FAN-OUT ACTUAL ==="
      puts actual
      puts "======================\n"

      # Literal assertion of ASCII layout
      expect(strip_ascii(actual)).to eq(expected)
    end
  end

  describe 'Complex Routing' do
    it 'renders multiple parallel paths with different depths' do
      # Expected: Multiple paths with different lengths merging to final
      expected = strip_ascii(<<-ASCII)
                ┌────────────┐
                │  ▶ source  │
                └────────────┘
                       │
       ┌───────────────┼───────────────┐
┌────────────┐  ┌────────────┐  ┌────────────┐
│   ◀ slow   │  │ ◀ process  │  │   ◀ fast   │
└────────────┘  └────────────┘  └────────────┘
       │               │               │
       │               │               │
       │        ┌────────────┐         │
       │        │ ◀ process2 │         │
       │        └────────────┘         │
       │               │               │
       └───────────────┼───────────────┘
                ┌────────────┐
                │  ◀ final   │
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

      # Literal assertion of ASCII layout
      expect(strip_ascii(actual)).to eq(expected)
    end
  end
end
