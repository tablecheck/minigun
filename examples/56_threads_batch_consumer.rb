#!/usr/bin/env ruby
# frozen_string_literal: true

# Example 56: Threads + Batch + Consumer
# Simplest case to reproduce the issue

require_relative '../lib/minigun'

# Demonstrates threads with batching and consumer stages
class ThreadsBatchConsumerExample
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

    consumer :save do |batch|
      @mutex.synchronize { @results << batch.size }
    end
  end
end

puts 'Testing: threads block + batch + consumer'
pipeline = ThreadsBatchConsumerExample.new
pipeline.run
puts "Results: #{pipeline.results.size} batches, total items: #{pipeline.results.sum}"
puts pipeline.results.sum == 20 ? '✓ Works!' : '✗ Failed'
