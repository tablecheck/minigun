#!/usr/bin/env ruby
# frozen_string_literal: true

# Example 31: Configurable Execution Contexts
#
# This example demonstrates the new execution context DSL that allows
# runtime configuration of concurrency patterns using instance variables.
#
# Key Features:
# - Runtime-configurable thread pools
# - Dynamic batch sizes
# - Process-per-batch with configurable limits
# - All parameters accessible as instance variables

require_relative '../lib/minigun'

# Example 1: Basic Configurable Pipeline
puts '=' * 60
puts 'Example 1: Basic Configurable Thread Pool'
puts '=' * 60

# Demonstrates runtime-configurable thread pools
class ConfigurableDownloader
  include Minigun::DSL

  attr_reader :results, :threads, :batch_size

  def initialize(threads: 10, batch_size: 100)
    @threads = threads
    @batch_size = batch_size
    @results = []
    @mutex = Mutex.new
  end

  pipeline do
    producer :gen_urls do |output|
      50.times { |i| output << "https://example.com/#{i}" }
    end

    # Use instance variable for thread count
    threads(@threads) do
      processor :download do |url, output|
        # Simulate download
        sleep 0.01
        output << { url: url, data: "content-#{url}" }
      end
    end

    # Batch before saving
    batch @batch_size

    consumer :save do |batch|
      @mutex.synchronize do
        @results.concat(batch)
      end
    end
  end
end

# Different configurations
small_pipeline = ConfigurableDownloader.new(threads: 5, batch_size: 10)
large_pipeline = ConfigurableDownloader.new(threads: 20, batch_size: 50)

puts "\nSmall pipeline (5 threads, batch 10):"
puts "  Configuration: threads=#{small_pipeline.threads}, batch=#{small_pipeline.batch_size}"

puts "\nLarge pipeline (20 threads, batch 50):"
puts "  Configuration: threads=#{large_pipeline.threads}, batch=#{large_pipeline.batch_size}"

# Example 2: Process Per Batch Configuration
puts "\n"
puts '=' * 60
puts 'Example 2: Configurable Process-Per-Batch'
puts '=' * 60

# Demonstrates configurable process-per-batch with dynamic batch sizes
class DataProcessor
  include Minigun::DSL

  attr_reader :processed_count, :threads, :processes, :batch_size

  def initialize(threads: 50, processes: 4, batch_size: 1000)
    @threads = threads
    @processes = processes
    @batch_size = batch_size
    @processed_count = 0
    @mutex = Mutex.new
  end

  pipeline do
    producer :generate do |output|
      5000.times { |i| output << i }
    end

    # Parallel download with thread pool
    threads(@threads) do
      processor :download do |item, output|
        # Simulate I/O-bound work
        output << { id: item, data: "data-#{item}" }
      end
    end

    # Batch for efficient processing
    batch @batch_size

    # CPU-intensive processing per batch with process isolation
    process_per_batch(max: @processes) do
      processor :parse do |batch, _output|
        # Simulate CPU-intensive work
        batch.map { |item| item[:data].upcase }
      end
    end

    consumer :save do |results|
      @mutex.synchronize do
        @processed_count += results.size
      end
    end
  end
end

processor = DataProcessor.new(threads: 100, processes: 8, batch_size: 500)
puts "\nProcessor configuration:"
puts "  Threads for I/O: #{processor.threads}"
puts "  Max processes: #{processor.processes}"
puts "  Batch size: #{processor.batch_size}"
puts "\nThis allows:"
puts '  - 100 concurrent downloads (threads)'
puts '  - Batches of 500 items'
puts '  - Up to 8 concurrent processes for CPU work'

# Example 3: Environment-Based Configuration
puts "\n"
puts '=' * 60
puts 'Example 3: Environment-Based Configuration'
puts '=' * 60

# Demonstrates environment-based pipeline configuration
class SmartPipeline
  include Minigun::DSL

  attr_reader :env, :threads, :processes, :batch_size

  def initialize
    # Configure based on environment
    @env = ENV['RACK_ENV'] || 'development'

    case @env
    when 'production'
      @threads = 100
      @processes = 8
      @batch_size = 5000
    when 'staging'
      @threads = 50
      @processes = 4
      @batch_size = 1000
    else # development
      @threads = 10
      @processes = 2
      @batch_size = 100
    end
  end

  pipeline do
    producer :source do |output|
      100.times { |i| output << i }
    end

    threads(@threads) do
      processor :work do |item, output|
        output << (item * 2)
      end
    end

    batch @batch_size

    process_per_batch(max: @processes) do
      processor :heavy_work do |batch, _output|
        batch.map { |x| x**2 }
      end
    end

    consumer :sink do |results|
      # Save results
    end
  end
