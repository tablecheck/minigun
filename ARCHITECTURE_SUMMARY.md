# Minigun Codebase Architecture Summary

## 1. What is Minigun?

**Minigun** is a high-performance data processing pipeline framework for Ruby that enables building complex, parallel data workflows with multiple execution strategies. It's positioned as a potential replacement for queue systems like Resque, Sidekiq, or Solid Queue.

### Key Characteristics:
- **Ruby-native**: Runs entirely in Ruby's memory (no external DB/infrastructure)
- **Multi-execution strategies**: Supports inline, threaded, COW fork, and IPC fork execution
- **DSL-based**: Simple, expressive domain-specific language for defining pipelines
- **Parallel & distributed**: Handles both thread-level and process-level concurrency
- **Advanced routing**: Supports DAG-based routing with fan-in, fan-out, and dynamic routing
- **Nested pipelines**: Can compose pipelines within stages (composite pattern)

---

## 2. Core Components

### A. **Pipeline** (`/lib/minigun/pipeline.rb`)
The orchestrator of all stages within a context. Manages:
- Stage registry and lifecycle
- DAG (Directed Acyclic Graph) for stage connections
- Queue creation and management
- Hook execution (before_run, after_run, before_fork, after_fork)
- Statistics aggregation

**Key Methods:**
- `add_stage()` - Register stages with routing
- `run()` - Execute the pipeline
- `build_dag_routing!()` - Construct and validate the routing graph
- `find_stage()` - Locate stages by name or reference

### B. **Stage** (`/lib/minigun/stage.rb`) - Base Class
Base class for all execution units. Three primary subclasses:

#### **1. ProducerStage** (run_mode: `:autonomous`)
- Generates initial data for pipeline
- No input, only output
- Executes once per run
- Example: `producer :fetch_urls { urls.each { |url| emit(url) } }`

#### **2. ConsumerStage** (run_mode: `:streaming`)
- Processes stream of items from input queue
- Loops until no more items (EndOfStage signal)
- Can optionally emit to downstream stages
- Includes AccumulatorStage subclass for batching

#### **3. RouterStage** (run_mode: `:streaming`)
- Internal stages for fan-out patterns (auto-inserted)
- `RouterBroadcastStage`: Sends item to ALL downstream
- `RouterRoundRobinStage`: Distributes items round-robin across downstream

#### **Special Types:**
- **PipelineStage**: Wraps and executes nested pipelines (composite pattern)
- **ExitStage**: Auto-created for nested pipeline outputs
- **AccumulatorStage**: Batches N items before emitting

### C. **Worker** (`/lib/minigun/worker.rb`)
Thread wrapper for each stage execution:
- One Worker thread per Stage
- Creates StageContext and Executor
- Handles disconnected stage detection
- Manages stage lifecycle (start, run, shutdown)
- Tracks statistics per stage

### D. **Executor** (`/lib/minigun/execution/executor.rb`)
Defines HOW stages execute (concurrency model):

| Executor | Concurrency | Process Model | Serialization | Use Case |
|----------|-------------|---------------|---------------|----------|
| **InlineExecutor** | None | Single thread | N/A | Debug, trivial ops |
| **ThreadPoolExecutor** | Threads | Single process | None (shared memory) | I/O-bound work |
| **CowForkExecutor** | Processes | Fork per item | None (COW memory) | CPU-intensive, large data |
| **IpcForkExecutor** | Processes | Persistent workers | Marshal/MessagePack | CPU-intensive, long-running |

### E. **DAG** (`/lib/minigun/dag.rb`)
Directed Acyclic Graph for stage routing:
- Nodes: Stage objects
- Edges: Data flow connections
- Uses TSort for cycle detection and topological sort
- Methods: `downstream()`, `upstream()`, `terminal?()`, `source?()`

### F. **Task** (`/lib/minigun/task.rb`)
Top-level coordinator:
- Holds root pipeline and configuration
- Manages stage registry for name resolution
- Tracks queue registry (Stage => Queue mappings)
- Handles IPC pipe lifecycle for cross-stage coordination

### G. **Runner** (`/lib/minigun/runner.rb`)
Job execution lifecycle manager:
- Signal handling (SIGINT, SIGTERM, SIGQUIT)
- Statistics collection and reporting
- Graceful shutdown
- Job lifecycle hooks

