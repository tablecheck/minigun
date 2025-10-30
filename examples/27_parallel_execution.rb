#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Demonstrates parallel processing of multiple items
class ParallelExample
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

    threads(5) do
      processor :process do |item, output|
        sleep 0.01 # Simulate work
        output << (item * 3)
      end
    end

    consumer :collect do |item|
      @mutex.synchronize { @results << item }
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  start = Time.now
  example = ParallelExample.new
  example.run
  elapsed = Time.now - start

  puts "Processed #{example.results.size} items in #{elapsed.round(2)}s"
  puts "Results: #{example.results.sort.inspect}"
end

