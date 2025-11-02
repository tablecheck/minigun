#!/usr/bin/env ruby
# frozen_string_literal: true

# Example: Routing to Nested Pipeline Stages
#
# Demonstrates how parent pipeline stages can route directly to stages
# within nested pipelines using the DAG-centric architecture.
#
# In this example:
# - accumulator batches items and routes to :save (nested stage)
# - :save is inside a process_per_batch nested pipeline
# - Parent DAG includes nested stages, enabling direct routing

require_relative '../lib/minigun'

class RoutingToNestedStagesExample
  include Minigun::DSL

  attr_reader :results

  def initialize
    @results = []
  end

  pipeline do
    # Generate some test data
    producer :gen do |output|
      5.times do |i|
        puts "[Producer] Generating item #{i + 1}"
        output << i + 1
      end
    end

    # Batch items and route directly to nested :save stage
    accumulator :batch, max_size: 2, to: [:save] do |items, output|
      puts "[Accumulator] Batched #{items.size} items: #{items.inspect}"
      output << items
    end

    # Nested pipeline with forked execution
    process_per_batch(max: 2) do
      consumer :save do |batch|
        puts "[Consumer:save] (PID #{Process.pid}) Received batch: #{batch.inspect}"
        @results.concat(batch)
        sleep 0.1 # Simulate work
      end
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  puts "=" * 60
  puts "Example: Routing to Nested Pipeline Stages"
  puts "=" * 60

  example = RoutingToNestedStagesExample.new
  example.run

  puts "\n" + "=" * 60
  puts "Results:"
  puts "  Items processed: #{example.results.sort.inspect}"
  puts "  Expected: [1, 2, 3, 4, 5]"
  puts "  Status: #{example.results.sort == [1, 2, 3, 4, 5] ? '✓ SUCCESS' : '✗ FAILED'}"
  puts "=" * 60
end
