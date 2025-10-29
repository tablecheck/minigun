#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Custom producer using yield syntax
class NumberGenerator < Minigun::ProducerStage
  def call
    10.times { |i| yield i }
  end
end

# Custom processor using yield syntax
class Doubler < Minigun::ConsumerStage
  def call(number)
    yield(number * 2)
  end
end

# Quick Start Example with Yield Syntax
# Demonstrates using native Ruby yield in custom stage classes
class QuickStartYieldExample
  include Minigun::DSL

  attr_accessor :results

  def initialize
    @results = []
    @mutex = Mutex.new
  end

  pipeline do
    # Step 1: Generate items using custom class with yield
    custom_stage(NumberGenerator, :generate)

    # Step 2: Transform items using custom class with yield
    custom_stage(Doubler, :transform)

    # Step 3: Collect results using block syntax
    consumer :collect do |item|
      @mutex.synchronize { results << item }
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  puts "=== Quick Start with Yield Example ===\n\n"
  puts 'This demonstrates the yield syntax with custom stage classes:'
  puts "  NumberGenerator (yield) → Doubler (yield) → Consumer (block)\n\n"

  example = QuickStartYieldExample.new
  example.run

  puts "\n=== Results ===\n"
  puts 'Input:  0, 1, 2, 3, 4, 5, 6, 7, 8, 9'
  puts "Output: #{example.results.sort.join(', ')}"
  puts "\nAll values doubled: #{example.results.sort == [0, 2, 4, 6, 8, 10, 12, 14, 16, 18] ? '✓' : '✗'}"
  puts "\n✓ Quick start with yield complete!"
  puts "\nKey takeaway:"
  puts '  • Custom stage classes with #call can use native Ruby yield'
  puts '  • Mix and match with block-based stages'
  puts '  • Same power, cleaner syntax!'
end
