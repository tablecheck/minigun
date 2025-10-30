#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Demonstrates basic thread pool usage
class BasicPoolExample
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

    # Thread pool with 3 workers
    threads(3) do
      processor :process do |item, output|
        sleep 0.05
        output << (item * 2)
      end
    end

    consumer :collect do |item|
      @mutex.synchronize { @results << item }
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  example = BasicPoolExample.new
  example.run
  puts "Processed #{example.results.size} items with 3-worker pool"
  puts "Results: #{example.results.sort.first(5).inspect}..."
end

