# frozen_string_literal: true

require_relative '../lib/minigun'

# Example demonstrating queue sizing and backpressure
class BackpressureDemoExample
  include Minigun::DSL

  attr_reader :items_to_generate

  def initialize(items: 100)
    @items_to_generate = items
  end

  pipeline do
    # Fast producer - generates items immediately
    producer :fast_producer do |output|
      puts "Producer: Starting to generate #{@items_to_generate} items..."
      @items_to_generate.times do |i|
        output << i
        print '.' if (@items_to_generate >= 100) && (i % 100) == 0
      end
      puts "\nProducer: Done! (Would finish instantly without backpressure)"
    end

    # Slow consumer with small queue (creates backpressure)
    consumer :slow_consumer, queue_size: 10 do |item, _output|
      sleep 0.001 # Simulate slow processing (reduced for tests)
      puts "Consumer: Processed item #{item}" if (@items_to_generate >= 100) && (item % 100) == 0
    end
  end
end

# Example with multiple stages and varying queue sizes
class MultiStageBackpressure
  include Minigun::DSL

  pipeline do
    # Burst producer - produces items in bursts
    producer :bursty_source do |output|
      puts "\n=== Bursty Producer ==="
      5.times do |burst|
        puts "Burst #{burst + 1}: Sending 20 items..."
        20.times { |i| output << ((burst * 20) + i) }
        sleep 0.5 # Pause between bursts
      end
    end

    # First stage with small queue - immediate backpressure
    processor :stage1, queue_size: 5 do |item, output|
      sleep 0.05 # Moderate processing time
      output << (item * 2)
    end

    # Second stage with large queue - buffers bursts
    processor :stage2, queue_size: 50 do |item, output|
      sleep 0.01 # Fast processing
      output << (item + 1)
    end

    # Final consumer
    consumer :final_sink do |item, output|
      # Just consume
    end
  end
end

# Example comparing bounded vs unbounded queues
class BoundedExample
  include Minigun::DSL

  pipeline do
    producer :producer do |output|
      start = Time.now
      puts 'Producer: Starting...'
      100.times do |i|
        output << i
        puts "Producer: Sent #{i + 1} items (#{Time.now - start}s)" if (i + 1) % 20 == 0
      end
      elapsed = Time.now - start
      puts "Producer: Done in #{elapsed.round(2)}s (throttled by backpressure)"
    end

    consumer :slow_consumer, queue_size: 10 do |_item, _output|
      sleep 0.05 # 50ms per item
    end
  end
end

# Demonstrates unbounded queues with no backpressure
class UnboundedExample
  include Minigun::DSL

  pipeline do
    producer :producer do |output|
      start = Time.now
      puts 'Producer: Starting...'
      100.times do |i|
        output << i
        puts "Producer: Sent #{i + 1} items (#{Time.now - start}s)" if (i + 1) % 20 == 0
      end
      elapsed = Time.now - start
      puts "Producer: Done in #{elapsed.round(2)}s (no backpressure!)"
    end

    consumer :slow_consumer, queue_size: Float::INFINITY do |_item, _output|
      sleep 0.05 # 50ms per item
    end
  end
end

# Example with global configuration
class GlobalConfigSmallExample
  include Minigun::DSL

  pipeline do
    producer :source do |output|
      start = Time.now
      puts 'Producing 50 items...'
      50.times { |i| output << i }
      elapsed = Time.now - start
      puts "Producer done in #{elapsed.round(2)}s"
    end

    # This stage uses the global default
    consumer :sink do |_item, _output|
      sleep 0.02 # 20ms per item
    end
  end
end

# Demonstrates global queue size configuration
class GlobalConfigLargeExample
  include Minigun::DSL

  pipeline do
    producer :source do |output|
      start = Time.now
      puts 'Producing 50 items...'
      50.times { |i| output << i }
      elapsed = Time.now - start
      puts "Producer done in #{elapsed.round(2)}s"
    end

    # This stage uses the global default
    consumer :sink do |_item, _output|
      sleep 0.02 # 20ms per item
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  puts "\n#{'=' * 70}"
  puts 'BACKPRESSURE DEMONSTRATION'
  puts '=' * 70
  puts "\nThis example shows how queue sizing affects pipeline behavior:"
  puts '- Bounded queues create backpressure (slow consumers throttle producers)'
  puts '- Unbounded queues allow producers to finish immediately'
  puts '- Small queues provide tight coupling'
  puts '- Large queues buffer bursts'

  # Example 1: Simple backpressure
  puts "\n#{'=' * 70}"
  puts 'Example 1: Fast Producer + Slow Consumer (queue_size: 10)'
  puts '=' * 70
  puts 'Watch how the producer is throttled by the small queue'
  BackpressureDemoExample.new(items: 1000).run

  # Example 2: Multi-stage with different queue sizes
  puts "\n#{'=' * 70}"
  puts 'Example 2: Multiple Stages with Different Queue Sizes'
  puts '=' * 70
  MultiStageBackpressure.new.run

  # Example 3: Bounded vs Unbounded comparison
  puts "\n#{'=' * 70}"
  puts 'Example 3A: BOUNDED QUEUE (queue_size: 10)'
  puts '=' * 70
  puts "Producer will be throttled by slow consumer\n\n"
  BoundedExample.new.run

  puts "\n#{'=' * 70}"
  puts 'Example 3B: UNBOUNDED QUEUE (queue_size: Float::INFINITY)'
  puts '=' * 70
  puts "Producer will finish immediately, queue will grow\n\n"
  UnboundedExample.new.run

  # Example 4: Global configuration
  puts "\n#{'=' * 70}"
  puts 'Example 4A: Global Configuration (default_queue_size: 5)'
  puts '=' * 70
  puts "Tight backpressure\n\n"
  Minigun.configure { |config| config.default_queue_size = 5 }
  GlobalConfigSmallExample.new.run

  puts "\n#{'=' * 70}"
  puts 'Example 4B: Global Configuration (default_queue_size: 100)'
  puts '=' * 70
  puts "Loose backpressure\n\n"
  Minigun.configure { |config| config.default_queue_size = 100 }
  GlobalConfigLargeExample.new.run

  puts "\n#{'=' * 70}"
  puts 'KEY TAKEAWAYS:'
  puts '=' * 70
  puts '✓ Bounded queues (SizedQueue) provide automatic backpressure'
  puts '✓ Small queues (5-50) = tight coupling, immediate throttling'
  puts '✓ Large queues (1000+) = buffering for bursty workloads'
  puts '✓ Unbounded queues = no backpressure, potential memory issues'
  puts '✓ Default (1000) is a good balance for most use cases'
  puts "\nChoose queue sizes based on your producer/consumer speed ratio!"
end
