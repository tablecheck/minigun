# frozen_string_literal: true

require_relative '../lib/minigun'

# Example demonstrating the difference between COW and IPC fork executors
#
# COW (Copy-On-Write) Fork Executor:
# - Forks child processes that inherit parent memory via copy-on-write
# - Memory pages are shared until modified
# - Efficient for read-heavy operations
# - No serialization overhead
#
# IPC (Inter-Process Communication) Fork Executor:
# - Forks child processes with explicit IPC via pipes
# - Data is serialized through pipes
# - Strong process isolation
# - Useful when you need explicit communication channels

puts "=" * 80
puts "COW Fork Executor Example"
puts "=" * 80

class CowForkExample
  include Minigun::DSL

  # Use COW fork executor
  execution :cow_fork, max: 2

  attr_accessor :results

  def initialize
    @results = []
    @shared_data = Array.new(1000) { |i| i * 2 }  # Large data structure
  end

  pipeline do
    producer :generate do |output|
      5.times { |i| output << i }
    end

    processor :process_with_cow do |item, output|
      # Access shared data without serialization overhead
      # Child process can read @shared_data via COW
      sum = @shared_data.take(100).sum
      output << { item: item, shared_sum: sum, pid: Process.pid }
    end

    consumer :collect do |result|
      @results << result
      puts "Processed #{result[:item]} in PID #{result[:pid]}"
    end
  end
end

begin
  cow_task = CowForkExample.new
  cow_task.run
  puts "\nCOW Fork Results: #{cow_task.results.size} items processed"
  puts "PIDs used: #{cow_task.results.map { |r| r[:pid] }.uniq.join(', ')}"
rescue NotImplementedError => e
  puts "\nCOW Fork not available on this platform: #{e.message}"
  puts "(This is expected on Windows)"
end

puts "\n"
puts "=" * 80
puts "IPC Fork Executor Example"
puts "=" * 80

class IpcForkExample
  include Minigun::DSL

  # Use IPC fork executor
  execution :ipc_fork, max: 2

  attr_accessor :results

  def initialize
    @results = []
  end

  pipeline do
    producer :generate do |output|
      5.times { |i| output << { id: i, value: i * 10 } }
    end

    processor :process_with_ipc do |item, output|
      # Data is serialized through IPC pipes
      # Strong process isolation
      output << {
        id: item[:id],
        value: item[:value],
        computed: item[:value] ** 2,
        pid: Process.pid
      }
    end

    consumer :collect do |result|
      @results << result
      puts "Processed ID #{result[:id]} (value: #{result[:value]} -> #{result[:computed]}) in PID #{result[:pid]}"
    end
  end
end

begin
  ipc_task = IpcForkExample.new
  ipc_task.run
  puts "\nIPC Fork Results: #{ipc_task.results.size} items processed"
  puts "PIDs used: #{ipc_task.results.map { |r| r[:pid] }.uniq.join(', ')}"
rescue NotImplementedError => e
  puts "\nIPC Fork not available on this platform: #{e.message}"
  puts "(This is expected on Windows)"
end

puts "\n"
puts "=" * 80
puts "Comparison: Both executors use forked processes"
puts "=" * 80
puts ""
puts "COW Fork:"
puts "  - Best for: Read-heavy operations on large shared data"
puts "  - Memory: Shared via copy-on-write"
puts "  - Performance: Lower overhead (no serialization)"
puts "  - Use case: Processing large datasets without modification"
puts ""
puts "IPC Fork:"
puts "  - Best for: Independent process execution with explicit communication"
puts "  - Memory: Isolated processes"
puts "  - Performance: Serialization overhead via pipes"
puts "  - Use case: Strong isolation, error handling via IPC"
puts ""
puts "=" * 80

