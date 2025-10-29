#!/usr/bin/env ruby
# frozen_string_literal: true

# Example 61: Scale test - same structure, different scale
# Test if scale causes the deadlock

require_relative '../lib/minigun'

# Demonstrates scalability testing with configurable parameters
class ScaleTestExample
  include Minigun::DSL

  attr_reader :stats, :results

  def initialize(items: 50, batch_size: 10, threads: 10)
    @items = items
    @batch_size = batch_size
    @threads = threads

    @stats = {
      downloaded: 0,
      parsed: 0,
      uploaded: 0
    }
    @results = []
    @mutex = Mutex.new
  end

  pipeline do
    execution_context :cache_pool, :threads, 5
    execution_context :db_pool, :threads, 3

    producer :generate do |output|
      @items.times { |i| output << { id: i, url: "item-#{i}" } }
    end

    processor :check_cache, execution_context: :cache_pool do |item, output|
      item[:cached] = false
      output << item
    end

    threads(@threads) do
      processor :download do |item, output|
        @mutex.synchronize { @stats[:downloaded] += 1 }
        item[:data] = "data-#{item[:id]}"
        output << item
      end

      processor :extract do |item, output|
        item[:metadata] = { size: 100 }
        output << item
      end
    end

    batch @batch_size

    process_per_batch(max: 2) do
      processor :parse_batch do |batch, output|
        @mutex.synchronize { @stats[:parsed] += batch.size }
        batch.each do |item|
          output << { id: item[:id], parsed: item[:data].upcase }
        end
      end
    end

    processor :save_db, execution_context: :db_pool do |item, output|
      output << item
    end

    threads(2) do
      consumer :upload do |item|
        @mutex.synchronize do
          @stats[:uploaded] += 1
          @results << item
        end
      end
    end
  end
end

puts 'Testing: scale with 200 items (like example 38)'
pipeline = ScaleTestExample.new(items: 200, batch_size: 100, threads: 50)
pipeline.run

puts "\nResults:"
puts "  Downloaded: #{pipeline.stats[:downloaded]}"
puts "  Parsed: #{pipeline.stats[:parsed]}"
puts "  Uploaded: #{pipeline.stats[:uploaded]}"

success = pipeline.stats[:uploaded] == 200
puts success ? '✓ Large scale works!' : '✗ Failed'
