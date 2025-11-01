#!/usr/bin/env ruby
# frozen_string_literal: true

# Example 55: Full Combination Test
# All features together like example 38 but smaller scale

require_relative '../lib/minigun'

# Demonstrates all execution features combined
class FullComboExample
  include Minigun::DSL

  attr_reader :stats

  def initialize(threads: 10, processes: 2, batch_size: 10)
    @threads = threads
    @processes = processes
    @batch_size = batch_size

    @stats = {
      downloaded: 0,
      parsed: 0,
      uploaded: 0
    }
    @mutex = Mutex.new
  end

  pipeline do
    execution_context :cache_pool, :threads, 5
    execution_context :db_pool, :threads, 3

    producer :generate do |output|
      50.times { |i| output << { id: i, url: "item-#{i}" } }
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

    process_per_batch(max: @processes) do
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

    threads(5) do
      consumer :upload do |_item|
        @mutex.synchronize { @stats[:uploaded] += 1 }
      end
    end
  end
end

puts 'Testing: full combination (mini example 38)'
pipeline = FullComboExample.new
pipeline.run

puts "\nResults:"
puts "  Downloaded: #{pipeline.stats[:downloaded]}"
puts "  Parsed: #{pipeline.stats[:parsed]}"
puts "  Uploaded: #{pipeline.stats[:uploaded]}"

success = pipeline.stats[:downloaded] == 50 &&
          pipeline.stats[:parsed] == 50 &&
          pipeline.stats[:uploaded] == 50

puts success ? '✓ Full combo works!' : '✗ Full combo failed'
