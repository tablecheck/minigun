#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Simulated ActiveRecord-like model
class Customer
  attr_reader :id, :name, :email, :updated_at

  def initialize(id)
    @id = id
    @name = "Customer #{id}"
    @email = "customer#{id}@example.com"
    @updated_at = Time.now - (rand(1..365) * 86_400) # Random date within last year
  end

  # Simulate ActiveRecord's find_each (batched iteration)
  def self.find_each(batch_size: 1000)
    puts "[Model] Fetching customers in batches of #{batch_size}..."

    # Simulate fetching 20 records from database
    20.times do |i|
      yield new(i + 1)
    end
  end

  def to_h
    {
      id: @id,
      name: @name,
      email: @email,
      updated_at: @updated_at.strftime('%Y-%m-%dT%H:%M:%S%z')
    }
  end
end

# Database Publisher Pipeline
# Real-world example: Sync database records to Elasticsearch or external service
class DatabasePublisher
  include Minigun::DSL

  max_threads 5       # 5 concurrent processor threads
  max_processes 2     # 2 forked consumer processes (if using process_per_batch)

  attr_accessor :published_ids, :enriched_count

  def initialize(model_class = Customer)
    @model_class = model_class
    @published_ids = []
    @enriched_count = 0
    @mutex = Mutex.new
    @start_time = nil
  end

  # Enrich customer data with additional info
  def enrich_customer_data(customer_data)
    # Simulate enrichment: add derived fields, lookup related data, etc.
    customer_data.merge(
      published_at: Time.now.strftime('%Y-%m-%dT%H:%M:%S%z'),
      source: 'database_publisher',
      version: 1
    )
  end

  # Simulate publishing to external service (Elasticsearch, API, etc.)
  def publish_to_service(enriched_data)
    # In real code, this would be:
    #   Elasticsearch::Client.new.index(
    #     index: 'customers',
    #     id: enriched_data[:id],
    #     body: enriched_data
    #   )

    sleep 0.01 # Simulate network I/O
    puts "[Publish] Published customer #{enriched_data[:id]} to service"
  end

  pipeline do
    before_run do
      @start_time = Time.now
      puts '[Lifecycle] Starting database publisher...'
      puts "[Lifecycle] Target model: #{@model_class.name}"
    end

    after_run do
      duration = Time.now - @start_time
      puts '[Lifecycle] Publishing complete!'
      puts "[Lifecycle] Duration: #{duration.round(2)}s"
      puts "[Lifecycle] Published #{@published_ids.size} records"
      puts "[Lifecycle] Average: #{(@published_ids.size / duration).round(2)} records/sec"
    end

    # Stage 1: Fetch customer IDs from database
    producer :fetch_customers do |output|
      puts "[Producer] Fetching customers from #{@model_class.name}..."

      @model_class.find_each do |customer|
        # Emit customer hash for downstream processing
        output << customer.to_h
      end

      puts '[Producer] Finished fetching customers'
    end

    # Stage 2: Enrich customer data
    processor :enrich_data do |customer_data, output|
      customer_hash = customer_data
      enriched = enrich_customer_data(customer_hash)

      @mutex.synchronize { @enriched_count += 1 }

      # Emit enriched data for publishing
      output << enriched
    end

    # Stage 3: Publish to external service
    # Using threaded consumer for simplicity (could use accumulator + process_per_batch for COW optimization)
    consumer :publish do |enriched_data|
      publish_to_service(enriched_data)

      @mutex.synchronize do
        @published_ids << enriched_data[:id]
      end
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  puts "=== Database Publisher Example ===\n\n"
  puts 'This example demonstrates a real-world ETL pipeline:'
  puts '  1. Fetch records from database (batched)'
  puts '  2. Enrich data with additional fields'
  puts "  3. Publish to external service (Elasticsearch, API, etc.)\n\n"

  publisher = DatabasePublisher.new
  result = publisher.run

  puts "\n=== Results ===\n"
  puts "Total records processed: #{result}"
  puts "Successfully published: #{publisher.published_ids.size}"
  puts "Enrichment operations: #{publisher.enriched_count}"

  puts "\n=== Published IDs (first 10) ===\n"
  publisher.published_ids.first(10).each do |id|
    puts "  ✓ Customer #{id}"
  end
  puts "  ... and #{publisher.published_ids.size - 10} more" if publisher.published_ids.size > 10

  puts "\n=== Use Cases ===\n"
  puts '• Syncing database records to Elasticsearch'
  puts '• Publishing updates to external APIs'
  puts '• ETL processes for data warehousing'
  puts '• Batch processing of large datasets'
  puts "\n✓ Publishing complete!"
end
