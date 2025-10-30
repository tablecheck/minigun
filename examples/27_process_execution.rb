#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Demonstrates process-based execution with isolation
class ProcessExample
  include Minigun::DSL

  attr_reader :results

  def initialize
    @results = []
    @mutex = Mutex.new
  end

  pipeline do
    producer :generate do |output|
      3.times { |i| output << i }
    end

    # Process isolation for CPU-bound tasks
    batch 1
    process_per_batch(max: 2) do
      processor :process do |batch, output|
        batch.each do |item|
          output << { item: item, pid: Process.pid, result: item * 100 }
        end
      end
    end

    consumer :collect do |data|
      @mutex.synchronize { @results << data }
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  if Process.respond_to?(:fork)
    example = ProcessExample.new
    example.run
    puts "Processed #{example.results.size} items"
    pids = example.results.map { |r| r[:pid] }.uniq
    puts "Used #{pids.size} different processes"
  else
    puts "Process isolation (skipped - fork not available)"
  end
end

