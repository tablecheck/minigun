#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Single Task with two nested pipelines
# Pipeline A processes items and routes to Pipeline B
# Pipeline B has its own multiple producers + receives from Pipeline A
class MultiPipelineWithProducersExample
  include Minigun::DSL

  attr_accessor :results

  def initialize
    @results = []
    @mutex = Mutex.new
  end

  # Pipeline A: Processes some data and forwards to Pipeline B
  pipeline :pipeline_a, to: :pipeline_b do
    producer :source_x do |output|
      puts '[Pipeline A] Producer X: generating items...'
      3.times do |i|
        output << { id: i, source: 'x', value: i * 10 }
      end
      puts '[Pipeline A] Producer X: done (3 items)'
    end

    processor :process_x do |item, output|
      puts "[Pipeline A] Processing: #{item[:id]} from #{item[:source]}"
      item[:processed_by_a] = true
      output << item
    end
  end

  # Pipeline B: Has its own producers AND receives from Pipeline A
  pipeline :pipeline_b do
    # Producer 1 in Pipeline B
    producer :source_y do |output|
      puts '[Pipeline B] Producer Y: generating items...'
      2.times do |i|
        output << { id: i + 100, source: 'y', value: i * 20 }
      end
      puts '[Pipeline B] Producer Y: done (2 items)'
    end

    # Producer 2 in Pipeline B
    producer :source_z do |output|
      puts '[Pipeline B] Producer Z: generating items...'
      2.times do |i|
        output << { id: i + 200, source: 'z', value: i * 30 }
      end
      puts '[Pipeline B] Producer Z: done (2 items)'
    end

    # Consumer receives items from:
    # 1. Pipeline A's processor (via pipeline routing)
    # 2. Pipeline B's producer Y
    # 3. Pipeline B's producer Z
    consumer :collect_all do |item|
      @mutex.synchronize do
        @results << item
        processed_marker = item[:processed_by_a] ? ' (from Pipeline A)' : ''
        puts "[Pipeline B] Collected: #{item[:id]} from source '#{item[:source]}'#{processed_marker}"
      end
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  puts '=== Multi-Pipeline with Multiple Producers Example ==='
  puts "Pipeline A (processor) → Pipeline B (2 producers + consumer)\n\n"

  task = MultiPipelineTask.new

  puts '=' * 60
  puts 'RUNNING TASK'
  puts '=' * 60
  puts ''

  task.run

  puts "\n#{'=' * 60}"
  puts 'RESULTS'
  puts '=' * 60

  puts "\nTotal items collected: #{task.results.size}"
  puts 'Expected: 7 items (3 from A, 2 from Y, 2 from Z)'

  # Group by source
  by_source = task.results.group_by { |r| r[:source] }
  puts "\nItems by source:"
  by_source.each do |source, items|
    from_pipeline_a = items.any? { |i| i[:processed_by_a] }
    marker = from_pipeline_a ? ' (via Pipeline A)' : ' (native to Pipeline B)'
    puts "  #{source}: #{items.size} items#{marker}"
  end

  # Show all items
  puts "\nAll collected items:"
  task.results.sort_by { |r| r[:id] }.each do |item|
    processed = item[:processed_by_a] ? '✓ Processed by A' : '  Native to B'
    puts "  ID: #{item[:id]}, Source: #{item[:source]}, Value: #{item[:value]} | #{processed}"
  end

  # Verify routing
  items_from_a = task.results.select { |r| r[:processed_by_a] }
  items_from_y = task.results.select { |r| r[:source] == 'y' }
  items_from_z = task.results.select { |r| r[:source] == 'z' }

  puts "\n✓ Routing verification:"
  puts "  Items from Pipeline A (via process_x): #{items_from_a.size} (expected 3)"
  puts "  Items from Producer Y: #{items_from_y.size} (expected 2)"
  puts "  Items from Producer Z: #{items_from_z.size} (expected 2)"
  puts "  Total: #{task.results.size} (expected 7)"

  if task.results.size == 7 &&
     items_from_a.size == 3 &&
     items_from_y.size == 2 &&
     items_from_z.size == 2
    puts "\n✅ SUCCESS: All items routed correctly!"
    puts "\nKey points demonstrated:"
    puts "  ✓ Pipeline A's processor routes to Pipeline B"
    puts '  ✓ Pipeline B has 2 internal producers (Y and Z)'
    puts "  ✓ All 3 sources (A's processor + B's 2 producers) route to B's consumer"
    puts '  ✓ Multiple producers in nested pipelines work correctly'
  else
    puts "\n❌ FAILED: Item counts don't match expected values"
  end
end
