#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Reroute with Fork Fan-Out/Fan-In Patterns
# Demonstrates rerouting in complex fan-out and fan-in topologies with forks
class RerouteForkFanOutExample
  include Minigun::DSL

  attr_reader :results_a, :results_b, :results_c

  def initialize
    @results_a = []
    @results_b = []
    @results_c = []
    @results_a_file = "/tmp/minigun_96_a_#{Process.pid}.txt"
    @results_b_file = "/tmp/minigun_96_b_#{Process.pid}.txt"
    @results_c_file = "/tmp/minigun_96_c_#{Process.pid}.txt"
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

    # Splitter routes to three IPC fork consumers
    thread_pool(2) do
      processor :splitter do |item, output|
        # Route based on modulo
        case item[:id] % 3
        when 0
          puts "[Splitter] Routing #{item[:id]} to process_a"
          output.to(:process_a) << item
        when 1
          puts "[Splitter] Routing #{item[:id]} to process_b"
          output.to(:process_b) << item
        when 2
          puts "[Splitter] Routing #{item[:id]} to process_c"
          output.to(:process_c) << item
        end
      end
    end

    # Three IPC fork consumers (fan-out targets)
    ipc_fork(2) do
      consumer :process_a do |item|
        result = item.merge(value: item[:value] * 2)
        puts "[ProcessA:ipc_fork] #{item[:id]}: #{item[:value]} * 2 = #{result[:value]} (PID #{Process.pid})"
        File.open(@results_a_file, 'a') do |f|
          f.flock(File::LOCK_EX)
          f.puts "#{result[:id]}:#{result[:value]}"
          f.flock(File::LOCK_UN)
        end
      end
    end

    ipc_fork(2) do
      consumer :process_b do |item|
        result = item.merge(value: item[:value] * 3)
        puts "[ProcessB:ipc_fork] #{item[:id]}: #{item[:value]} * 3 = #{result[:value]} (PID #{Process.pid})"
        File.open(@results_b_file, 'a') do |f|
          f.flock(File::LOCK_EX)
          f.puts "#{result[:id]}:#{result[:value]}"
          f.flock(File::LOCK_UN)
        end
      end
    end

    ipc_fork(2) do
      consumer :process_c do |item|
        result = item.merge(value: item[:value] * 4)
        puts "[ProcessC:ipc_fork] #{item[:id]}: #{item[:value]} * 4 = #{result[:value]} (PID #{Process.pid})"
        File.open(@results_c_file, 'a') do |f|
          f.flock(File::LOCK_EX)
          f.puts "#{result[:id]}:#{result[:value]}"
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

# Reroute to collapse fan-out (route directly to one consumer)
class RerouteCollapseFanOutExample < RerouteForkFanOutExample
  pipeline do
    # Bypass splitter and route everything to process_a
    reroute_stage :generate, to: :process_a
  end
end

# Reroute to change fan-out targets (different IPC consumers)
class RerouteChangeFanOutExample < RerouteForkFanOutExample
  pipeline do
    # Add a new COW fork consumer
    cow_fork(2) do
      consumer :process_d do |item|
        result = item.merge(value: item[:value] * 5)
        puts "[ProcessD:cow_fork] #{item[:id]}: #{item[:value]} * 5 = #{result[:value]} (PID #{Process.pid})"
        File.open(@results_c_file, 'a') do |f|
          f.flock(File::LOCK_EX)
          f.puts "#{result[:id]}:#{result[:value]}"
          f.flock(File::LOCK_UN)
        end
      end
    end

    # Reroute splitter to fan out to different targets
    # Keep process_a and process_b, replace process_c with process_d
    reroute_stage :splitter, to: [:process_a, :process_b, :process_d]
  end
end

# Fan-in example with multiple IPC fork producers
class RerouteForkFanInExample
  include Minigun::DSL

  attr_reader :results

  def initialize
    @results = []
    @results_file = "/tmp/minigun_96_fanin_#{Process.pid}.txt"
  end

  def cleanup
    File.unlink(@results_file) if File.exist?(@results_file)
  end

  pipeline do
    # Three IPC fork producers (fan-in sources)
    ipc_fork(2) do
      producer :producer_a do |output|
        puts "[ProducerA:ipc_fork] Generating items (PID #{Process.pid})"
        3.times { |i| output << { id: "A#{i + 1}", value: i + 1, source: 'A' } }
      end
    end

    ipc_fork(2) do
      producer :producer_b do |output|
        puts "[ProducerB:ipc_fork] Generating items (PID #{Process.pid})"
        3.times { |i| output << { id: "B#{i + 1}", value: i + 4, source: 'B' } }
      end
    end

    cow_fork(2) do
      producer :producer_c do |output|
        puts "[ProducerC:cow_fork] Generating items (PID #{Process.pid})"
        3.times { |i| output << { id: "C#{i + 1}", value: i + 7, source: 'C' } }
      end
    end

    # Aggregator receives from all three (fan-in)
    thread_pool(2) do
      consumer :aggregator do |item|
        puts "[Aggregator:thread] Received #{item[:id]} from #{item[:source]}: #{item[:value]}"
        File.open(@results_file, 'a') do |f|
          f.flock(File::LOCK_EX)
          f.puts "#{item[:id]}:#{item[:value]}:#{item[:source]}"
          f.flock(File::LOCK_UN)
        end
      end
    end

    after_run do
      if File.exist?(@results_file)
        @results = File.readlines(@results_file).map do |line|
          id, value, source = line.strip.split(':')
          { id: id, value: value.to_i, source: source }
        end
      end
    end
  end
