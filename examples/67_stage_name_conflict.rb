#!/usr/bin/env ruby
# frozen_string_literal: true

# Example: Stage Name Conflict Detection
#
# Demonstrates how the StageRegistry detects and prevents duplicate stage names
# within the same pipeline. This ensures stage names are unique at each level.
#
# Key points:
# - Stage names must be unique within a pipeline
# - Same name can be used in different pipelines (different scope)
# - Conflict raises StageNameConflict error at registration time

require_relative '../lib/minigun'

# Example 1: This will FAIL with StageNameConflict
class ConflictingPipeline
  include Minigun::DSL

  pipeline do
    producer :duplicated do |output|
      output << 1
    end

    # This will raise StageNameConflict!
    consumer :duplicated do |item|
      puts item
    end
  end
end

# Example 2: This WORKS - same names in different (nested) pipelines are scoped
class ScopedNamesExample
  include Minigun::DSL

  attr_reader :results

  def initialize
    @results = []
  end

  pipeline do
    # First nested pipeline with :process stage
    pipeline :pipe1 do
      producer :gen1 do |output|
        3.times { |i| output << i + 1 }
      end

      consumer :process do |item|
        puts "[Pipeline 1] Processing: #{item}"
        @results << "p1:#{item}"
      end
    end

    # Second nested pipeline with :process stage (different scope - OK!)
    pipeline :pipe2 do
      producer :gen2 do |output|
        3.times { |i| output << i + 10 }
      end

      consumer :process do |item|
        puts "[Pipeline 2] Processing: #{item}"
        @results << "p2:#{item}"
      end
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  puts "=" * 70
  puts "Example: Stage Name Conflict Detection"
  puts "=" * 70

  puts "\n--- Scenario 1: Duplicate names in SAME pipeline (will fail) ---"
  conflict_caught = false
  error_message = nil
  
  begin
    # Run triggers pipeline block evaluation and stage registration
    ConflictingPipeline.new.run
  rescue Minigun::StageNameConflict => e
    conflict_caught = true
    error_message = e.message
    puts "✓ Caught expected error: #{e.class}"
    puts "  Message: #{e.message}"
  end
  
  if conflict_caught
    puts "\n✓ SUCCESS: StageNameConflict was properly detected"
    puts "  This prevents ambiguous stage references within a pipeline"
  else
    puts "\n✗ FAILED: Expected StageNameConflict but didn't catch it"
  end

  puts "\n" + "=" * 70
  puts "--- Scenario 2: Same names in DIFFERENT pipelines (OK) ---"
  example = ScopedNamesExample.new
  example.run
  
  puts "\nResults: #{example.results.size} items processed"
  puts "✓ SUCCESS: Same stage names allowed in different pipeline scopes"
  puts "  Each nested pipeline has its own :process stage"
  puts "=" * 70
end

