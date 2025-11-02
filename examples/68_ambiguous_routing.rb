#!/usr/bin/env ruby
# frozen_string_literal: true

# Example: Ambiguous Routing Detection
#
# Demonstrates how the StageRegistry detects ambiguous stage name references
# when multiple stages with the same name exist at the same lookup level.
#
# The 3-level lookup strategy:
# 1. Local (same pipeline) - highest priority
# 2. Children (nested pipelines)
# 3. Global (all pipelines)
#
# Ambiguity errors occur when:
# - Multiple nested pipelines have same stage name (level 2)
# - Multiple pipelines globally have same stage name with no local match (level 3)

require_relative '../lib/minigun'

# Example 1: Direct demonstration of ambiguous lookup in children
class AmbiguousChildrenDemo
  include Minigun::DSL

  pipeline do
    # First nested pipeline with :processor
    pipeline :pipe1 do
      consumer :processor do |item|
        puts "[Pipe1] Processing: #{item}"
      end
    end

    # Second nested pipeline with :processor
    pipeline :pipe2 do
      consumer :processor do |item|
        puts "[Pipe2] Processing: #{item}"
      end
    end
  end

  def demonstrate_ambiguity
    # Trigger pipeline evaluation
    _evaluate_pipeline_blocks!

    task = _minigun_task
    root_pipeline = task.root_pipeline
    stage_registry = task.stage_registry

    puts "Attempting to look up :processor from root pipeline..."
    puts "Multiple nested pipelines contain :processor"

    begin
      # This should raise AmbiguousRoutingError
      stage_registry.find_by_name(:processor, from_pipeline: root_pipeline)
      puts "\n✗ FAILED: Expected AmbiguousRoutingError"
      nil
    rescue Minigun::AmbiguousRoutingError => e
      puts "\n✓ Caught expected error: #{e.class}"
      puts "  Message: #{e.message}"
      e
    end
  end
end

# Example 2: WORKS - Unique names avoid ambiguity
class UniqueNamesDemo
  include Minigun::DSL

  pipeline do
    # First nested pipeline with uniquely named stage
    pipeline :pipe1 do
      producer :gen1 do |output|
        output << 1
      end

      consumer :processor_a do |item|
        puts "[Pipe1] processor_a: #{item}"
      end
    end

    # Second nested pipeline with uniquely named stage (no conflict!)
    pipeline :pipe2 do
      producer :gen2 do |output|
        output << 2
      end

      consumer :processor_b do |item|
        puts "[Pipe2] processor_b: #{item}"
      end
    end
  end

  def demonstrate_unique_names
    _evaluate_pipeline_blocks!

    task = _minigun_task
    root_pipeline = task.root_pipeline
    stage_registry = task.stage_registry

    puts "Looking up stages with unique names:"

    # These lookups succeed because names are unique
    proc_a = stage_registry.find_by_name(:processor_a, from_pipeline: root_pipeline)
    proc_b = stage_registry.find_by_name(:processor_b, from_pipeline: root_pipeline)

    puts "  ✓ Found :processor_a - #{proc_a.inspect}"
    puts "  ✓ Found :processor_b - #{proc_b.inspect}"
    puts "  No ambiguity when names are unique!"

    [proc_a, proc_b]
  end
end

# Example 3: WORKS - Local names take priority, avoiding ambiguity
class LocalPriorityExample
  include Minigun::DSL

  attr_reader :results

  def initialize
    @results = []
  end

  pipeline do
    producer :gen do |output|
      output << 1
    end

    # Local :processor takes priority over any nested ones
    consumer :processor do |item|
      @results << "local:#{item}"
      puts "[Local Processor] #{item}"
    end

    # Nested pipeline also has :processor, but local takes priority
    pipeline :nested do
      consumer :processor do |item|
        puts "[Nested Processor] #{item} (won't be reached)"
      end
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  puts "=" * 70
  puts "Example: Ambiguous Routing Detection"
  puts "=" * 70

  puts "\n--- Scenario 1: Ambiguous lookup in children ---"
  example1 = AmbiguousChildrenDemo.new
  error = example1.demonstrate_ambiguity

  if error
    puts "\n✓ SUCCESS: AmbiguousRoutingError was properly detected"
    puts "  The stage_registry prevents lookups with multiple matches"
  else
    puts "\n✗ FAILED: Expected AmbiguousRoutingError"
  end

  puts "\n" + "=" * 70
  puts "--- Scenario 2: Unique names (works correctly) ---"
  example2 = UniqueNamesDemo.new
  stages = example2.demonstrate_unique_names

  puts "\n✓ SUCCESS: Registry found #{stages.size} stages with unique names"

  puts "\n" + "=" * 70
  puts "--- Scenario 3: Local priority (works correctly) ---"
  example3 = LocalPriorityExample.new
  example3.run

  puts "\nResults: #{example3.results.inspect}"
  puts "✓ SUCCESS: Local stage takes priority over nested stages"
  puts "=" * 70
end

