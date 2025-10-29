#!/usr/bin/env ruby
# frozen_string_literal: true

# Example 52: Threads Block + Named Context
# Test combination of thread blocks and named contexts

require_relative '../lib/minigun'

# Demonstrates combining thread blocks with named contexts
class ThreadsPlusNamedExample
  include Minigun::DSL

  attr_reader :results

  def initialize
    @results = []
    @mutex = Mutex.new
  end

  pipeline do
    execution_context :named_pool, :threads, 3

    producer :gen do |output|
      20.times { |i| output << i }
    end

    threads(5) do
      processor :work1 do |item, output|
        output << (item + 10)
      end
    end

    processor :work2, execution_context: :named_pool do |item, output|
      output << (item * 2)
    end

    consumer :save do |item|
      @mutex.synchronize { @results << item }
    end
  end
end

puts 'Testing: threads block + named context'
pipeline = ThreadsPlusNamedExample.new
pipeline.run
puts "Results: #{pipeline.results.size} items"
puts '✓ Threads + named works' if pipeline.results.size == 20
