#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

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

  attr_reader :results

  def initialize(config: PipelineConfig.new)
    @config = config
    @results = []
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
      processor :parse do |batch, output|
        batch.map { |x| x + 100 }.each { |result| output << result }
      end
    end

    consumer :save do |result|
      @results << result
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  config = PipelineConfig.new
  config.thread_pool_size = 100
  config.process_pool_size = 8
  config.batch_size = 500

  puts "Using configuration object:"
  puts "  Thread pool: #{config.thread_pool_size}"
  puts "  Process pool: #{config.process_pool_size}"
  puts "  Batch size: #{config.batch_size}"
end