### H. **Statistics** (`/lib/minigun/stats.rb`)
Performance monitoring:
- Per-stage counters (produced, consumed, failed items)
- Latency sampling (reservoir sampling for memory efficiency)
- Bottleneck detection (identifies slowest stage)
- Throughput calculation

### I. **Queue Wrappers** (`/lib/minigun/queue_wrappers.rb`)
Input/Output abstraction layers:
- **InputQueue**: Consumes EndOfSource signals, tracks upstream completion
- **OutputQueue**: Routes items to multiple downstream queues, handles dynamic routing

---

## 3. Execution & Processing Model

### A. **Stage Execution Lifecycle**

```
1. Worker.start() creates a Thread
   ↓
2. Worker.run() creates StageContext
   ↓
3. Executor created (inline, thread pool, fork pool, etc.)
   ↓
4. Stage.run_stage(stage_ctx) executes
   ↓
5. Stage.execute() called with (context, input_queue, output_queue)
   ↓
6. send_end_signals() notifies downstream when complete
```

### B. **Run Modes**

Each stage has a `run_mode` that determines its behavior:

- **`:autonomous`** (ProducerStage)
  - No input, generates data independently
  - Runs once per pipeline execution
  - No executor needed

- **`:streaming`** (ConsumerStage, RouterStage)
  - Processes items from input queue in a loop
  - Continues until EndOfStage signal
  - Uses executor for concurrency control

- **`:composite`** (PipelineStage)
  - Wraps and manages nested pipeline
  - Delegates to nested pipeline's run()
  - Transparent to parent pipeline

### C. **Data Flow & Queueing**

```
Producer (autonomous)
    ↓ emit(item)
OutputQueue → SizedQueue(default 1000) → InputQueue
    ↓
Executor (thread pool, fork pool, etc.)
    ↓
ConsumerStage processes item
    ↓ emit(result)
OutputQueue → downstream queues
```

**Queue Management:**
- Each stage (except producers) has input queue
- Bounded queues (SizedQueue) by default for backpressure
- Unbounded queues available via `queue_size: 0` or `Float::INFINITY`
- Global default: `Minigun.default_queue_size` (1000)

### D. **Termination Protocol**

```
Producer: emits all items, calls stage.end_signals()
    ↓ EndOfSource signal
Downstream InputQueue: collects EndOfSource from all upstreams
    ↓ returns EndOfStage sentinel
ConsumerStage: breaks from loop, calls stage.end_signals()
    ↓ EndOfSource to its downstreams
...continues cascade...
```

### E. **Process/Thread Models**

#### **Thread Pool** (`:thread`)
- Multiple threads in single process
- Shared memory (no serialization)
- Subject to GVL (Ruby Global VM Lock)
- Best for I/O-bound work

#### **COW Fork** (`:cow_fork`)
- Forks new process per item
- Copy-on-Write memory sharing (read-only data shared until modification)
- True parallelism (no GVL)
- Memory cleaned up on process exit
- Best for CPU-intensive work with large read-only data

#### **IPC Fork** (`:ipc_fork`)
- Spawns persistent worker processes
- Inter-Process Communication via pipes
- Data serialized (Marshal or MessagePack)
- Workers reused across multiple items
- Best for CPU-intensive, long-running operations

---

## 4. Project Structure

```
/mnt/c/workspace/minigun/
├── lib/minigun/
│   ├── minigun.rb                    # Main entry point, module definition
│   ├── configuration.rb              # Configuration management
│   ├── pipeline.rb                   # Pipeline orchestrator
│   ├── stage.rb                      # Stage hierarchy (Producer, Consumer, Router, etc.)
│   ├── worker.rb                     # Worker thread wrapper
│   ├── runner.rb                     # Job lifecycle manager
│   ├── task.rb                       # Top-level task coordinator
│   ├── dag.rb                        # Directed Acyclic Graph for routing
│   ├── queue_wrappers.rb             # InputQueue, OutputQueue abstractions
│   ├── stats.rb                      # Performance statistics
│   ├── signal.rb                     # Signal handling utilities
│   ├── stage_registry.rb             # Stage name resolution
│   ├── version.rb                    # Version info
│   ├── execution/
│   │   └── executor.rb               # Executor strategies (Inline, Thread, Fork, IPC)
│   └── dsl.rb                        # DSL for defining pipelines
├── examples/                         # ~100 example pipelines
├── spec/                             # Tests
├── README.md                         # Comprehensive documentation
└── Gemfile                           # Dependencies
```

