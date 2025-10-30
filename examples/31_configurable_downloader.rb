#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

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

if __FILE__ == $PROGRAM_NAME
  small_pipeline = ConfigurableDownloader.new(threads: 5, batch_size: 10)
  large_pipeline = ConfigurableDownloader.new(threads: 20, batch_size: 50)

  puts "Small pipeline (5 threads, batch 10):"
  puts "  Configuration: threads=#{small_pipeline.threads}, batch=#{small_pipeline.batch_size}"

  puts "\nLarge pipeline (20 threads, batch 50):"
  puts "  Configuration: threads=#{large_pipeline.threads}, batch=#{large_pipeline.batch_size}"
end

