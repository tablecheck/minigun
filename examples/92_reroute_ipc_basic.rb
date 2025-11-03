#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Basic Reroute with IPC Fork
# Demonstrates rerouting to and from IPC fork stages
class RerouteIpcBasicExample
  include Minigun::DSL

  attr_reader :results

  def initialize
    @results = []
    @results_file = "/tmp/minigun_92_#{Process.pid}.txt"
  end

  def cleanup
    File.unlink(@results_file) if File.exist?(@results_file)
  end

  pipeline do
    producer :generate do |output|
      puts '[Producer] Generating 5 items'
      5.times { |i| output << { id: i + 1, value: i + 1 } }
    end

    # IPC fork processor - doubles values
    ipc_fork(2) do
      processor :double do |item, output|
        result = item.merge(value: item[:value] * 2, doubled: true)
        puts "[Double:ipc_fork] #{item[:id]}: #{item[:value]} * 2 = #{result[:value]} (PID #{Process.pid})"
        output << result
      end
    end

    # IPC fork consumer - collects results
    ipc_fork(2) do
      consumer :collect do |item|
        puts "[Collect:ipc_fork] Received: #{item[:id]} = #{item[:value]} (PID #{Process.pid})"
        File.open(@results_file, 'a') do |f|
          f.flock(File::LOCK_EX)
          f.puts "#{item[:id]}:#{item[:value]}:#{item[:doubled]}"
          f.flock(File::LOCK_UN)
        end
      end
    end

    after_run do
      if File.exist?(@results_file)
        @results = File.readlines(@results_file).map do |line|
          id, value, doubled = line.strip.split(':')
          { id: id.to_i, value: value.to_i, doubled: doubled == 'true' }
        end
      end
    end
  end
end

# Skip IPC fork stage via reroute
class RerouteIpcSkipExample < RerouteIpcBasicExample
  pipeline do
    # Reroute to skip the double stage
    reroute_stage :generate, to: :collect
  end
end

# Insert new IPC fork stage via reroute
class RerouteIpcInsertExample < RerouteIpcBasicExample
  pipeline do
    # Add a new IPC fork stage
    ipc_fork(2) do
      processor :triple do |item, output|
        result = item.merge(value: item[:value] * 3, tripled: true)
        puts "[Triple:ipc_fork] #{item[:id]}: #{item[:value]} * 3 = #{result[:value]} (PID #{Process.pid})"
        output << result
      end
    end

    # Reroute to insert triple between double and collect
    reroute_stage :double, to: :triple
    reroute_stage :triple, to: :collect
  end
end

if __FILE__ == $PROGRAM_NAME
  puts "=" * 80
  puts "Basic Reroute with IPC Fork Examples"
  puts "=" * 80
  puts ""

  begin
    puts "--- Base Pipeline (IPC fork) ---"
    puts "Flow: generate -> double (IPC) -> collect (IPC)"
    base = RerouteIpcBasicExample.new
    base.run
    puts "Results: #{base.results.map { |r| r[:value] }.inspect}"
    puts "Expected: [2, 4, 6, 8, 10]"
    success = base.results.map { |r| r[:value] }.sort == [2, 4, 6, 8, 10]
    puts success ? "✓ PASS" : "✗ FAIL"
    base.cleanup

    puts "\n--- Skip IPC Stage (Reroute) ---"
    puts "Flow: generate -> collect (IPC) [skips double]"
    skip = RerouteIpcSkipExample.new
    skip.run
    puts "Results: #{skip.results.map { |r| r[:value] }.inspect}"
    puts "Expected: [1, 2, 3, 4, 5]"
    success = skip.results.map { |r| r[:value] }.sort == [1, 2, 3, 4, 5]
    puts success ? "✓ PASS" : "✗ FAIL"
    skip.cleanup

    puts "\n--- Insert IPC Stage (Reroute) ---"
    puts "Flow: generate -> double (IPC) -> triple (IPC) -> collect (IPC)"
    insert = RerouteIpcInsertExample.new
    insert.run
    puts "Results: #{insert.results.map { |r| r[:value] }.inspect}"
    puts "Expected: [6, 12, 18, 24, 30] (double then triple)"
    success = insert.results.map { |r| r[:value] }.sort == [6, 12, 18, 24, 30]
    puts success ? "✓ PASS" : "✗ FAIL"
    insert.cleanup

    puts "\n" + "=" * 80
    puts "Key Points:"
    puts "  - reroute_stage works with IPC fork executors"
    puts "  - Can skip IPC fork stages"
    puts "  - Can insert new IPC fork stages in the flow"
    puts "  - Rerouting preserves fork isolation and serialization"
    puts "=" * 80
  rescue NotImplementedError => e
    puts "\nForking not available on this platform: #{e.message}"
    puts "(This is expected on Windows)"
  end
end
