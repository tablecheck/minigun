#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Demonstrates Ractor-based parallel execution
class RactorExample
  include Minigun::DSL

  attr_reader :results

  def initialize
    @results = []
    @mutex = Mutex.new
  end

  pipeline do
    producer :generate do |output|
      5.times { |i| output << i }
    end

    # Ractors provide true parallelism (falls back to threads if unavailable)
    ractors(2) do
      processor :process do |item, output|
        output << (item**2)
      end
    end

    consumer :collect do |item|
      @mutex.synchronize { @results << item }
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  example = RactorExample.new
  example.run
  puts "Processed #{example.results.size} items"
  puts "Results: #{example.results.sort.inspect}"
end