### Key Files for Understanding Architecture:
1. **`lib/minigun.rb`** - Module setup, entry point
2. **`lib/minigun/pipeline.rb`** - DAG building, routing, stage management
3. **`lib/minigun/stage.rb`** - Stage types and execution interface
4. **`lib/minigun/worker.rb`** - Thread lifecycle and executor creation
5. **`lib/minigun/execution/executor.rb`** - Concurrency strategies

---

## 5. Where Would a Monitoring/HUD Tool Fit?

### A. **Integration Points**

A monitoring/HUD tool can integrate at multiple levels:

#### **1. Statistics Hook (Non-intrusive)**
```ruby
# Hook into AggregatedStats object
stats = pipeline.stats
  
# Access per-stage metrics:
- stats.for_stage(stage).items_produced
- stats.for_stage(stage).items_consumed
- stats.for_stage(stage).latency_samples
- stats.bottleneck()  # Returns slowest stage

# Access pipeline-level metrics:
- stats.throughput         # items/second
- stats.total_produced     # total items emitted
- stats.total_consumed     # total items processed
```

#### **2. Callback System (Recommended)**
Add periodic callbacks to Runner/Pipeline:
```ruby
class MonitoringTask
  include Minigun::Task
  
  # Could add periodic telemetry
  on_statistics_update do |stats|
    # Update HUD display with current stats
    hud.update(stats)
  end
  
  # Hook into stage completion
  on_stage_complete do |stage, stage_stats|
    hud.mark_stage_complete(stage.name, stage_stats)
  end
end
```

#### **3. Direct Stats Access (Simple)**
```ruby
runner = Minigun::Runner.new(task, context)
result = runner.run

# After execution, query stats:
stats = task.root_pipeline.stats
puts "Pipeline bottleneck: #{stats.bottleneck.stage_name}"
puts "Throughput: #{stats.throughput} items/s"
puts "Total runtime: #{stats.end_time - stats.start_time}s"
```

### B. **Real-time Monitoring Architecture**

```
┌─────────────────────────────────────┐
│  Pipeline Execution                 │
│  (produces events/metrics)          │
└────────────┬────────────────────────┘
             │
             ├─→ Stats Object (in-memory counters)
             │   - per-stage metrics
             │   - latency samples
             │   - throughput
             │
             ├─→ Event Log (optional)
             │   - stage started/completed
             │   - errors/retries
             │   - dynamic routing events
             │
             └─→ Reporter Thread (optional)
                 - polls stats periodically
                 - sends to HUD/dashboard
                 - formats for display
```

### C. **Available Observability Data**

**Per-Stage Metrics:**
- Items produced/consumed/failed
- Latency percentiles (p50, p95, p99)
- Throughput (items/second)
- Start/end times
- Queue depths

**Pipeline-level Metrics:**
- Total runtime
- Total throughput
- Bottleneck identification
- DAG visualization
- Memory usage (via Process.mem or GC stats)

**Worker/Thread Metrics:**
- Active thread count
- Active process count
- Queue fill levels
- Backpressure events

### D. **Recommended HUD Integration Approach**

1. **Polling-based (simplest)**
   - Background thread polls `pipeline.stats` every 100ms
   - Updates terminal display or web dashboard
   - Zero changes to core pipeline code

2. **Callback-based (flexible)**
   - Add hooks to pipeline lifecycle
   - `on_stage_complete`, `on_statistics_update`
   - HUD subscribes to relevant events

3. **WebSocket-based (real-time)**
   - Worker thread publishes stats to WebSocket server
   - Web frontend subscribes and updates live
   - Could serve web UI on separate port

### E. **Key Classes to Extend/Hook**

- **`Stats`** (`lib/minigun/stats.rb`) - All metrics live here
- **`Runner`** (`lib/minigun/runner.rb`) - Already has lifecycle hooks
- **`Worker`** (`lib/minigun/worker.rb`) - Could add stage lifecycle callbacks
- **`Pipeline`** (`lib/minigun/pipeline.rb`) - Could expose metrics endpoint

