#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Dynamic Routing to Inner Fork Stages
# Demonstrates using output.to() to route to stages INSIDE ipc_fork/cow_fork blocks
# This tests cross-boundary dynamic routing to nested fork contexts

class DynamicRoutingToInnerIpcExample
  include Minigun::DSL

  attr_reader :results_a, :results_b, :results_c

  def initialize
    @results_a = []
    @results_b = []
    @results_c = []
    @results_a_file = "/tmp/minigun_97_a_#{Process.pid}.txt"
    @results_b_file = "/tmp/minigun_97_b_#{Process.pid}.txt"
    @results_c_file = "/tmp/minigun_97_c_#{Process.pid}.txt"
  end

  def cleanup
    File.unlink(@results_a_file) if File.exist?(@results_a_file)
    File.unlink(@results_b_file) if File.exist?(@results_b_file)
    File.unlink(@results_c_file) if File.exist?(@results_c_file)
  end

  pipeline do
    producer :generate do |output|
      puts '[Producer] Generating 9 items'
      9.times { |i| output << { id: i + 1, value: i + 1 } }
    end

    # Router stage - dynamically routes to inner stages of IPC fork block
    thread_pool(2) do
      processor :router do |item, output|
        # Route based on modulo to different INNER stages of the IPC fork
        case item[:id] % 3
        when 0
          puts "[Router] Routing #{item[:id]} to inner_process_a (inside IPC fork)"
          output.to(:inner_process_a) << item
        when 1
          puts "[Router] Routing #{item[:id]} to inner_process_b (inside IPC fork)"
          output.to(:inner_process_b) << item
        when 2
          puts "[Router] Routing #{item[:id]} to inner_collect_c (inside COW fork)"
          output.to(:inner_collect_c) << item
        end
      end
    end

    # IPC fork context with TWO inner stages
    # These stages are INSIDE the ipc_fork block and can be targeted with output.to()
    # IMPORTANT: await: true is required since these stages have no upstream DAG connections
    # within the fork block, but receive items via dynamic routing from outside
    ipc_fork(2) do
      # Inner stage A - processes subset of items
      processor :inner_process_a, await: true do |item, output|
        result = item.merge(value: item[:value] * 10, processed_by: 'A')
        puts "[InnerProcessA:ipc_fork] #{item[:id]}: #{item[:value]} * 10 = #{result[:value]} (PID #{Process.pid})"
        output << result
      end

      # Inner stage B - processes another subset
      processor :inner_process_b, await: true do |item, output|
        result = item.merge(value: item[:value] * 20, processed_by: 'B')
        puts "[InnerProcessB:ipc_fork] #{item[:id]}: #{item[:value]} * 20 = #{result[:value]} (PID #{Process.pid})"
        output << result
      end
    end

    # COW fork with inner consumer
    # IMPORTANT: await: true required for disconnected stages receiving dynamic routing
    cow_fork(2) do
      # Inner stage C - collects its own subset
      consumer :inner_collect_c, await: true do |item|
        puts "[InnerCollectC:cow_fork] #{item[:id]} = #{item[:value]} (PID #{Process.pid})"
        File.open(@results_c_file, 'a') do |f|
          f.flock(File::LOCK_EX)
          f.puts "#{item[:id]}:#{item[:value]}"
          f.flock(File::LOCK_UN)
        end
      end
    end

    # Separate collectors for A and B paths
    # Use from: to explicitly connect to the IPC fork stages
    consumer :collect_a, from: :inner_process_a do |item|
      puts "[CollectA] Received from A: #{item[:id]} = #{item[:value]}"
      File.open(@results_a_file, 'a') do |f|
        f.flock(File::LOCK_EX)
        f.puts "#{item[:id]}:#{item[:value]}"
        f.flock(File::LOCK_UN)
      end
    end

    consumer :collect_b, from: :inner_process_b do |item|
      puts "[CollectB] Received from B: #{item[:id]} = #{item[:value]}"
      File.open(@results_b_file, 'a') do |f|
        f.flock(File::LOCK_EX)
        f.puts "#{item[:id]}:#{item[:value]}"
        f.flock(File::LOCK_UN)
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
          id, value = line.strip.split(':')
          { id: id.to_i, value: value.to_i }
        end
      end

      if File.exist?(@results_c_file)
        @results_c = File.readlines(@results_c_file).map do |line|
          id, value = line.strip.split(':')
          { id: id.to_i, value: value.to_i }
        end
      end
    end
  end
end

