#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Custom producer stage using yield syntax
class NumberGenerator < Minigun::ProducerStage
  def call(_output)
    10.times do |i|
      yield i # Use native Ruby yield!
    end
  end
end

# Custom processor stage using yield with routing
class ParityRouter < Minigun::ConsumerStage
  def call(number, _output)
    if number.even?
      yield(number, to: :process_even)
    else
      yield(number, to: :process_odd)
    end
  end
end

# Custom processor for even numbers
class EvenProcessor < Minigun::ConsumerStage
  def call(number, _output)
    yield(number * 2) # Double even numbers
  end
end

# Custom processor for odd numbers
class OddProcessor < Minigun::ConsumerStage
  def call(number, _output)
    yield(number * 3) # Triple odd numbers
  end
end

# Yield Syntax with Classes Example
class YieldWithClassesExample
  include Minigun::DSL

  attr_accessor :even_results, :odd_results

  def initialize
    @even_results = []
    @odd_results = []
    @mutex = Mutex.new
  end

  pipeline do
    # Use custom stage class instead of block
    custom_stage(NumberGenerator, :generate)

    # Use custom routing stage
    custom_stage(ParityRouter, :route_by_parity, from: :generate)

    # Use custom processor stages
    custom_stage(EvenProcessor, :process_even)
    custom_stage(OddProcessor, :process_odd)

    # Collect even results (still using block syntax - both work!)
    consumer :collect_even, from: :process_even do |item|
      @mutex.synchronize { even_results << item }
    end

    # Collect odd results
    consumer :collect_odd, from: :process_odd do |item|
      @mutex.synchronize { odd_results << item }
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  puts "=== Yield Syntax with Classes Example ===\n\n"
  puts 'Demonstrates using yield in custom stage classes:'
  puts '  • Define stage as class inheriting from ProducerStage/ConsumerStage'
  puts '  • Implement #call method'
  puts '  • Use native Ruby yield syntax'
  puts '  • yield(item) - emit to all downstream stages'
  puts "  • yield(item, to: :stage_name) - emit to specific stage\n\n"

  example = YieldWithClassesExample.new
  example.run

  puts "\n=== Results ===\n"
  puts 'Input: 0, 1, 2, 3, 4, 5, 6, 7, 8, 9'
  puts "Even numbers (doubled): #{example.even_results.sort.join(', ')}"
  puts "Odd numbers (tripled): #{example.odd_results.sort.join(', ')}"

  expected_even = [0, 4, 8, 12, 16]
  expected_odd = [3, 9, 15, 21, 27]

  puts "\nEven results correct: #{example.even_results.sort == expected_even ? '✓' : '✗'}"
  puts "Odd results correct: #{example.odd_results.sort == expected_odd ? '✓' : '✗'}"
  puts "\n✓ Yield syntax with classes example complete!"
  puts "\nNote: You can mix class-based stages (with yield) and block-based stages!"
end
