#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Demonstrates proper pool termination and cleanup
class TerminationPoolExample
  include Minigun::DSL

  attr_reader :completed

  def initialize
    @completed = 0
    @mutex = Mutex.new
  end

  pipeline do
    producer :generate do |output|
      5.times { |i| output << i }
    end

    threads(5) do
      processor :process do |item, output|
        sleep 0.01 # Simulate work
        output << item
      end
    end

    consumer :collect do |_item|
      @mutex.synchronize { @completed += 1 }
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  example = TerminationPoolExample.new
  example.run
  puts "Completed #{example.completed} tasks"
end