end

# Reroute to change fan-in (remove one producer from aggregator)
class RerouteReduceFanInExample < RerouteForkFanInExample
  pipeline do
    # Add separate consumer for producer_a
    consumer :consumer_a do |item|
      puts "[ConsumerA] Processing #{item[:id]}: #{item[:value]}"
      File.open(@results_file, 'a') do |f|
        f.flock(File::LOCK_EX)
        f.puts "#{item[:id]}:#{item[:value]}:#{item[:source]}_separate"
        f.flock(File::LOCK_UN)
      end
    end

    # Reroute producer_a away from aggregator
    reroute_stage :producer_a, to: :consumer_a
  end
end

if __FILE__ == $PROGRAM_NAME
  puts "=" * 80
  puts "Reroute with Fork Fan-Out/Fan-In Patterns"
  puts "=" * 80
  puts ""

  begin
    puts "--- Fan-Out Base (Thread Splitter -> 3 IPC Consumers) ---"
    base = RerouteForkFanOutExample.new
    base.run
    puts "Results A: #{base.results_a.size} items (IDs: #{base.results_a.map { |r| r[:id] }.sort})"
    puts "Results B: #{base.results_b.size} items (IDs: #{base.results_b.map { |r| r[:id] }.sort})"
    puts "Results C: #{base.results_c.size} items (IDs: #{base.results_c.map { |r| r[:id] }.sort})"
    success = base.results_a.size == 3 && base.results_b.size == 3 && base.results_c.size == 3
    puts success ? "✓ PASS" : "✗ FAIL"
    base.cleanup

    puts "\n--- Collapse Fan-Out (All to One IPC Consumer) ---"
    collapse = RerouteCollapseFanOutExample.new
    collapse.run
    puts "Results A: #{collapse.results_a.size} items (expected: 9)"
    puts "Results B: #{collapse.results_b.size} items (expected: 0)"
    puts "Results C: #{collapse.results_c.size} items (expected: 0)"
    success = collapse.results_a.size == 9 && collapse.results_b.size == 0 && collapse.results_c.size == 0
    puts success ? "✓ PASS" : "✗ FAIL"
    collapse.cleanup

    puts "\n--- Fan-In Base (3 Fork Producers -> Thread Aggregator) ---"
    fanin = RerouteForkFanInExample.new
    fanin.run
    puts "Total results: #{fanin.results.size} (expected: 9)"
    by_source = fanin.results.group_by { |r| r[:source] }
    puts "From A: #{by_source['A']&.size || 0}, B: #{by_source['B']&.size || 0}, C: #{by_source['C']&.size || 0}"
    success = fanin.results.size == 9
    puts success ? "✓ PASS" : "✗ FAIL"
    fanin.cleanup

    puts "\n--- Reduce Fan-In (Remove One Producer) ---"
    reduce = RerouteReduceFanInExample.new
    reduce.run
    puts "Total results: #{reduce.results.size} (expected: 9)"
    by_source = reduce.results.group_by { |r| r[:source] }
    separate_count = reduce.results.count { |r| r[:source].include?('_separate') }
    puts "Separate path: #{separate_count}, Aggregator path: #{reduce.results.size - separate_count}"
    success = reduce.results.size == 9 && separate_count == 3
    puts success ? "✓ PASS" : "✗ FAIL"
    reduce.cleanup

    puts "\n" + "=" * 80
    puts "Key Points:"
    puts "  - reroute_stage works with fork-based fan-out patterns"
    puts "  - Can collapse fan-out (all to one consumer)"
    puts "  - Can change fan-out targets (redirect to different forks)"
    puts "  - Works with fan-in (multiple fork producers to one consumer)"
    puts "  - Can modify fan-in topology (remove/redirect producers)"
    puts "=" * 80
  rescue NotImplementedError => e
    puts "\nForking not available on this platform: #{e.message}"
    puts "(This is expected on Windows)"
  end
end
