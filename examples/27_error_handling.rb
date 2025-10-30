#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Demonstrates error handling in different execution contexts
class ErrorExample
  include Minigun::DSL

  attr_reader :errors, :results

  def initialize
    @errors = []
    @results = []
    @mutex = Mutex.new
  end

  pipeline do
    producer :generate do |output|
      5.times { |i| output << i }
    end

    threads(2) do
      processor :process do |item, output|
        raise StandardError, "Error on item #{item}" if item == 2

        output << (item * 2)
      end
    end

    consumer :collect do |item|
      @mutex.synchronize { @results << item }
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  example = ErrorExample.new
  example.run
  puts "Processed #{example.results.size} successful items"
  puts "Results: #{example.results.sort.inspect}"
end

