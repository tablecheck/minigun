# Minigun Quick Reference

## What is Minigun?
A Ruby framework for building high-performance parallel data pipelines with multiple execution strategies (threads, fork, IPC).

## Core Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│ Task (top-level coordinator)                                    │
│  └─ root_pipeline: Pipeline                                    │
│     ├─ stages: [Producer, Consumer, Router, ...]               │
│     ├─ dag: Directed Acyclic Graph for routing                 │
│     └─ stats: Per-stage and pipeline-level metrics             │
└─────────────────────────────────────────────────────────────────┘
       ↓
       ├─→ Runner: Manages job lifecycle, signals, statistics
       │
       └─→ Pipeline.run() creates Workers for each stage
           │
           ├─→ Producer Worker (autonomous, no input)
           │   └─→ emit(item) → OutputQueue
           │
           ├─→ Transformer Worker (streaming, executor-managed)
           │   ├─→ InputQueue.pop() consumes items
           │   ├─→ execute(item) via Executor
           │   └─→ emit(result) → OutputQueue
           │
           └─→ Consumer Worker (streaming, executor-managed)
               ├─→ InputQueue.pop() consumes items
               └─→ execute(item) processes final data
```

## Stage Lifecycle

```
1. Worker Thread Created (one per stage)
   ↓
2. StageContext Created (tracks sources, queues, stats)
   ↓
3. Executor Created (determines concurrency: thread, fork, etc.)
   ↓
4. Stage.run_stage(ctx) called
   ├─→ for Producer: emit all data, send EndOfSource
   ├─→ for Consumer: loop on InputQueue until EndOfStage
   └─→ End signals cascade to downstream stages
```

## Stage Types

| Type | Run Mode | Input | Output | Executor | Example |
|------|----------|-------|--------|----------|---------|
| **Producer** | `:autonomous` | ✗ | ✓ | None | `producer { 10.times { emit(i) } }` |
| **Processor** | `:streaming` | ✓ | ✓ | Thread/Fork | `processor { \|x\| emit(x*2) }` |
| **Consumer** | `:streaming` | ✓ | ✗ | Thread/Fork | `consumer { \|x\| puts x }` |
| **Accumulator** | `:streaming` | ✓ | ✓ | Thread/Fork | Batches N items before emit |
| **Router** | `:streaming` | ✓ | ✓ | None | Auto-inserted for fan-out |
| **Pipeline** | `:composite` | ✓ | ✓ | Special | Wraps nested pipeline |

## Execution Strategies

```
Thread Pool (:thread)           COW Fork (:cow_fork)         IPC Fork (:ipc_fork)
└─ Concurrency: Threads        └─ Concurrency: Processes   └─ Concurrency: Processes
   Shared memory                  Copy-On-Write memory        IPC pipes
   GVL limited                    No GVL                      Data serialized
   Best: I/O-bound                Best: CPU w/ large data     Best: CPU long-running
```

## Key Data Structures

### DAG (Routing Graph)
```ruby
dag.add_edge(stage_a, stage_b)  # Producer → Consumer
dag.upstream(stage)              # All sources
dag.downstream(stage)            # All sinks
dag.validate!                     # Cycle detection
```

### Stats Tracking
```ruby
stats = pipeline.stats
stats.for_stage(stage).items_produced
stats.for_stage(stage).items_consumed
stats.bottleneck()               # Slowest stage
stats.throughput                 # items/second
```

### Queues
```ruby
Queue → SizedQueue(1000 default) → InputQueue → ConsumerStage
  ↑                                              ↓
  └─ emit(item) from Producer          pop() loops until EndOfStage
```

## Termination Protocol

```
Producer.execute() completes
    ↓ send_end_signals()
    ↓ EndOfSource to all downstreams
InputQueue.pop() receives EndOfSource from ALL upstreams
    ↓ returns EndOfStage sentinel
ConsumerStage.execute() breaks from loop
    ↓ send_end_signals()
    ↓ cascade continues downstream
```

## Queue Communication

```
emit(item)
    ↓
OutputQueue → downstream_queues[*]
    ↓
SizedQueue (bounded, provides backpressure)
    ↓
InputQueue.pop() → item
    ↓
executor → Thread.new { execute(item) }
    ↓
