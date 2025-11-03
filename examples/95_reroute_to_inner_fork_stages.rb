#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Reroute to Inner Fork Stages
# Demonstrates rerouting to stages INSIDE ipc_fork/cow_fork blocks
# This tests cross-boundary routing to nested fork contexts
class RerouteToInnerIpcStagesExample
  include Minigun::DSL

  attr_reader :results_a, :results_b

  def initialize
    @results_a = []
    @results_b = []
    @results_a_file = "/tmp/minigun_95_a_#{Process.pid}.txt"
    @results_b_file = "/tmp/minigun_95_b_#{Process.pid}.txt"
  end

  def cleanup
    File.unlink(@results_a_file) if File.exist?(@results_a_file)
    File.unlink(@results_b_file) if File.exist?(@results_b_file)
  end

  pipeline do
    producer :generate do |output|
      puts '[Producer] Generating 6 items'
      6.times { |i| output << { id: i + 1, value: i + 1 } }
    end

    # Inline processor
    processor :filter_even do |item, output|
      if item[:id].even?
        puts "[FilterEven] Passing even ID: #{item[:id]}"
        output << item.merge(filtered: true)
      else
        puts "[FilterEven] Filtering odd ID: #{item[:id]}"
      end
    end

    # IPC fork context with TWO inner stages
    ipc_fork(2) do
      # Inner stage A - processes filtered items
      processor :process_a do |item, output|
        result = item.merge(value: item[:value] * 10, processed_by: 'A')
        puts "[ProcessA:ipc_fork] #{item[:id]}: #{item[:value]} * 10 = #{result[:value]} (PID #{Process.pid})"
        output << result
      end

      # Inner stage B - collects processed items
      consumer :collect_b do |item|
        puts "[CollectB:ipc_fork] Received: #{item[:id]} = #{item[:value]} (PID #{Process.pid})"
        File.open(@results_b_file, 'a') do |f|
          f.flock(File::LOCK_EX)
          f.puts "#{item[:id]}:#{item[:value]}:#{item[:processed_by]}"
          f.flock(File::LOCK_UN)
        end
      end
    end

    # COW fork consumer - separate collection point
    cow_fork(2) do
      consumer :collect_a do |item|
        puts "[CollectA:cow_fork] Received: #{item[:id]} = #{item[:value]} (PID #{Process.pid})"
        File.open(@results_a_file, 'a') do |f|
          f.flock(File::LOCK_EX)
          f.puts "#{item[:id]}:#{item[:value]}"
          f.flock(File::LOCK_UN)
        end
      end
    end

    after_run do
      if File.exist?(@results_a_file)
        @results_a = File.readlines(@results_a_file).map do |line|
          id, value = line.strip.split(':')
          { id: id.to_i, value: value.to_i }
        end
      end

      if File.exist?(@results_b_file)
        @results_b = File.readlines(@results_b_file).map do |line|
          id, value, processed_by = line.strip.split(':')
          { id: id.to_i, value: value.to_i, processed_by: processed_by }
        end
      end
    end
  end
end

# Reroute directly to inner IPC stage (bypass filter_even)
class RerouteDirectlyToInnerIpcExample < RerouteToInnerIpcStagesExample
  pipeline do
    # Route generate directly to process_a (which is INSIDE the ipc_fork block)
    # This bypasses the filter_even stage completely
    reroute_stage :generate, to: :process_a
  end
end

# Reroute from inner IPC stage to COW stage
class RerouteFromInnerIpcToCowExample < RerouteToInnerIpcStagesExample
  pipeline do
    # Route process_a (inside IPC fork) directly to collect_a (COW fork)
    # This bypasses collect_b (also inside IPC fork)
    reroute_stage :process_a, to: :collect_a
  end
end

