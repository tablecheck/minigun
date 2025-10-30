# Minigun - Clean Implementation

This is a clean, from-scratch implementation of the Minigun gem focused on the producer→accumulator→consumer(fork) pattern.

## Core Pattern

Minigun follows a specific pattern inspired by the original Vesper publishers:

1. **Producer**: Generates or fetches items (e.g., database IDs)
2. **Processor** (optional): Transforms items as they pass through
3. **Accumulator**: Batches items by type until thresholds are met
4. **Consumer**: Processes batches in parallel (forked processes or threads)

## Features

- ✅ Simple DSL for defining pipelines
- ✅ Automatic batching and accumulation
- ✅ Fork-based parallelism (with thread fallback on Windows)
- ✅ Thread pools for concurrent processing
- ✅ Lifecycle hooks (before_run, after_run, before_fork, after_fork)
- ✅ Configurable thresholds and concurrency

## Basic Usage

```ruby
require 'minigun'

class MyPublisher
  include Minigun::DSL

  # Configuration
  max_threads 10
  max_processes 4

  pipeline do
    # Generate items
    producer :fetch_ids do |output|
      Model.find_each do |record|
        output << record.id
      end
    end

    # Optional: transform items
    consumer :enrich do |id, output|
      output << fetch_data(id)
    end

    # Process in parallel
    consumer :process do |item|
      # This runs in forked process with thread pool
      process_item(item)
    end
  end

  # Hooks
  before_fork do
    # Disconnect database
    ActiveRecord::Base.connection_handler.clear_all_connections!
  end

  after_fork do
    # Reconnect in child
    ActiveRecord::Base.establish_connection
  end
end

# Run it
publisher = MyPublisher.new
publisher.run
```

## How It Works

### 1. Producer Thread
- Runs your producer block
- Emits items to an internal queue
- Signals completion when done

### 2. Accumulator Thread
- Receives items from producer
- Runs optional processors
- Groups items by class
- Triggers consumer when thresholds are met:
  - Single queue: 2000 items
  - All queues combined: 4000 items

### 3. Consumer (Forked Process)
- Receives batches from accumulator
- Processes items using thread pool
- On Unix: runs in forked child process
- On Windows: runs in main process with threads

## Configuration

```ruby
max_threads 10          # Threads per consumer process
max_processes 4         # Maximum concurrent forks
max_retries 3           # Retries for failed items (future)
```

## Hooks

```ruby
before_run { }    # Before pipeline starts
after_run { }     # After pipeline completes
before_fork { }   # Before forking consumer (disconnect DB)
after_fork { }    # After fork in child (reconnect DB)
```

## Thread Safety

- Uses `Concurrent::AtomicFixnum` for counters
- `SizedQueue` for producer→accumulator communication
- Thread pools from `concurrent-ruby` gem

## Platform Support

- **Unix/Linux/Mac**: Uses `fork()` for true process parallelism
- **Windows**: Falls back to thread-only mode (no fork)

## Example: Database Publisher

```ruby
class ElasticPublisher
  include Minigun::DSL

  max_threads 10
  max_processes 4

  pipeline do
    producer :fetch_ids do
      Customer.where('updated_at > ?', 1.hour.ago).find_each do |customer|
        output << [Customer, customer.id]
      end
    end

    consumer :upsert do |model_id|
      model, id = model_id
      record = model.find(id)
      record.elastic_upsert!
    end
  end

  before_fork do
    Mongoid.disconnect_clients
  end

  after_fork do
    Mongoid.reconnect_clients
  end
end
```

## Why This Pattern?

This pattern is perfect for:
- Batch processing database records
- Syncing data to external systems (Elasticsearch, etc.)
- Processing large datasets with parallelism
- Jobs that need process isolation (database connections, memory)
- Replacing background job systems for batch operations

## Differences from Other Gems

- **vs Sidekiq**: In-memory, no Redis, designed for batch operations
- **vs Parallel**: Built-in batching, accumulation, and lifecycle hooks
- **vs concurrent-ruby**: Higher-level abstractions for data pipelines

## License

MIT

