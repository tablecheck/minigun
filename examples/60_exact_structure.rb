#!/usr/bin/env ruby
# frozen_string_literal: true

# Example 60: Exact structure of example 55
# Match example 55 structure exactly but with smaller data

require_relative '../lib/minigun'

# Demonstrates exact structure matching for testing
class ExactStructureExample
  include Minigun::DSL

  attr_reader :stats

  def initialize
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
      20.times { |i| output << { id: i, url: "item-#{i}" } }
    end

    processor :check_cache, execution_context: :cache_pool do |item, output|
      item[:cached] = false
      output << item
    end

    threads(5) do
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

    batch 5

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
      consumer :upload do |_item|
        @mutex.synchronize { @stats[:uploaded] += 1 }
      end
    end
  end
end

puts 'Testing: exact structure of example 55'
pipeline = ExactStructureExample.new
pipeline.run

puts "\nResults:"
puts "  Downloaded: #{pipeline.stats[:downloaded]}"
puts "  Parsed: #{pipeline.stats[:parsed]}"
puts "  Uploaded: #{pipeline.stats[:uploaded]}"

success = pipeline.stats[:downloaded] == 20 &&
          pipeline.stats[:parsed] == 20 &&
          pipeline.stats[:uploaded] == 20

puts success ? '✓ Exact structure works!' : '✗ Failed'
