# frozen_string_literal: true

# Example: Round-Robin Load Balancing
#
# Demonstrates automatic round-robin distribution when a producer fans out to multiple terminal consumers.
# This is useful for distributing work evenly across multiple worker threads or processes.

require_relative '../lib/minigun'

# Demonstrates round-robin load balancing across multiple workers
class RoundRobinLoadBalancingExample
  include Minigun::DSL

  attr_accessor :results

  def initialize
    @results = []
    @mutex = Mutex.new
  end

  pipeline do
    # Producer with explicit round-robin routing to multiple consumers
    # routing: :round_robin distributes items evenly across workers for load balancing
    producer :generate_work, to: %i[worker1 worker2 worker3], routing: :round_robin do |output|
      puts "\n[Producer] Generating 10 work items..."
      10.times { |i| output << i }
    end

    # Multiple consumers that process work in parallel
    # Items will be distributed round-robin across these workers
    consumer :worker1 do |item|
      sleep 0.01  # Simulate work
      @mutex.synchronize do
        @results << { worker: 1, item: item }
        puts "[Worker 1] Processed item #{item}"
      end
    end

    consumer :worker2 do |item|
      sleep 0.01  # Simulate work
      @mutex.synchronize do
        @results << { worker: 2, item: item }
        puts "[Worker 2] Processed item #{item}"
      end
    end

    consumer :worker3 do |item|
      sleep 0.01  # Simulate work
      @mutex.synchronize do
        @results << { worker: 3, item: item }
        puts "[Worker 3] Processed item #{item}"
      end
    end
  end
end

# Run the pipeline
pipeline = RoundRobinLoadBalancingExample.new
pipeline.run

# Display results
puts "\n#{'=' * 60}"
puts 'ROUND-ROBIN LOAD BALANCING RESULTS'
puts '=' * 60

puts "\nProcessing order:"
pipeline.results.sort_by { |r| r[:item] }.each do |r|
  puts "  Item #{r[:item]} -> Worker #{r[:worker]}"
end

worker_counts = pipeline.results.group_by { |r| r[:worker] }.transform_values(&:count)
puts "\nWorker distribution:"
worker_counts.each { |worker, count| puts "  Worker #{worker}: #{count} items" }

puts "\nNote: Items are evenly distributed across workers using round-robin strategy."
puts 'This happens automatically when a stage fans out to multiple terminal consumers.'
