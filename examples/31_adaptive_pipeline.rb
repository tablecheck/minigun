#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Demonstrates dynamic configuration based on runtime conditions
class AdaptivePipeline
  include Minigun::DSL

  attr_accessor :concurrency_level

  def initialize(concurrency: :medium)
    @concurrency_level = concurrency
  end

  def thread_count
    case @concurrency_level
    when :low then 10
    when :high then 200
    else 50 # medium
    end
  end

  def process_count
    case @concurrency_level
    when :low then 2
    when :high then 16
    else 4 # medium
    end
  end

  def batch_size
    case @concurrency_level
    when :low then 100
    when :high then 10_000
    else 1000 # medium
    end
  end

  pipeline do
    producer :gen do |output|
      1000.times { |i| output << i }
    end

    threads(thread_count) do
      processor :fetch do |item, output|
        output << { id: item, data: 'fetched' }
      end
    end

    batch batch_size

    process_per_batch(max: process_count) do
      processor :process do |batch, _output|
        batch.map { |x| x[:data].upcase }
      end
    end

    consumer :store do |results|
      # Store
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  %i[low medium high].each do |level|
    pipeline = AdaptivePipeline.new(concurrency: level)
    puts "\nConcurrency level: #{level}"
    puts "  Threads: #{pipeline.thread_count}"
    puts "  Processes: #{pipeline.process_count}"
    puts "  Batch size: #{pipeline.batch_size}"
  end
end

