#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'
require 'tempfile'

# Example demonstrating Runner features:
# - Job ID tracking in logs
# - Signal handling (Ctrl+C gracefully)
# - Process.setproctitle (visible in ps/top)
# - GC before forking
# - Difference between run() and perform()
class RunnerFeaturesExample
  include Minigun::DSL

  attr_accessor :results

  def initialize
    @results = []
    @temp_file = Tempfile.new(['minigun_results', '.txt'])
    @temp_file.close
  end

  pipeline do
    producer :generate do |output|
      puts '[Producer] Generating 10 items'
      10.times { |i| output << (i + 1) }
    end

    processor :double do |num, output|
      result = num * 2
      puts "[Processor] #{num} * 2 = #{result}"
      output << result
    end

    # Use accumulator + process_per_batch to see process title in action
    accumulator :batch, max_size: 5

    process_per_batch(max: 2) do
      consumer :process do |batch|
        # On Unix systems, run 'ps aux | grep minigun' while this is running
        # You'll see: "minigun-default-consumer-12345"
        puts "[Fork:#{Process.pid}] Processing batch of #{batch.size} items"
        sleep 0.5 # Keep process alive briefly so you can see it in ps
        # Write results to temp file (fork-safe)
        File.open(@temp_file.path, 'a') do |f|
          f.flock(File::LOCK_EX)
          batch.each { |num| f.puts(num) }
          f.flock(File::LOCK_UN)
        end
      end
    end

    after_run do
      # Read fork results from temp file
      @results = File.readlines(@temp_file.path).map { |line| line.strip.to_i } if File.exist?(@temp_file.path)
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  puts "=== Runner Features Demo ===\n\n"

  example = RunnerFeaturesExample.new

  puts '--- Using run() - Full Production Execution ---'
  puts 'Features:'
  puts '  • Job ID in logs: [Job:abc123]'
  puts '  • Signal handling: Try Ctrl+C (graceful shutdown)'
  puts "  • Process title: Run 'ps aux | grep minigun' in another terminal"
  puts '  • Statistics: items/min at completion'
  puts "  • GC before fork: Memory optimized\n\n"

  example.run
  puts "\nResults: #{example.results.sort.inspect}"

  puts "\n--- Using perform() - Direct Execution ---"
  puts "Use this for testing or embedding (no Runner overhead)\n\n"

  example2 = RunnerFeaturesExample.new
  count = example2.perform # Direct, no job ID, no signals
  puts "\nDirect execution complete: #{count} items"

  puts "\n=== Key Differences ==="
  puts 'run()     - Production: signals, job ID, stats, cleanup'
  puts 'perform() - Testing: lightweight, no overhead'
  puts "\n✓ Runner features demonstrated!"
end
