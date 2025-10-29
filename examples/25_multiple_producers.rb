#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Demonstrates multiple producers in a single pipeline
# Use case: Multiple data sources feeding into a shared processing pipeline
class MultipleProducersExample
  include Minigun::DSL

  attr_accessor :results

  def initialize
    @results = []
    @mutex = Mutex.new
  end

  pipeline do
    # Producer 1: Fetch from API
    producer :api_source do |output|
      puts '[API Source] Fetching from REST API...'
      10.times do |i|
        output << { source: 'api', id: i, data: "API record #{i}" }
      end
      puts '[API Source] Fetched 10 records'
    end

    # Producer 2: Read from database
    producer :db_source do |output|
      puts '[DB Source] Querying database...'
      5.times do |i|
        output << { source: 'database', id: i + 100, data: "DB record #{i}" }
      end
      puts '[DB Source] Queried 5 records'
    end

    # Producer 3: Read from file
    producer :file_source do |output|
      puts '[File Source] Reading from file...'
      3.times do |i|
        output << { source: 'file', id: i + 200, data: "File record #{i}" }
      end
      puts '[File Source] Read 3 records'
    end

    # Shared processor - enriches all records
    processor :enrich do |record, output|
      enriched = record.merge(
        timestamp: Time.now.to_i,
        processed: true
      )
      output << enriched
    end

    # Single consumer collects all records
    consumer :collect do |record|
      @mutex.synchronize do
        @results << record
        puts "[Collect] Stored: #{record[:source]} - #{record[:data]}"
      end
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  puts '=== Multiple Producers Example ==='
  puts "Running pipeline with 3 concurrent producers...\n\n"

  example = MultipleProducersExample.new
  example.run

  puts "\n#{'=' * 60}"
  puts 'RESULTS'
  puts '=' * 60

  puts "\nTotal records processed: #{example.results.size}"

  # Group by source
  by_source = example.results.group_by { |r| r[:source] }
  by_source.each do |source, records|
    puts "  #{source}: #{records.size} records"
  end

  # Show sample records
  puts "\nSample records:"
  example.results.first(5).each do |record|
    puts "  #{record[:source].ljust(10)} | ID: #{record[:id].to_s.ljust(3)} | #{record[:data]}"
  end

  # Get statistics
  task = example.class._minigun_task
  pipeline = task.root_pipeline
  stats = pipeline.stats

  puts "\n📊 Producer Statistics:"
  %i[api_source db_source file_source].each do |producer_name|
    producer_stats = stats.stage_stats[producer_name]
    puts "  #{producer_name}: #{producer_stats.items_produced} items (#{producer_stats.throughput.round(0)} items/s)" if producer_stats
  end

  puts "\n✓ Multiple producers example complete!"
  puts "All #{example.results.size} records from 3 different sources processed successfully"
end