emit(result) → next stage's queues
```

## Monitoring Integration Points

### 1. **Poll-based** (Non-intrusive)
```ruby
stats = pipeline.stats
puts "Throughput: #{stats.throughput} items/s"
puts "Bottleneck: #{stats.bottleneck.stage_name}"
```

### 2. **Callback-based** (Clean)
```ruby
# Add hooks to Runner/Pipeline
on_statistics_update { |stats| hud.update(stats) }
on_stage_complete { |stage, stats| hud.mark_done(stage) }
```

### 3. **Direct Access** (Simple)
```ruby
result = runner.run
stats = task.root_pipeline.stats
# Access metrics after execution
```

## Key Metrics for HUD

**Per-Stage:**
- `items_produced` - total items emitted
- `items_consumed` - total items processed
- `throughput` - items/second (derived)
- `latency_samples` - p50, p95, p99 latency
- `start_time`, `end_time`

**Pipeline-level:**
- `total_produced` - total items from all stages
- `total_consumed` - total items processed
- `bottleneck()` - slowest stage
- `throughput` - overall items/second
- `runtime` - end_time - start_time

## Project Structure

```
lib/minigun/
├── minigun.rb              # Module entry, Platform.fork check
├── pipeline.rb             # DAG management, stage orchestration
├── stage.rb                # Stage hierarchy (Producer/Consumer/Router)
├── worker.rb               # Thread wrapper, lifecycle
├── runner.rb               # Job lifecycle, signal handling
├── task.rb                 # Top-level coordinator
├── dag.rb                  # Graph w/ TSort
├── stats.rb                # Per-stage metrics (atomic counters, latency)
├── queue_wrappers.rb       # InputQueue/OutputQueue abstractions
├── dsl.rb                  # User-facing DSL
├── execution/
│   └── executor.rb         # Concurrency strategies
└── signal.rb               # Signal objects (EndOfSource, EndOfStage)

examples/                   # 100+ example pipelines
spec/                       # Tests
```

## Critical Concepts

### Bottleneck
The stage with minimum throughput limits overall performance:
```
Pipeline throughput = min(stage.throughput for all stages)
```

### Backpressure
Automatic flow control via bounded queues:
```
Producer fast → OutputQueue fills (SizedQueue max=1000)
             → emit() blocks waiting for consumer
             → Consumer catches up → queue drains
```

### Dynamic Routing
Route items to stages without DAG connection:
```ruby
output.to(:specific_stage, item)  # Send to specific stage
output.to(:other_stage) << item    # Alternative syntax
```

### Run Modes
Determines stage behavior:
- `:autonomous` - generates data (Producer)
- `:streaming` - processes queue items (Consumer/Router)
- `:composite` - manages nested pipeline (PipelineStage)

## Common Patterns

### Simple ETL
```ruby
producer :extract { data.each { emit(_1) } }
processor :transform { |x| emit(transform(x)) }
consumer :load { |x| database.insert(x) }
```

### Parallel Processing
```ruby
producer :source { data.each { emit(_1) } }
processor :heavy, threads: 8 { |x| emit(expensive(x)) }
consumer :store { |x| cache.set(x) }
```

### Branching (Fan-out)
```ruby
producer :source, to: [:branch_a, :branch_b] { data.each { emit(_1) } }
processor :branch_a { |x| emit(path_a(x)) }
processor :branch_b { |x| emit(path_b(x)) }
```

### Batching
```ruby
producer :source { items.each { emit(_1) } }
accumulator :batch, max_size: 100 { |item| emit(item) }
consumer :process { |batch| process_batch(batch) }
```

## API Glossary

### Pipeline Methods
- `add_stage(type, name, options, &block)` - Register stage
- `run(context, job_id: nil)` - Execute pipeline
- `build_dag_routing!()` - Validate DAG
- `find_stage(name)` - Lookup stage

### Stage Methods
- `run_mode()` - Returns `:autonomous`, `:streaming`, `:composite`
- `execute(context, input_queue, output_queue, stats)` - Process items
- `emit(item)` - Send item downstream (via output_queue)
- `queue_size()` - Get configured queue size

### Worker Methods
- `start()` - Create execution thread
- `join()` - Wait for completion

### Stats Methods
- `for_stage(stage)` - Get stage stats
- `throughput()` - items/second
- `bottleneck()` - Slowest stage
- `increment_produced(count)` - Atomic counter

### Executor Methods
- `execute_stage(stage, context, input_queue, output_queue)` - Concurrently execute
- `shutdown()` - Cleanup resources

## File Locations

**Architecture Files** (5 critical files):
1. `/lib/minigun.rb` - Module setup
2. `/lib/minigun/pipeline.rb` - DAG & orchestration
3. `/lib/minigun/stage.rb` - Stage types
4. `/lib/minigun/worker.rb` - Thread lifecycle
5. `/lib/minigun/execution/executor.rb` - Concurrency strategies

**Supporting Files**:
- `dag.rb` - Routing graph
- `stats.rb` - Metrics
- `runner.rb` - Job lifecycle
- `task.rb` - Top-level coordinator
- `queue_wrappers.rb` - Queue abstractions
- `dsl.rb` - User DSL

