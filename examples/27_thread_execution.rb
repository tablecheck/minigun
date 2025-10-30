#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Demonstrates thread-based execution with each stage in its own thread
class ThreadExample
  include Minigun::DSL

  attr_reader :results

  def initialize
    @results = []
    @mutex = Mutex.new
  end

  pipeline do
    producer :generate do |output|
      10.times { |i| output << i }
    end

    # Use thread pool for concurrent processing
    threads(5) do
      processor :process do |item, output|
        sleep 0.01 # Simulate work
        output << (item * 2)
      end
    end

    consumer :collect do |item|
      @mutex.synchronize { @results << item }
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  example = ThreadExample.new
  example.run
  puts "Processed #{example.results.size} items concurrently"
  puts "Results (first 5): #{example.results.sort.first(5).inspect}"
end

