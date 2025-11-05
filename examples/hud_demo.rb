#!/usr/bin/env ruby
# frozen_string_literal: true

# Demo script showing Minigun HUD in action
# Run with: ruby examples/hud_demo.rb

require_relative '../lib/minigun'
require_relative '../lib/minigun/hud'

# Define a demo pipeline with various stages
class HudDemoTask
  include Minigun::DSL

  pipeline do
    # Producer - generates numbers
    producer :generator do |output|
      puts "Starting data generation..."
      100.times do |i|
        output << i
        sleep 0.05 # Slow down to see animation
      end
      puts "Generation complete!"
    end

    # Processor - transforms data
    processor :doubler, threads: 3 do |num, output|
      result = num * 2
      sleep rand(0.01..0.05) # Simulate varying latency
      output << result
    end

    # Processor - adds offset
    processor :adder, threads: 2 do |num, output|
      result = num + 100
      sleep rand(0.02..0.08) # Simulate slower processing
      output << result
    end

    # Accumulator - batch items
    accumulator :batcher, max_size: 10 do |batch, output|
      output << batch
    end

    # Consumer - process batches
    consumer :processor, threads: 2 do |batch, _output|
      # Simulate batch processing
      sleep 0.1
      puts "Processed batch of #{batch.size} items"
    end
  end
end

# Run the demo
puts "=" * 60
puts "MINIGUN HUD DEMO"
puts "=" * 60
puts ""
puts "This demo will show the HUD monitoring a pipeline in real-time."
puts "The pipeline processes 100 numbers through multiple stages."
puts ""
puts "Controls:"
puts "  - Press SPACE to pause/resume"
puts "  - Press 'h' for help"
puts "  - Press 'q' to quit"
puts ""
puts "Starting in 3 seconds..."
sleep 3

# Create and run task with HUD
task = HudDemoTask.new
pipeline = task.pipelines.first

# Start HUD in a thread
hud = Minigun::HUD::Controller.new(pipeline)
hud_thread = Thread.new { hud.start }

# Give HUD time to initialize
sleep 0.5

# Run the pipeline
begin
  task.run
rescue Interrupt
  puts "\nInterrupted by user"
ensure
  # Keep HUD running for a moment to show final stats
  sleep 2

  # Stop HUD
  hud.stop
  hud_thread.join(timeout: 1)
  hud_thread.kill if hud_thread.alive?
end

puts "\nDemo complete!"
