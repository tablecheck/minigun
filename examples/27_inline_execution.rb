#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Demonstrates inline (synchronous) execution
class InlineExample
  include Minigun::DSL

  attr_reader :results

  def initialize
    @results = []
  end

  pipeline do
    producer :generate do |output|
      5.times { |i| output << i }
    end

    # No execution context specified = inline (synchronous)
    processor :process do |item, output|
      output << (item * 2)
    end

    consumer :collect do |item|
      @results << item
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  example = InlineExample.new
  example.run
  puts "Processed #{example.results.size} items synchronously"
  puts "Results: #{example.results.inspect}"
end

