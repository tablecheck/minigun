#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Demonstrates batch processing with thread pools
class BatchProcessorExample
  include Minigun::DSL

  attr_reader :processed_count, :results

  def initialize(workers: 5)
    @workers = workers
    @processed_count = 0
    @results = []
    @mutex = Mutex.new
  end

  pipeline do
    producer :generate do |output|
      %w[apple banana cherry date elderberry fig grape honeydew kiwi lemon].each { |item| output << item }
    end

    processor :process do |item, output|
      @mutex.synchronize { @processed_count += 1 }
      result = { item: item, result: item.upcase, timestamp: Time.now }
      output << result
    end

    consumer :collect do |result|
      @mutex.synchronize { @results << result }
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  processor = BatchProcessorExample.new(workers: 5)
  processor.run

  puts "Processed: #{processor.processed_count} items"
  puts "Results: #{processor.results.map { |r| r[:result] }.join(', ')}"
end

