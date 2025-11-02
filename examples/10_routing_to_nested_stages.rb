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
require 'tempfile'

class RoutingToNestedStagesExample
  include Minigun::DSL

  attr_reader :results

  def initialize
    @results = []
    @temp_file = Tempfile.new(['minigun_routing_results', '.txt'])
    @temp_file.close
  end

  def cleanup
    File.unlink(@temp_file.path) if @temp_file && File.exist?(@temp_file.path)
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
        
        # Write to temp file (fork-safe) - each item on its own line
        File.open(@temp_file.path, 'a') do |f|
          f.flock(File::LOCK_EX)
          batch.each { |item| f.puts(item) }
          f.flock(File::LOCK_UN)
        end
        
        sleep 0.1 # Simulate work
      end
    end

    after_run do
      # Read fork results from temp file
      if File.exist?(@temp_file.path)
        @results = File.readlines(@temp_file.path).map(&:to_i)
      end
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  puts "=" * 60
  puts "Example: Routing to Nested Pipeline Stages"
  puts "=" * 60

  example = RoutingToNestedStagesExample.new
  begin
    example.run

    puts "\n" + "=" * 60
    puts "Results:"
    puts "  Items processed: #{example.results.sort.inspect}"
    puts "  Expected: [1, 2, 3, 4, 5]"
    puts "  Status: #{example.results.sort == [1, 2, 3, 4, 5] ? '✓ SUCCESS' : '✗ FAILED'}"
    puts "=" * 60
  ensure
    example.cleanup
  end
end
