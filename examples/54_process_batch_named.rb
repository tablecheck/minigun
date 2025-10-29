#!/usr/bin/env ruby
# frozen_string_literal: true

# Example 54: Process Per Batch + Named Context
# Test process_per_batch with named contexts before and after

require_relative '../lib/minigun'

# Demonstrates process-per-batch with named contexts
class ProcessBatchNamedExample
  include Minigun::DSL

  attr_reader :results

  def initialize
    @results = []
    @mutex = Mutex.new
  end

  pipeline do
    execution_context :before_pool, :threads, 3
    execution_context :after_pool, :threads, 2

    producer :gen do |output|
      20.times { |i| output << i }
    end

    processor :prep, execution_context: :before_pool do |item, output|
      output << (item + 1)
    end

    batch 5

    process_per_batch(max: 2) do
      processor :process_batch do |batch, output|
        batch.each { |item| output << (item * 2) }
      end
    end

    processor :post, execution_context: :after_pool do |item, output|
      output << (item + 100)
    end

    consumer :save do |item|
      @mutex.synchronize { @results << item }
    end
  end
end

puts 'Testing: process_per_batch + named contexts'
pipeline = ProcessBatchNamedExample.new
pipeline.run
puts "Results: #{pipeline.results.size} items"
puts '✓ Process batch + named works' if pipeline.results.size == 20
