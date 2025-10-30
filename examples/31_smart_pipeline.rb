#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

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

if __FILE__ == $PROGRAM_NAME
  smart = SmartPipeline.new
  puts "Environment: #{smart.env}"
  puts 'Configuration:'
  puts "  Threads: #{smart.threads}"
  puts "  Processes: #{smart.processes}"
  puts "  Batch size: #{smart.batch_size}"
end