### F. **Example HUD Data Format**

```
╔════════════════════════════════════════════════════════════╗
║  Pipeline: etl_processor  [Runtime: 45.2s]                ║
╠════════════════════════════════════════════════════════════╣
║ Stage              │ In Queue │ Out Queue │ Throughput    ║
├────────────────────┼──────────┼───────────┼───────────────┤
║ producer           │        - │       234 │  5.2 items/s  ║
║ transform    ◀──── │      234 │       189 │  4.2 items/s  ║  BOTTLENECK
║ accumulate         │       45 │        19 │  0.4 batches/s║
║ process_batch      │       19 │        19 │  0.4 items/s  ║
╠════════════════════════════════════════════════════════════╣
║ Overall: 234 items, 5.2 items/s avg throughput            ║
║ Bottleneck: transform (4.2 items/s)                       ║
╚════════════════════════════════════════════════════════════╝
```

---

## 6. Key Architecture Principles

### A. **Separation of Concerns**
- **Stage**: WHAT to do (business logic)
- **Executor**: HOW to do it (concurrency strategy)
- **Worker**: WHO manages it (thread wrapper)
- **Pipeline**: WHERE it routes (DAG/routing)

### B. **Composite Pattern**
- PipelineStage wraps nested pipelines
- Treats pipelines as stages
- Enables hierarchical composition

### C. **Queue-Based Communication**
- All inter-stage communication via queues
- Enables process isolation (IPC fork)
- Backpressure through bounded queues
- Dynamic routing via output.to() method

### D. **Signal-Based Termination**
- EndOfSource signals track upstream completion
- EndOfStage signals indicate downstream readiness
- Cascade prevents deadlocks

### E. **DAG-Driven Routing**
- All connections declared in DAG before execution
- Enables cycle detection
- Supports topological sort for scheduling
- Forward references resolved before run

---

## 7. Data Flow Example

### Simple Pipeline: Producer → Transformer → Consumer

```
1. Pipeline.run() creates Workers for each stage
2. ProducerStage Worker thread executes:
   - create_output_queue(downstream: [Transformer])
   - execute() called with output_queue
   - emit(5) writes to output_queue
   - stage.end_signals() writes EndOfSource

3. TransformerStage Worker thread executes:
   - create_input_queue(upstream: [Producer])
   - create_output_queue(downstream: [Consumer])
   - InputQueue.pop() returns 5
   - execute(5) called
   - emit(5*2) writes 10 to output_queue
   - loop continues until EndOfStage

4. ConsumerStage Worker thread executes:
   - create_input_queue(upstream: [Transformer])
   - InputQueue.pop() returns 10, 20, 30, ...
   - execute(item) called for each
   - loop breaks on EndOfStage
   - stage.end_signals() (no downstream)
```

---

## 8. Critical Concepts for Monitoring

### A. **Bottleneck Detection**
The stage with minimum throughput limits overall pipeline throughput:
```
Bottleneck = min(stage.throughput for each stage)
```

### B. **Backpressure**
When consumer slower than producer:
- Producer's output_queue fills up
- SizedQueue blocks producer on write
- Automatically regulates flow

### C. **Latency**
Per-item processing time, tracked via reservoir sampling to avoid memory explosion.

### D. **Queue Depth**
Indicator of backpressure:
- Growing queue = upstream faster than downstream
- Empty queue = stages well-balanced

---

## Summary Table

| Component | Purpose | Key Methods/Attributes |
|-----------|---------|----------------------|
| **Pipeline** | Orchestrate stages & routing | `run()`, `add_stage()`, `dag`, `stats` |
| **Stage** | Business logic unit | `run_mode`, `execute()`, `emit()` |
| **Worker** | Thread wrapper for stage | `run()`, `join()`, create executor |
| **Executor** | Concurrency strategy | `execute_stage()`, `shutdown()` |
| **DAG** | Routing graph | `upstream()`, `downstream()`, `validate!()` |
| **Task** | Top-level coordinator | `root_pipeline`, `stage_registry`, `find_queue()` |
| **Stats** | Performance metrics | `throughput()`, `bottleneck()`, `latency_samples` |
| **Runner** | Job lifecycle | `run()`, signal handling, reporting |

