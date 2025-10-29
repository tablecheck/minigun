# frozen_string_literal: true

# Example: Broadcast Fan-Out
#
# Demonstrates automatic broadcast distribution when a producer fans out to multiple processing branches.
# This is useful for ETL pipelines where the same data needs different transformations.

require_relative '../lib/minigun'

# Demonstrates broadcast fan-out to multiple downstream stages
class BroadcastFanOutExample
  include Minigun::DSL

  attr_accessor :results

  def initialize
    @results = []
    @mutex = Mutex.new
  end

  pipeline do
    # Producer with explicit broadcast routing to multiple consumers
    # routing: :broadcast sends each item to ALL branches (default behavior)
    # This is useful for ETL where the same data needs multiple transformations
    producer :data_source, to: %i[validate transform analyze], routing: :broadcast do |output|
      puts "\n[Producer] Generating data..."
      3.times { |i| output << { id: i, value: i * 10 } }
    end

    # Branch 1: Validation
    # With routing: :broadcast, each item reaches ALL three consumers
    consumer :validate do |item|
      @mutex.synchronize do
        validated = item.merge(validated: true)
        @results << { branch: :validation, data: validated }
        puts "[Validate] Checked and stored: #{validated.inspect}"
      end
    end

    # Branch 2: Transformation
    consumer :transform do |item|
      @mutex.synchronize do
        transformed = item.merge(value: item[:value] * 2)
        @results << { branch: :transform, data: transformed }
        puts "[Transform] Doubled and stored: #{transformed.inspect}"
      end
    end

    # Branch 3: Analysis
    consumer :analyze do |item|
      @mutex.synchronize do
        analyzed = item.merge(category: item[:value] > 10 ? :high : :low)
        @results << { branch: :analysis, data: analyzed }
        puts "[Analyze] Categorized and stored: #{analyzed.inspect}"
      end
    end
  end
end

# Run the pipeline
pipeline = BroadcastFanOutExample.new
pipeline.run

# Display results
puts "\n#{'=' * 60}"
puts 'BROADCAST FAN-OUT RESULTS'
puts '=' * 60

puts "\nEach item was processed by ALL branches:"
pipeline.results.group_by { |r| r[:data][:id] }.sort.each do |id, branches|
  puts "\nItem #{id}:"
  branches.each do |branch_result|
    puts "  #{branch_result[:branch]}: #{branch_result[:data].inspect}"
  end
end

branch_counts = pipeline.results.group_by { |r| r[:branch] }.transform_values(&:count)
puts "\nItems per branch:"
branch_counts.each { |branch, count| puts "  #{branch}: #{count} items" }

puts "\nNote: Each item reaches ALL branches (broadcast), not just one."
puts 'This happens because routing: :broadcast was specified (also the default).'
