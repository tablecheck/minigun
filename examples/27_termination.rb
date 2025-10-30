#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Demonstrates proper termination and cleanup of execution contexts
class TerminationExample
  include Minigun::DSL

  attr_reader :count

  def initialize
    @count = 0
    @mutex = Mutex.new
  end

  pipeline do
    producer :generate do |output|
      10.times { |i| output << i }
    end

    threads(3) do
      processor :process do |item, output|
        output << item
      end
    end

    consumer :collect do |_item|
      @mutex.synchronize { @count += 1 }
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  example = TerminationExample.new
  example.run
  puts "Processed #{example.count} items"
end

