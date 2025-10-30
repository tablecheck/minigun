#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Demonstrates thread context reuse in pools
class ReuseExample
  include Minigun::DSL

  attr_reader :thread_ids

  def initialize
    @thread_ids = []
    @mutex = Mutex.new
  end

  pipeline do
    producer :generate do |output|
      20.times { |i| output << i }
    end

    threads(3) do
      processor :track do |item, output|
        @mutex.synchronize { @thread_ids << Thread.current.object_id }
        output << item
      end
    end

    consumer :collect do |item|
      # Just consume
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  example = ReuseExample.new
  example.run
  unique_threads = example.thread_ids.uniq.size
  puts "Executed 20 tasks using #{unique_threads} unique threads"
end

