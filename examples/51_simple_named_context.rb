#!/usr/bin/env ruby
# frozen_string_literal: true

# Example 51: Simple Named Context Test
# Isolate the named context feature

require_relative '../lib/minigun'

# Demonstrates basic named context usage
class SimpleNamedContextExample
  include Minigun::DSL

  attr_reader :results

  def initialize
    @results = []
    @mutex = Mutex.new
  end

  pipeline do
    execution_context :my_pool, :threads, 5

    producer :gen do |output|
      10.times { |i| output << i }
    end

    processor :work, execution_context: :my_pool do |item, output|
      output << (item * 2)
    end

    consumer :save do |item|
      @mutex.synchronize { @results << item }
    end
  end
end

puts 'Testing: named context only'
pipeline = SimpleNamedContextExample.new
pipeline.run
puts "Results: #{pipeline.results.size} items"
puts '✓ Named context works' if pipeline.results.size == 10
