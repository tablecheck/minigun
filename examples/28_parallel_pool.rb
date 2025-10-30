#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Demonstrates parallel processing with a thread pool
class ParallelPoolExample
  include Minigun::DSL

  attr_reader :results

  def initialize
    @results = []
    @mutex = Mutex.new
  end

  pipeline do
    producer :generate do |output|
      50.times { |i| output << i }
    end

    threads(10) do
      processor :process do |item, output|
        output << (item * 2)
      end
    end

    consumer :collect do |item|
      @mutex.synchronize { @results << item }
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  example = ParallelPoolExample.new
  example.run
  puts "Processed #{example.results.size} items with 10-worker pool"
end

