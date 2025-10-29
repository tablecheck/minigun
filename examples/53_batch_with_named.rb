#!/usr/bin/env ruby
# frozen_string_literal: true

# Example 53: Batch + Named Context
# Test batching with named contexts

require_relative '../lib/minigun'

# Demonstrates batching combined with named contexts
class BatchWithNamedExample
  include Minigun::DSL

  attr_reader :results, :batches_processed

  def initialize
    @results = []
    @batches_processed = 0
    @mutex = Mutex.new
  end

  pipeline do
    execution_context :processor_pool, :threads, 3

    producer :gen do |output|
      30.times { |i| output << i }
    end

    processor :prep, execution_context: :processor_pool do |item, output|
      output << (item + 1)
    end

    batch 5

    processor :process_batch do |batch, output|
      @mutex.synchronize { @batches_processed += 1 }
      batch.each { |item| output << (item * 2) }
    end

    consumer :save do |item|
      @mutex.synchronize { @results << item }
    end
  end
end

puts 'Testing: batch + named context'
pipeline = BatchWithNamedExample.new
pipeline.run
puts "Results: #{pipeline.results.size} items"
puts '✓ Batch + named works' if pipeline.results.size == 30
