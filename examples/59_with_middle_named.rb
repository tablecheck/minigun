#!/usr/bin/env ruby
# frozen_string_literal: true

# Example 59: Add named context processor in the middle
# This matches the structure of example 55 more closely

require_relative '../lib/minigun'

# Demonstrates named context in the middle of processing pipeline
class WithMiddleNamedExample
  include Minigun::DSL

  attr_reader :results

  def initialize
    @results = []
    @mutex = Mutex.new
  end

  pipeline do
    execution_context :db_pool, :threads, 3

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

    processor :save_db, execution_context: :db_pool do |item, output|
      output << item
    end

    threads(2) do
      consumer :upload do |item|
        @mutex.synchronize { @results << item }
      end
    end
  end
end

puts 'Testing: threads + batch + process_per_batch + named + threads(consumer)'
pipeline = WithMiddleNamedExample.new
pipeline.run
puts "Results: #{pipeline.results.size} items"
puts pipeline.results.size == 20 ? '✓ Works!' : '✗ Failed'
