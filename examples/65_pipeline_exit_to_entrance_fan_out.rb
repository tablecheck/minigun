#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Example demonstrating multiple pipeline exits fanning out to multiple pipeline entrances
# Shows how 2 parent pipelines can route their outputs to 3 child pipelines
class PipelineExitToEntranceFanOutExample
  include Minigun::DSL

  attr_accessor :results_x, :results_y, :results_z

  def initialize
    @results_x = []
    @results_y = []
    @results_z = []
    @mutex = Mutex.new
  end

  # First parent pipeline - generates even numbers
  pipeline :source_a, to: %i[processor_x processor_y processor_z] do
    producer :generate_evens do |output|
      puts '[Source A] Generating even numbers...'
      [2, 4, 6].each do |num|
        puts "[Source A] Produced: #{num}"
        output << { value: num, source: :a }
      end
    end
  end

  # Second parent pipeline - generates odd numbers
  pipeline :source_b, to: %i[processor_x processor_y processor_z] do
    producer :generate_odds do |output|
      puts '[Source B] Generating odd numbers...'
      [1, 3, 5].each do |num|
        puts "[Source B] Produced: #{num}"
        output << { value: num, source: :b }
      end
    end
  end

  # First child pipeline - adds 10
  pipeline :processor_x do
    processor :add_ten do |item, output|
      result = item[:value] + 10
      puts "[Processor X] #{item[:value]} + 10 = #{result} (from #{item[:source]})"
      output << { value: result, source: item[:source], processor: :x }
    end

    consumer :collect_x do |item|
      puts "[Processor X] Collecting: #{item.inspect}"
      @mutex.synchronize { @results_x << item }
    end
  end

  # Second child pipeline - multiplies by 2
  pipeline :processor_y do
    processor :double do |item, output|
      result = item[:value] * 2
      puts "[Processor Y] #{item[:value]} * 2 = #{result} (from #{item[:source]})"
      output << { value: result, source: item[:source], processor: :y }
    end

    consumer :collect_y do |item|
      puts "[Processor Y] Collecting: #{item.inspect}"
      @mutex.synchronize { @results_y << item }
    end
  end

  # Third child pipeline - squares the number
  pipeline :processor_z do
    processor :square do |item, output|
      result = item[:value]**2
      puts "[Processor Z] #{item[:value]}^2 = #{result} (from #{item[:source]})"
      output << { value: result, source: item[:source], processor: :z }
    end

    consumer :collect_z do |item|
      puts "[Processor Z] Collecting: #{item.inspect}"
      @mutex.synchronize { @results_z << item }
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  puts "=== Pipeline Exit-to-Entrance Fan-Out Example ===\n\n"
  puts "Topology:"
  puts "  source_a (evens: 2,4,6) ──┐"
  puts "                            ├──> processor_x (add 10)"
  puts "                            ├──> processor_y (multiply 2)"
  puts "  source_b (odds: 1,3,5) ───┴──> processor_z (square)"
  puts "\nEach source pipeline's :_exit fans out to all 3 processor :_entrance nodes\n\n"

  example = PipelineExitToEntranceFanOutExample.new
  example.run

  puts "\n=== Results ==="
  puts "\nProcessor X (add 10):"
  puts "  From A: #{example.results_x.select { |r| r[:source] == :a }.map { |r| r[:value] }.sort.inspect}"
  puts "  From B: #{example.results_x.select { |r| r[:source] == :b }.map { |r| r[:value] }.sort.inspect}"
  puts "  Total: #{example.results_x.size} items"

  puts "\nProcessor Y (multiply 2):"
  puts "  From A: #{example.results_y.select { |r| r[:source] == :a }.map { |r| r[:value] }.sort.inspect}"
  puts "  From B: #{example.results_y.select { |r| r[:source] == :b }.map { |r| r[:value] }.sort.inspect}"
  puts "  Total: #{example.results_y.size} items"

  puts "\nProcessor Z (square):"
  puts "  From A: #{example.results_z.select { |r| r[:source] == :a }.map { |r| r[:value] }.sort.inspect}"
  puts "  From B: #{example.results_z.select { |r| r[:source] == :b }.map { |r| r[:value] }.sort.inspect}"
  puts "  Total: #{example.results_z.size} items"

  # Verify we got the right results
  expected_x_from_a = [12, 14, 16] # 2+10, 4+10, 6+10
  expected_x_from_b = [11, 13, 15] # 1+10, 3+10, 5+10
  expected_y_from_a = [4, 8, 12]   # 2*2, 4*2, 6*2
  expected_y_from_b = [2, 6, 10]   # 1*2, 3*2, 5*2
  expected_z_from_a = [4, 16, 36]  # 2^2, 4^2, 6^2
  expected_z_from_b = [1, 9, 25]   # 1^2, 3^2, 5^2

  x_from_a = example.results_x.select { |r| r[:source] == :a }.map { |r| r[:value] }.sort
  x_from_b = example.results_x.select { |r| r[:source] == :b }.map { |r| r[:value] }.sort
  y_from_a = example.results_y.select { |r| r[:source] == :a }.map { |r| r[:value] }.sort
  y_from_b = example.results_y.select { |r| r[:source] == :b }.map { |r| r[:value] }.sort
  z_from_a = example.results_z.select { |r| r[:source] == :a }.map { |r| r[:value] }.sort
  z_from_b = example.results_z.select { |r| r[:source] == :b }.map { |r| r[:value] }.sort

  success = x_from_a == expected_x_from_a &&
            x_from_b == expected_x_from_b &&
            y_from_a == expected_y_from_a &&
            y_from_b == expected_y_from_b &&
            z_from_a == expected_z_from_a &&
            z_from_b == expected_z_from_b

  puts "\n#{success ? '✓ Success!' : '✗ Failed'}"
  puts "Expected: 2 sources × 3 processors = 6 items per processor, 18 total"
  puts "Got: #{example.results_x.size + example.results_y.size + example.results_z.size} total items"
end
