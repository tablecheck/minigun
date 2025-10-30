#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Demonstrates bulk operations with thread pools
class BulkExample
  include Minigun::DSL

  attr_reader :results

  def initialize
    @results = []
    @mutex = Mutex.new
  end

  pipeline do
    producer :generate do |output|
      100.times { |i| output << i }
    end

    threads(20) do
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
  start = Time.now
  example = BulkExample.new
  example.run
  elapsed = Time.now - start

  puts "Processed #{example.results.size} items in #{elapsed.round(3)}s"
  puts "Throughput: #{(example.results.size / elapsed).round(0)} items/sec"
end

