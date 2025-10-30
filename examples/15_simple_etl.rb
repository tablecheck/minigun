#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Simple ETL (Extract-Transform-Load) Example
# Single pipeline ETL pattern (simpler than the multi-pipeline version)
class SimpleETLExample
  include Minigun::DSL

  attr_accessor :extracted, :transformed, :loaded

  def initialize
    @extracted = []
    @transformed = []
    @loaded = []
    @mutex = Mutex.new
  end

  pipeline do
    # Extract: Simulate extracting from database
    producer :extract do |output|
      puts '[Extract] Fetching records from database...'
      5.times do |i|
        record = { id: i, value: i * 10, raw: true }
        @mutex.synchronize { extracted << record }
        output << record
      end
      puts "[Extract] Extracted #{@extracted.size} records"
    end

    # Transform: Clean and enrich the data
    processor :transform do |record, output|
      puts "[Transform] Processing record #{record[:id]}"

      transformed_record = {
        id: record[:id],
        value: record[:value],
        raw: false,
        processed: true,
        timestamp: Time.now.strftime('%Y-%m-%dT%H:%M:%S%z')
      }

      @mutex.synchronize { transformed << transformed_record }
      output << transformed_record
    end

    # Load: Save to destination (database, file, API, etc.)
    consumer :load do |record|
      puts "[Load] Saving record #{record[:id]} to destination"
      # Simulate saving to destination
      sleep 0.01
      @mutex.synchronize { loaded << record }
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  puts "=== Simple ETL Example ===\n\n"
  puts 'ETL Pipeline Pattern:'
  puts "  Extract (from source) → Transform (clean/enrich) → Load (to destination)\n\n"

  example = SimpleETLExample.new
  example.run

  puts "\n=== Results ===\n"
  puts "Extracted: #{example.extracted.size} records"
  puts "Transformed: #{example.transformed.size} records"
  puts "Loaded: #{example.loaded.size} records"

  puts "\nSample extracted record:"
  puts "  #{example.extracted.first.inspect}"

  puts "\nSample transformed record:"
  puts "  #{example.transformed.first.inspect}"

  puts "\nAll records processed: #{example.loaded.all? { |r| r[:processed] } ? '✓' : '✗'}"

  puts "\n=== Use Cases ===\n"
  puts '• Database → Data Warehouse migrations'
  puts '• API data ingestion and transformation'
  puts '• File format conversions'
  puts '• Data cleaning and enrichment'
  puts "\nFor more complex ETL with fan-out, see 06_multi_pipeline_etl.rb"
  puts "\n✓ ETL complete!"
end
