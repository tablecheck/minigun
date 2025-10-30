# Fork Executors in Minigun

Minigun provides two fork-based execution strategies for processing pipeline stages in separate processes.

## COW Fork Pool Executor

### Overview
The **Copy-On-Write (COW) Fork Pool Executor** maintains a pool of forked processes where each process handles a single item then exits. It leverages Ruby's copy-on-write memory optimization.

### How It Works
1. Items flow into the stage's input queue
2. Executor forks a new process for each item (up to `max_size` concurrent forks)
3. Child process inherits parent's memory via COW (no serialization for input)
4. Child processes the item and sends result back via IPC pipe
5. Child exits immediately after processing
6. Parent reaps completed children, reads results via IPC, and forks for new items

### Memory Model
- **Copy-On-Write**: Memory pages are shared between parent and child until modified
- **No Serialization for Input**: Input item is accessible directly in forked process via COW
- **IPC for Results**: Results and errors are returned to parent via IPC pipes (Marshal serialization)
- **Ephemeral Workers**: Each fork handles one item then exits

### Concurrency
- Up to `max_size` concurrent forked processes
- Pool management: automatically reaps completed forks and spawns new ones
- Non-blocking: continues forking as capacity allows

### Best For
- Read-heavy operations on large shared data structures
- Processing where data doesn't need modification
- Scenarios where forking overhead is acceptable
- Memory efficiency with minimal data modification

### Example
```ruby
class DataProcessor
  include Minigun::Task

  execution :cow_fork, max: 4

  def initialize
    @large_dataset = load_huge_dataset()  # Shared via COW
  end

  pipeline do
    producer :generate do |output|
      items.each { |item| output << item }
    end

    processor :process_with_cow do |item|
      # Child process can read @large_dataset without serialization
      @large_dataset.lookup(item[:key])
    end
  end
end
```

## IPC Fork Pool Executor

### Overview
The **Inter-Process Communication (IPC) Fork Pool Executor** creates persistent worker processes that communicate with the parent via pipes. Workers continuously process items throughout the pipeline's lifetime.

### How It Works
1. At stage startup, fork `max_size` persistent worker processes
2. Create bidirectional IPC pipes for each worker
3. Parent pulls items from input queue
4. Parent distributes items to workers round-robin via IPC pipes (Marshal serialization)
5. Workers receive serialized items, process them, send results back via IPC pipes
6. Parent receives results via IPC and pushes to output queue
7. Workers persist until pipeline completes (graceful shutdown)

### Memory Model
- **Process Isolation**: Each worker has independent memory
- **Explicit IPC**: All data (input and output) serialized through pipes using Marshal
- **Persistent Workers**: Processes stay alive, handle multiple items

### Concurrency
- Exactly `max_size` worker processes created at startup
- Round-robin work distribution
- Synchronous processing per worker (workers handle one item at a time)
- Parent coordinates all queue interaction

### Best For
- Strong process isolation requirements
- Independent processing where memory sharing isn't needed
- Long-running operations where fork overhead matters
- When you need persistent worker state
- Scenarios requiring explicit error boundaries

### Example
```ruby
class ApiProcessor
  include Minigun::Task

  execution :ipc_fork, max: 8

  pipeline do
    producer :fetch_jobs do |output|
      jobs.each { |job| output << job }
    end

    processor :call_api do |job|
      # Each worker maintains its own HTTP connection pool
      # Processes are isolated - errors don't affect siblings
      api_client.process(job)
    end
  end
end
```

## Comparison

| Feature | COW Fork Pool | IPC Fork Pool |
|---------|---------------|---------------|
| **Worker Lifetime** | Ephemeral (1 item) | Persistent (entire stage) |
| **Input Communication** | COW (no serialization) | IPC pipes (Marshal) |
| **Output Communication** | IPC pipes (Marshal) | IPC pipes (Marshal) |
| **Memory Sharing** | Yes (COW for input) | No (isolated) |
| **Serialization** | Results only (via IPC) | Input & output (via IPC) |
| **Fork Overhead** | High (per item) | Low (once at startup) |
| **Process Isolation** | Moderate (shared input) | Strong (isolated) |
| **Best Use Case** | Large shared read-only data | Independent isolated processing |
| **Concurrency Model** | Pool of ephemeral forks | Pool of persistent workers |
| **Result Communication** | IPC pipes | IPC pipes |

## Implementation Details

### Shared Architecture
Both `CowForkPoolExecutor` and `IpcForkPoolExecutor` inherit from `AbstractForkExecutor`, which provides:
- Common IPC result communication logic via pipes
- Error handling and propagation from child to parent
- Marshal-based serialization for results and errors
- Protocol: `{ type: :result/:error/:no_result, ... }` messages

### COW Fork Pool
- Uses `Process.fork` for each item
- Tracks active PIDs in a hash
- Non-blocking reap with `Process.wait2(..., Process::WNOHANG)`
- Respects pool size limit before forking
- Input item shared via COW (read-only access)
- Results sent back via IPC pipe (inherited from `AbstractForkExecutor`)
- Each child exits immediately after processing one item

### IPC Fork Pool
- Pre-forks workers at stage startup
- Creates bidirectional pipes (`IO.pipe`) for each worker
- Input items serialized and sent via IPC (`{ type: :item, item: ... }`)
- Results sent back via IPC pipe (inherited from `AbstractForkExecutor`)
- Message protocol: `{ type: :item/:result/:error/:shutdown, ... }`
- Round-robin distribution from parent to workers
- Synchronous request/response per item
- Graceful shutdown with explicit shutdown signals

## Usage

Both executors can be configured at the task level:

```ruby
class MyTask
  include Minigun::Task

  # Use COW fork
  execution :cow_fork, max: 4

  # Or use IPC fork
  execution :ipc_fork, max: 4
end
```

## Platform Support

Both fork executors require `Process.fork` support:
- ✅ Supported: Linux, macOS, Unix-like systems
- ❌ Not supported: Windows (falls back to inline execution)

## Inspired By

- **Puma's Fork Worker Mode**: IPC implementation inspired by Puma's persistent worker processes with IPC coordination
- **Unicorn**: COW fork pattern inspired by forking per request with memory sharing
- **Unix Process Model**: Classic fork/exec patterns adapted for data pipeline processing

