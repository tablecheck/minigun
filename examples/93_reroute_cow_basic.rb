#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Basic Reroute with COW Fork
# Demonstrates rerouting to and from COW fork stages
class RerouteCowBasicExample
  include Minigun::DSL

  attr_reader :results

  def initialize
    @results = []
    @results_file = "/tmp/minigun_93_#{Process.pid}.txt"
  end

  def cleanup
    File.unlink(@results_file) if File.exist?(@results_file)
  end

  pipeline do
    producer :generate do |output|
      puts '[Producer] Generating 5 items'
      5.times { |i| output << { id: i + 1, value: i + 1 } }
    end

    # COW fork processor - squares values
    cow_fork(3) do
      processor :square do |item, output|
        result = item.merge(value: item[:value] ** 2, squared: true)
        puts "[Square:cow_fork] #{item[:id]}: #{item[:value]}^2 = #{result[:value]} (PID #{Process.pid})"
        output << result
      end
    end

    # COW fork consumer - collects results
    cow_fork(3) do
      consumer :collect do |item|
        puts "[Collect:cow_fork] Received: #{item[:id]} = #{item[:value]} (PID #{Process.pid})"
        File.open(@results_file, 'a') do |f|
          f.flock(File::LOCK_EX)
          f.puts "#{item[:id]}:#{item[:value]}:#{item[:squared]}"
          f.flock(File::LOCK_UN)
        end
      end
    end

    after_run do
      if File.exist?(@results_file)
        @results = File.readlines(@results_file).map do |line|
          id, value, squared = line.strip.split(':')
          { id: id.to_i, value: value.to_i, squared: squared == 'true' }
        end
      end
    end
  end
end

# Skip COW fork stage via reroute
class RerouteCowSkipExample < RerouteCowBasicExample
  pipeline do
    # Reroute to skip the square stage
    reroute_stage :generate, to: :collect
  end
end

# Insert new COW fork stage via reroute
class RerouteCowInsertExample < RerouteCowBasicExample
  pipeline do
    # Add a new COW fork stage
    cow_fork(3) do
      processor :cube do |item, output|
        result = item.merge(value: item[:value] ** 3, cubed: true)
        puts "[Cube:cow_fork] #{item[:id]}: #{item[:value]}^3 = #{result[:value]} (PID #{Process.pid})"
        output << result
      end
    end

    # Reroute to insert cube between square and collect
    reroute_stage :square, to: :cube
    reroute_stage :cube, to: :collect
  end
end

if __FILE__ == $PROGRAM_NAME
  puts "=" * 80
  puts "Basic Reroute with COW Fork Examples"
  puts "=" * 80
  puts ""

  begin
    puts "--- Base Pipeline (COW fork) ---"
    puts "Flow: generate -> square (COW) -> collect (COW)"
    base = RerouteCowBasicExample.new
    base.run
    puts "Results: #{base.results.map { |r| r[:value] }.inspect}"
    puts "Expected: [1, 4, 9, 16, 25]"
    success = base.results.map { |r| r[:value] }.sort == [1, 4, 9, 16, 25]
    puts success ? "✓ PASS" : "✗ FAIL"
    base.cleanup

    puts "\n--- Skip COW Stage (Reroute) ---"
    puts "Flow: generate -> collect (COW) [skips square]"
    skip = RerouteCowSkipExample.new
    skip.run
    puts "Results: #{skip.results.map { |r| r[:value] }.inspect}"
    puts "Expected: [1, 2, 3, 4, 5]"
    success = skip.results.map { |r| r[:value] }.sort == [1, 2, 3, 4, 5]
    puts success ? "✓ PASS" : "✗ FAIL"
    skip.cleanup

    puts "\n--- Insert COW Stage (Reroute) ---"
    puts "Flow: generate -> square (COW) -> cube (COW) -> collect (COW)"
    insert = RerouteCowInsertExample.new
    insert.run
    puts "Results: #{insert.results.map { |r| r[:value] }.inspect}"
    puts "Expected: [1, 64, 729, 4096, 15625] (square then cube)"
    success = insert.results.map { |r| r[:value] }.sort == [1, 64, 729, 4096, 15625]
    puts success ? "✓ PASS" : "✗ FAIL"
    insert.cleanup

    puts "\n" + "=" * 80
    puts "Key Points:"
    puts "  - reroute_stage works with COW fork executors"
    puts "  - Can skip COW fork stages"
    puts "  - Can insert new COW fork stages in the flow"
    puts "  - Rerouting preserves COW semantics and ephemeral process model"
    puts "=" * 80
  rescue NotImplementedError => e
    puts "\nForking not available on this platform: #{e.message}"
    puts "(This is expected on Windows)"
  end
end
