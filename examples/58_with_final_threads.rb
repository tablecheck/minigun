#!/usr/bin/env ruby
# frozen_string_literal: true

# Example 58: Add final threads block
# Test if threads block after process_per_batch causes issues

require_relative '../lib/minigun'

# Demonstrates threads block after process-per-batch
class WithFinalThreadsExample
  include Minigun::DSL

  attr_reader :results

  def initialize
    @results = []
    @mutex = Mutex.new
  end

  pipeline do
    producer :gen do |output|
      20.times { |i| output << i }
    end

    threads(3) do
      processor :work do |item, output|
        output << (item * 2)
      end
    end

    batch 5

    process_per_batch(max: 2) do
      processor :process_batch do |batch, output|
        batch.each { |item| output << (item + 100) }
      end
    end

    threads(2) do
      consumer :save do |item|
        @mutex.synchronize { @results << item }
      end
    end
  end
end

puts 'Testing: threads + batch + process_per_batch + threads(consumer)'
pipeline = WithFinalThreadsExample.new
pipeline.run
puts "Results: #{pipeline.results.size} items"
puts pipeline.results.size == 20 ? '✓ Works!' : '✗ Failed'