# Reroute between two inner IPC stages with external stage in between
class RerouteIpcInnerComplexExample < RerouteToInnerIpcStagesExample
  pipeline do
    # Add an external thread stage
    thread_pool(2) do
      processor :transform do |item, output|
        result = item.merge(value: item[:value] + 100, transformed: true)
        puts "[Transform:thread] #{item[:id]}: #{item[:value]} + 100 = #{result[:value]}"
        output << result
      end
    end

    # Reroute: generate -> process_a (IPC inner) -> transform (thread) -> collect_b (IPC inner)
    reroute_stage :generate, to: :process_a
    reroute_stage :process_a, to: :transform
    reroute_stage :transform, to: :collect_b
  end
end

if __FILE__ == $PROGRAM_NAME
  puts "=" * 80
  puts "Reroute to Inner Fork Stages Examples"
  puts "=" * 80
  puts ""

  begin
    puts "--- Base Pipeline ---"
    puts "Flow: generate -> filter_even -> process_a (IPC inner) -> collect_b (IPC inner)"
    puts "      [collect_a (COW) is disconnected]"
    base = RerouteToInnerIpcStagesExample.new
    base.run
    puts "Results B: #{base.results_b.map { |r| r[:value] }.inspect}"
    puts "Expected: [20, 40, 60] (even IDs * 10)"
    success = base.results_b.map { |r| r[:value] }.sort == [20, 40, 60]
    puts success ? "✓ PASS" : "✗ FAIL"
    base.cleanup

    puts "\n--- Reroute Directly to Inner IPC Stage ---"
    puts "Flow: generate -> process_a (IPC inner) -> collect_b (IPC inner)"
    puts "      [bypasses filter_even]"
    direct = RerouteDirectlyToInnerIpcExample.new
    direct.run
    puts "Results B: #{direct.results_b.map { |r| r[:value] }.inspect}"
    puts "Expected: [10, 20, 30, 40, 50, 60] (all IDs * 10)"
    success = direct.results_b.map { |r| r[:value] }.sort == [10, 20, 30, 40, 50, 60]
    puts success ? "✓ PASS" : "✗ FAIL"
    direct.cleanup

    puts "\n--- Reroute from Inner IPC to COW ---"
    puts "Flow: generate -> filter_even -> process_a (IPC inner) -> collect_a (COW)"
    puts "      [routes from IPC inner stage to COW outer stage]"
    to_cow = RerouteFromInnerIpcToCowExample.new
    to_cow.run
    puts "Results A: #{to_cow.results_a.map { |r| r[:value] }.inspect}"
    puts "Expected: [20, 40, 60]"
    success = to_cow.results_a.map { |r| r[:value] }.sort == [20, 40, 60]
    puts success ? "✓ PASS" : "✗ FAIL"
    to_cow.cleanup

    puts "\n--- Complex Inner Reroute ---"
    puts "Flow: generate -> process_a (IPC) -> transform (thread) -> collect_b (IPC)"
    puts "      [routes through IPC inner, out to thread, back to IPC inner]"
    complex = RerouteIpcInnerComplexExample.new
    complex.run
    puts "Results B: #{complex.results_b.map { |r| r[:value] }.inspect}"
    puts "Expected: [110, 120, 130, 140, 150, 160] (x * 10 + 100)"
    success = complex.results_b.map { |r| r[:value] }.sort == [110, 120, 130, 140, 150, 160]
    puts success ? "✓ PASS" : "✗ FAIL"
    complex.cleanup

    puts "\n" + "=" * 80
    puts "Key Points:"
    puts "  - Can reroute directly to stages INSIDE ipc_fork/cow_fork blocks"
    puts "  - Can reroute FROM inner fork stages to outer stages"
    puts "  - Can create complex flows: inner IPC -> outer thread -> inner IPC"
    puts "  - Stage names are globally accessible regardless of nesting"
    puts "  - Rerouting respects executor boundaries and serialization"
    puts "=" * 80
  rescue NotImplementedError => e
    puts "\nForking not available on this platform: #{e.message}"
    puts "(This is expected on Windows)"
  end
end
