#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Complex Routing with Await Stages
# Demonstrates advanced patterns with await: true stages including:
# - Multi-level routing (stage A -> stage B -> stage C)
# - Conditional routing based on item properties
# - Mixing await stages with normal DAG-connected stages
# - Multiple collectors from different sources

class ComplexAwaitRoutingExample
  include Minigun::DSL

  attr_reader :high_priority, :low_priority, :errors

  def initialize
    @high_priority = []
    @low_priority = []
    @errors = []
    @high_file = "/tmp/minigun_98_high_#{Process.pid}.txt"
    @low_file = "/tmp/minigun_98_low_#{Process.pid}.txt"
    @error_file = "/tmp/minigun_98_error_#{Process.pid}.txt"
  end

  def cleanup
    File.unlink(@high_file) if File.exist?(@high_file)
    File.unlink(@low_file) if File.exist?(@low_file)
    File.unlink(@error_file) if File.exist?(@error_file)
  end

  pipeline do
    producer :generate do |output|
      puts '[Producer] Generating 20 items with priorities'
      20.times do |i|
        id = i + 1
        priority = case id % 4
                   when 0 then :high
                   when 1 then :low
                   when 2 then :high
                   else :error
                   end
        output << { id: id, priority: priority, value: id * 10 }
      end
    end

    # Primary router - routes based on priority
    processor :primary_router do |item, output|
      case item[:priority]
      when :high
        puts "[PrimaryRouter] Routing high priority item #{item[:id]} to high_priority_handler"
        output.to(:high_priority_handler) << item
      when :low
        puts "[PrimaryRouter] Routing low priority item #{item[:id]} to low_priority_handler"
        output.to(:low_priority_handler) << item
      when :error
        puts "[PrimaryRouter] Routing error item #{item[:id]} to error_handler"
        output.to(:error_handler) << item
      end
    end

    # High priority handler - await stage that does validation
    processor :high_priority_handler, await: true do |item, output|
      validated = item.merge(validated: true, handler: :high)
      puts "[HighPriorityHandler] Validated #{item[:id]}"
      # Route to enricher for further processing
      output.to(:enricher) << validated
    end

    # Low priority handler - await stage with different processing
    processor :low_priority_handler, await: true do |item, output|
      processed = item.merge(processed: true, handler: :low)
      puts "[LowPriorityHandler] Processed #{item[:id]}"
      output << processed
    end

    # Error handler - await stage for error processing
    processor :error_handler, await: true do |item, output|
      error_data = item.merge(error: true, handler: :error)
      puts "[ErrorHandler] Handled error #{item[:id]}"
      output << error_data
    end

    # Enricher - await stage that receives from high_priority_handler
    processor :enricher, await: true do |item, output|
      enriched = item.merge(enriched: true, enrichment_time: Time.now.to_i)
      puts "[Enricher] Enriched #{item[:id]}"
      output << enriched
    end

    # Separate collectors for each path
    consumer :collect_high, from: :enricher do |item|
      puts "[CollectHigh] Received #{item[:id]} = #{item[:value]}"
      File.open(@high_file, 'a') do |f|
        f.flock(File::LOCK_EX)
        f.puts "#{item[:id]}:#{item[:value]}:#{item[:validated]}:#{item[:enriched]}"
        f.flock(File::LOCK_UN)
      end
    end

    consumer :collect_low, from: :low_priority_handler do |item|
      puts "[CollectLow] Received #{item[:id]} = #{item[:value]}"
      File.open(@low_file, 'a') do |f|
        f.flock(File::LOCK_EX)
        f.puts "#{item[:id]}:#{item[:value]}:#{item[:processed]}"
        f.flock(File::LOCK_UN)
      end
    end

    consumer :collect_errors, from: :error_handler do |item|
      puts "[CollectErrors] Received error #{item[:id]}"
      File.open(@error_file, 'a') do |f|
        f.flock(File::LOCK_EX)
        f.puts "#{item[:id]}:#{item[:error]}"
        f.flock(File::LOCK_UN)
      end
    end

    after_run do
      if File.exist?(@high_file)
        @high_priority = File.readlines(@high_file).map do |line|
          parts = line.strip.split(':')
          { id: parts[0].to_i, value: parts[1].to_i, validated: parts[2] == 'true', enriched: parts[3] == 'true' }
        end
      end

      if File.exist?(@low_file)
        @low_priority = File.readlines(@low_file).map do |line|
          parts = line.strip.split(':')
          { id: parts[0].to_i, value: parts[1].to_i, processed: parts[2] == 'true' }
        end
      end

      if File.exist?(@error_file)
        @errors = File.readlines(@error_file).map do |line|
          parts = line.strip.split(':')
          { id: parts[0].to_i, error: parts[1] == 'true' }
        end
      end
    end
  end
end

