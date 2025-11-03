#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Mixed Executor Rerouting
# Demonstrates rerouting between different executor types (inline, threads, IPC, COW)
class RerouteMixedExecutorsExample
  include Minigun::DSL

  attr_reader :results

  def initialize
    @results = []
    @results_file = "/tmp/minigun_94_#{Process.pid}.txt"
  end

  def cleanup
    File.unlink(@results_file) if File.exist?(@results_file)
  end

  pipeline do
    # Inline producer
    producer :generate do |output|
      puts '[Producer:inline] Generating 6 items'
      6.times { |i| output << { id: i + 1, value: i + 1 } }
    end

    # Thread pool processor
    thread_pool(2) do
      processor :add_ten do |item, output|
        result = item.merge(value: item[:value] + 10, thread_processed: true)
        puts "[AddTen:thread] #{item[:id]}: #{item[:value]} + 10 = #{result[:value]}"
        output << result
      end
    end

    # IPC fork processor
    ipc_fork(2) do
      processor :multiply_two do |item, output|
        result = item.merge(value: item[:value] * 2, ipc_processed: true)
        puts "[MultiplyTwo:ipc_fork] #{item[:id]}: #{item[:value]} * 2 = #{result[:value]} (PID #{Process.pid})"
        output << result
      end
    end

    # COW fork consumer
    cow_fork(2) do
      consumer :collect do |item|
        puts "[Collect:cow_fork] #{item[:id]} = #{item[:value]} (PID #{Process.pid})"
        File.open(@results_file, 'a') do |f|
          f.flock(File::LOCK_EX)
          f.puts "#{item[:id]}:#{item[:value]}"
          f.flock(File::LOCK_UN)
        end
      end
    end

    after_run do
      if File.exist?(@results_file)
        @results = File.readlines(@results_file).map do |line|
          id, value = line.strip.split(':')
          { id: id.to_i, value: value.to_i }
        end
      end
    end
  end
end

# Reroute to skip thread stage (inline -> IPC directly)
class RerouteSkipThreadExample < RerouteMixedExecutorsExample
  pipeline do
    reroute_stage :generate, to: :multiply_two
  end
end

# Reroute to skip IPC stage (threads -> COW directly)
class RerouteSkipIpcExample < RerouteMixedExecutorsExample
  pipeline do
    reroute_stage :add_ten, to: :collect
  end
end

# Reroute to reverse order (inline -> COW -> IPC -> threads -> collect)
class RerouteReverseOrderExample < RerouteMixedExecutorsExample
  pipeline do
    # Create a new COW stage at the beginning
    cow_fork(2) do
      processor :subtract_five do |item, output|
        result = item.merge(value: item[:value] - 5)
        puts "[SubtractFive:cow_fork] #{item[:id]}: #{item[:value]} - 5 = #{result[:value]} (PID #{Process.pid})"
        output << result
      end
    end

    # Reroute to change flow order
    reroute_stage :generate, to: :subtract_five
    reroute_stage :subtract_five, to: :multiply_two
    reroute_stage :multiply_two, to: :add_ten
    reroute_stage :add_ten, to: :collect
  end
end

if __FILE__ == $PROGRAM_NAME
  puts "=" * 80
  puts "Mixed Executor Rerouting Examples"
  puts "=" * 80
  puts ""

  begin
    puts "--- Base Pipeline (Mixed Executors) ---"
    puts "Flow: generate (inline) -> add_ten (threads) -> multiply_two (IPC) -> collect (COW)"
    base = RerouteMixedExecutorsExample.new
    base.run
    puts "Results: #{base.results.map { |r| r[:value] }.inspect}"
    puts "Expected: [22, 24, 26, 28, 30, 32] ((x + 10) * 2)"
    success = base.results.map { |r| r[:value] }.sort == [22, 24, 26, 28, 30, 32]
    puts success ? "✓ PASS" : "✗ FAIL"
    base.cleanup

    puts "\n--- Skip Thread Stage (Reroute) ---"
    puts "Flow: generate (inline) -> multiply_two (IPC) -> collect (COW)"
    skip_thread = RerouteSkipThreadExample.new
    skip_thread.run
    puts "Results: #{skip_thread.results.map { |r| r[:value] }.inspect}"
    puts "Expected: [2, 4, 6, 8, 10, 12] (x * 2)"
    success = skip_thread.results.map { |r| r[:value] }.sort == [2, 4, 6, 8, 10, 12]
    puts success ? "✓ PASS" : "✗ FAIL"
    skip_thread.cleanup

    puts "\n--- Skip IPC Stage (Reroute) ---"
    puts "Flow: generate (inline) -> add_ten (threads) -> collect (COW)"
    skip_ipc = RerouteSkipIpcExample.new
    skip_ipc.run
    puts "Results: #{skip_ipc.results.map { |r| r[:value] }.inspect}"
    puts "Expected: [11, 12, 13, 14, 15, 16] (x + 10)"
    success = skip_ipc.results.map { |r| r[:value] }.sort == [11, 12, 13, 14, 15, 16]
    puts success ? "✓ PASS" : "✗ FAIL"
    skip_ipc.cleanup

    puts "\n--- Reverse Order (Reroute) ---"
    puts "Flow: generate -> subtract_five (COW) -> multiply_two (IPC) -> add_ten (threads) -> collect (COW)"
    reverse = RerouteReverseOrderExample.new
    reverse.run
    puts "Results: #{reverse.results.map { |r| r[:value] }.inspect}"
    puts "Expected: [2, 4, 6, 8, 10, 12] ((x - 5) * 2 + 10)"
    success = reverse.results.map { |r| r[:value] }.sort == [2, 4, 6, 8, 10, 12]
    puts success ? "✓ PASS" : "✗ FAIL"
    reverse.cleanup

    puts "\n" + "=" * 80
    puts "Key Points:"
    puts "  - reroute_stage works across different executor types"
    puts "  - Can route inline -> IPC, threads -> COW, etc."
    puts "  - Rerouting preserves executor semantics (isolation, serialization)"
    puts "  - Enables flexible pipeline composition with mixed executors"
    puts "=" * 80
  rescue NotImplementedError => e
    puts "\nForking not available on this platform: #{e.message}"
    puts "(This is expected on Windows)"
  end
end
