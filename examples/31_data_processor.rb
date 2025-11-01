#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Demonstrates configurable process-per-batch with dynamic batch sizes
class DataProcessor
  include Minigun::DSL

  attr_reader :processed_count, :thread_count, :process_count, :batch_size

  def initialize(threads: 50, processes: 4, batch_size: 1000)
    @thread_count = threads
    @process_count = processes
    @batch_size = batch_size
    @processed_count = 0
    @mutex = Mutex.new
  end

  pipeline do
    producer :generate do |output|
      5000.times { |i| output << i }
    end

    # Parallel download with thread pool
    threads(@thread_count) do
      processor :download do |item, output|
        # Simulate I/O-bound work
        output << { id: item, data: "data-#{item}" }
      end
    end

    # Batch for efficient processing
    batch @batch_size

    # CPU-intensive processing per batch with process isolation
    process_per_batch(max: @process_count) do
      processor :parse do |batch, output|
        # Simulate CPU-intensive work
        batch.map { |item| item[:data].upcase }.each { |result| output << result }
      end
    end

    consumer :save do |results|
      @mutex.synchronize do
        @processed_count += results.size
      end
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  processor = DataProcessor.new(threads: 100, processes: 8, batch_size: 500)
  puts "Processor configuration:"
  puts "  Threads for I/O: #{processor.thread_count}"
  puts "  Max processes: #{processor.process_count}"
  puts "  Batch size: #{processor.batch_size}"
end