end

smart = SmartPipeline.new
puts "\nEnvironment: #{smart.env}"
puts 'Configuration:'
puts "  Threads: #{smart.threads}"
puts "  Processes: #{smart.processes}"
puts "  Batch size: #{smart.batch_size}"

# Example 4: Dynamic Configuration
puts "\n"
puts '=' * 60
puts 'Example 4: Dynamic Configuration Methods'
puts '=' * 60

# Demonstrates dynamic configuration based on runtime conditions
class AdaptivePipeline
  include Minigun::DSL

  attr_accessor :concurrency_level

  def initialize(concurrency: :medium)
    @concurrency_level = concurrency
  end

  def thread_count
    case @concurrency_level
    when :low then 10
    when :high then 200
    else 50 # medium
    end
  end

  def process_count
    case @concurrency_level
    when :low then 2
    when :high then 16
    else 4 # medium
    end
  end

  def batch_size
    case @concurrency_level
    when :low then 100
    when :high then 10_000
    else 1000 # medium
    end
  end

  pipeline do
    producer :gen do |output|
      1000.times { |i| output << i }
    end

    threads(thread_count) do
      processor :fetch do |item, output|
        output << { id: item, data: 'fetched' }
      end
    end

    batch batch_size

    process_per_batch(max: process_count) do
      processor :process do |batch, _output|
        batch.map { |x| x[:data].upcase }
      end
    end

    consumer :store do |results|
      # Store
    end
  end
end

%i[low medium high].each do |level|
  pipeline = AdaptivePipeline.new(concurrency: level)
  puts "\nConcurrency level: #{level}"
  puts "  Threads: #{pipeline.thread_count}"
  puts "  Processes: #{pipeline.process_count}"
  puts "  Batch size: #{pipeline.batch_size}"
end

# Example 5: Configuration Object Pattern
puts "\n"
puts '=' * 60
puts 'Example 5: Configuration Object Pattern'
puts '=' * 60

# Configuration object for pipeline settings
class PipelineConfig
  attr_accessor :thread_pool_size, :process_pool_size, :batch_size

  def initialize
    @thread_pool_size = 50
    @process_pool_size = 4
    @batch_size = 1000
  end

  def self.from_yaml(_file)
    # Could load from YAML/JSON/ENV
    new
  end
end

# Demonstrates using configuration objects with pipelines
class ConfigurablePipeline
  include Minigun::DSL

  def initialize(config: PipelineConfig.new)
    @config = config
  end

  pipeline do
    producer :source do |output|
      10.times { |i| output << i }
    end

    threads(@config.thread_pool_size) do
      processor :download do |item, output|
        output << (item * 2)
      end
    end

    batch @config.batch_size

    process_per_batch(max: @config.process_pool_size) do
      processor :parse do |batch, _output|
        batch.map { |x| x + 100 }
      end
    end

    consumer :save do |results|
      # Save
    end
  end
end

config = PipelineConfig.new
config.thread_pool_size = 100
config.process_pool_size = 8
config.batch_size = 500

ConfigurablePipeline.new(config: config)
puts "\nUsing configuration object:"
puts "  Thread pool: #{config.thread_pool_size}"
puts "  Process pool: #{config.process_pool_size}"
puts "  Batch size: #{config.batch_size}"

# Summary
puts "\n"
puts '=' * 60
puts 'Summary'
puts '=' * 60
puts <<~SUMMARY

  Configurable Execution Contexts enable:

  1. Runtime Configuration:
     - Thread pool sizes determined at initialization
     - Batch sizes based on data volume
     - Process limits based on available resources

  2. Environment Awareness:
     - Different settings for dev/staging/prod
     - Adapt to available CPU/memory
     - Scale based on workload

  3. Dynamic Behavior:
     - Use instance variables (@threads, @batch_size)
     - Call methods (thread_count, batch_size)
     - Access configuration objects (@config.setting)

  4. Patterns Supported:
     - threads(N) { ... }           # Thread pool
     - processes(N) { ... }          # Process pool (future)
     - ractors(N) { ... }            # Ractor pool (future)
     - batch N                       # Batching
     - process_per_batch(max: N)    # Spawn process per batch
     - thread_per_batch(max: N)     # Spawn thread per batch (future)
     - ractor_per_batch(max: N)     # Spawn ractor per batch (future)

  5. Use Cases:
     - Web scraping with configurable parallelism
     - ETL pipelines with environment-specific settings
     - Data processing with adaptive resource usage
     - Multi-tenant systems with per-tenant limits

  ✓ All configuration happens at initialization
  ✓ Pipeline definition uses instance context
  ✓ Full access to instance variables and methods
  ✓ Clean, declarative DSL
SUMMARY