# Example with IPC fork for high-throughput scenario
class AwaitWithIpcExample
  include Minigun::DSL

  attr_reader :results

  def initialize
    @results = []
    @results_file = "/tmp/minigun_98_ipc_#{Process.pid}.txt"
  end

  def cleanup
    File.unlink(@results_file) if File.exist?(@results_file)
  end

  pipeline do
    producer :generate do |output|
      puts '[Producer] Generating 10 items for IPC processing'
      10.times { |i| output << { id: i + 1, data: "item_#{i + 1}" } }
    end

    # Router running in main process
    processor :router do |item, output|
      if item[:id].even?
        puts "[Router] Routing #{item[:id]} to ipc_worker_a"
        output.to(:ipc_worker_a) << item
      else
        puts "[Router] Routing #{item[:id]} to ipc_worker_b"
        output.to(:ipc_worker_b) << item
      end
    end

    # IPC workers - these are await stages inside IPC fork
    ipc_fork(2) do
      processor :ipc_worker_a, await: true do |item, output|
        result = item.merge(worker: :a, processed_at: Time.now.to_i, pid: Process.pid)
        puts "[IpcWorkerA] Processed #{item[:id]} in PID #{Process.pid}"
        output << result
      end

      processor :ipc_worker_b, await: true do |item, output|
        result = item.merge(worker: :b, processed_at: Time.now.to_i, pid: Process.pid)
        puts "[IpcWorkerB] Processed #{item[:id]} in PID #{Process.pid}"
        output << result
      end
    end

    # Collector from both IPC workers
    consumer :collect, from: [:ipc_worker_a, :ipc_worker_b] do |item|
      puts "[Collect] Received #{item[:id]} from worker #{item[:worker]}"
      File.open(@results_file, 'a') do |f|
        f.flock(File::LOCK_EX)
        f.puts "#{item[:id]}:#{item[:worker]}:#{item[:pid]}"
        f.flock(File::LOCK_UN)
      end
    end

    after_run do
      if File.exist?(@results_file)
        @results = File.readlines(@results_file).map do |line|
          parts = line.strip.split(':')
          { id: parts[0].to_i, worker: parts[1].to_sym, pid: parts[2].to_i }
        end
      end
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  puts "=" * 80
  puts "Complex Await Stages Routing Examples"
  puts "=" * 80
  puts ""

  begin
    # Test 1: Complex multi-level routing
    puts "--- Test 1: Multi-level routing with await stages ---"
    puts "Flow: generate -> primary_router -> [high/low/error]_handler -> enricher -> collectors"
    example1 = ComplexAwaitRoutingExample.new
    example1.run

    puts "\nResults:"
    puts "  High priority (enriched): #{example1.high_priority.size} items"
    puts "  Low priority: #{example1.low_priority.size} items"
    puts "  Errors: #{example1.errors.size} items"

    # Verify distribution: 20 items total
    # IDs 4,8,12,16,20 = high (5 items) BUT id%4==0 is high, id%4==2 is high
    # Actually: id%4: 0=high, 1=low, 2=high, 3=error
    # So: high=[4,8,12,16,20, 2,6,10,14,18] = 10 items
    #     low=[1,5,9,13,17] = 5 items
    #     error=[3,7,11,15,19] = 5 items

    expected_high = 10
    expected_low = 5
    expected_error = 5

    success1 = example1.high_priority.size == expected_high &&
               example1.low_priority.size == expected_low &&
               example1.errors.size == expected_error

    # Verify enrichment chain for high priority
    all_enriched = example1.high_priority.all? { |item| item[:validated] && item[:enriched] }
    success1 = success1 && all_enriched

    puts success1 ? "✓ PASS" : "✗ FAIL"
    example1.cleanup

    # Test 2: IPC fork with await stages
    puts "\n--- Test 2: IPC fork with await stages ---"
    puts "Flow: generate -> router -> [ipc_worker_a, ipc_worker_b] -> collect"

    example2 = AwaitWithIpcExample.new
    example2.run

    puts "\nResults: #{example2.results.size} items (expected: 10)"
    by_worker = example2.results.group_by { |r| r[:worker] }
    puts "  Worker A: #{by_worker[:a]&.size || 0} items"
    puts "  Worker B: #{by_worker[:b]&.size || 0} items"

    # Verify all items processed and split between workers
    success2 = example2.results.size == 10 &&
               by_worker[:a]&.size == 5 &&
               by_worker[:b]&.size == 5

    # Verify workers ran in different PIDs
    pids = example2.results.map { |r| r[:pid] }.uniq
    success2 = success2 && pids.size > 1

    puts success2 ? "✓ PASS" : "✗ FAIL"
    example2.cleanup

    puts "\n" + "=" * 80
    puts "Key Points:"
    puts "  - await: true stages can form multi-level routing chains"
    puts "  - Conditional routing works with await stages"
    puts "  - await stages integrate with IPC/COW fork executors"
    puts "  - Multiple collectors can receive from different await sources"
    puts "  - Dynamic routing to await stages is fully isolated from DAG"
    puts "=" * 80
  rescue NotImplementedError => e
    puts "\nForking not available on this platform: #{e.message}"
    puts "(This is expected on Windows)"
  end
end