# Example: Routing from INSIDE an IPC fork to INNER stages of another fork
class DynamicRoutingFromInnerToInnerExample
  include Minigun::DSL

  attr_reader :results

  def initialize
    @results = []
    @results_file = "/tmp/minigun_97_inner_#{Process.pid}.txt"
  end

  def cleanup
    File.unlink(@results_file) if File.exist?(@results_file)
  end

  pipeline do
    producer :generate do |output|
      puts '[Producer] Generating 6 items'
      6.times { |i| output << { id: i + 1, value: i + 1 } }
    end

    # First IPC fork with two inner stages
    ipc_fork(2) do
      # Inner router - routes from INSIDE ipc_fork to INNER stages of COW fork
      processor :inner_router do |item, output|
        if item[:id].even?
          puts "[InnerRouter:ipc] Routing #{item[:id]} to cow_process_x (inside COW fork)"
          output.to(:cow_process_x) << item
        else
          puts "[InnerRouter:ipc] Routing #{item[:id]} to cow_process_y (inside COW fork)"
          output.to(:cow_process_y) << item
        end
      end

      # Unused inner stage (to demonstrate multiple stages in same fork)
      processor :unused do |item, output|
        output << item
      end
    end

    # COW fork with two inner stages that receive from IPC inner router
    # IMPORTANT: await: true required for disconnected stages receiving dynamic routing
    cow_fork(2) do
      processor :cow_process_x, await: true do |item, output|
        result = item.merge(value: item[:value] * 100, path: 'X')
        puts "[CowProcessX:cow] #{item[:id]}: #{item[:value]} * 100 = #{result[:value]} (PID #{Process.pid})"
        output << result
      end

      processor :cow_process_y, await: true do |item, output|
        result = item.merge(value: item[:value] * 200, path: 'Y')
        puts "[CowProcessY:cow] #{item[:id]}: #{item[:value]} * 200 = #{result[:value]} (PID #{Process.pid})"
        output << result
      end
    end

    consumer :collect, from: [:cow_process_x, :cow_process_y] do |item|
      puts "[Collect] Received: #{item[:id]} = #{item[:value]} via path #{item[:path]}"
      File.open(@results_file, 'a') do |f|
        f.flock(File::LOCK_EX)
        f.puts "#{item[:id]}:#{item[:value]}:#{item[:path]}"
        f.flock(File::LOCK_UN)
      end
    end

    after_run do
      if File.exist?(@results_file)
        @results = File.readlines(@results_file).map do |line|
          id, value, path = line.strip.split(':')
          { id: id.to_i, value: value.to_i, path: path }
        end
      end
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  puts "=" * 80
  puts "Dynamic Routing to Inner Fork Stages"
  puts "=" * 80
  puts ""

  begin
    puts "--- Dynamic Routing from Thread to Inner IPC/COW Stages ---"
    puts "Flow: generate -> router (thread) -> output.to(:inner_stage) where inner_stage is INSIDE fork"
    example1 = DynamicRoutingToInnerIpcExample.new
    example1.run
    puts "Results A (via inner_process_a): #{example1.results_a.size} items (IDs: #{example1.results_a.map { |r| r[:id] }.sort})"
    puts "Results B (via inner_process_b): #{example1.results_b.size} items (IDs: #{example1.results_b.map { |r| r[:id] }.sort})"
    puts "Results C (via inner_collect_c): #{example1.results_c.size} items (IDs: #{example1.results_c.map { |r| r[:id] }.sort})"
    puts "Expected: 3 items in each path (IDs divisible by 3 in A, remainder 1 in B, remainder 2 in C)"
    success = example1.results_a.size == 3 && example1.results_b.size == 3 && example1.results_c.size == 3
    puts success ? "✓ PASS" : "✗ FAIL"
    example1.cleanup

    puts "\n--- Dynamic Routing from Inner IPC to Inner COW Stages ---"
    puts "Flow: generate -> inner_router (inside IPC) -> output.to(:cow_inner) where cow_inner is INSIDE COW fork"
    example2 = DynamicRoutingFromInnerToInnerExample.new
    example2.run
    puts "Total results: #{example2.results.size} (expected: 6)"
    by_path = example2.results.group_by { |r| r[:path] }
    puts "Path X (even IDs): #{by_path['X']&.size || 0}, Path Y (odd IDs): #{by_path['Y']&.size || 0}"
    expected_x = [200, 400, 600]
    expected_y = [200, 600, 1000]
    actual_x = by_path['X']&.map { |r| r[:value] }&.sort || []
    actual_y = by_path['Y']&.map { |r| r[:value] }&.sort || []
    success = actual_x == expected_x && actual_y == expected_y
    puts success ? "✓ PASS" : "✗ FAIL"
    example2.cleanup

    puts "\n" + "=" * 80
    puts "Key Points:"
    puts "  - output.to() can target stages INSIDE ipc_fork/cow_fork blocks"
    puts "  - Stage names are globally accessible regardless of nesting"
    puts "  - Can route from thread to inner IPC stage"
    puts "  - Can route from thread to inner COW stage"
    puts "  - Can route from inner IPC stage to inner COW stage"
    puts "  - Routing respects executor boundaries and serialization"
    puts "  - IMPORTANT: Inner stages with no DAG upstream need await: true"
    puts "=" * 80
  rescue NotImplementedError => e
    puts "\nForking not available on this platform: #{e.message}"
    puts "(This is expected on Windows)"
  end
end
