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
    # Producer - generates numbers infinitely
    producer :generator do |output|
      puts "Starting infinite data generation..."
      puts "Press Ctrl+C or 'q' in the HUD to stop"

      counter = 0
      loop do
        output << counter
        counter += 1

        # Vary the sleep time to create interesting throughput patterns
        sleep_time = 0.01 + (Math.sin(counter / 20.0).abs * 0.05)
        sleep sleep_time
      end
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
      # Simulate batch processing with varying latency
      sleep 0.05 + rand(0.1)
      # Uncomment to see batch processing messages
      # puts "Processed batch of #{batch.size} items (#{batch.first}..#{batch.last})"
    end
  end
end

# Run the demo
puts "=" * 60
puts "MINIGUN HUD DEMO - INFINITE MODE"
puts "=" * 60
puts ""
puts "This demo shows the HUD monitoring a pipeline in real-time."
puts "The pipeline continuously generates and processes data with"
puts "varying latencies to demonstrate different performance patterns."
puts ""
puts "Features to observe:"
puts "  - Real-time throughput metrics"
puts "  - Animated flow diagram (left panel)"
puts "  - Live performance statistics (right panel)"
puts "  - Bottleneck detection"
puts "  - Latency percentiles (P50, P99)"
puts ""
puts "Controls:"
puts "  - Press SPACE to pause/resume"
puts "  - Press 'h' for help"
puts "  - Press 'q' to quit (or Ctrl+C)"
puts "  - Use ↑/↓ to scroll"
puts ""
puts "Starting in 3 seconds..."
sleep 3

# Create and run task with HUD
begin
  Minigun::HUD.run_with_hud(HudDemoTask)
rescue Interrupt
  puts "\nInterrupted by user"
end

puts "\nDemo complete!"
