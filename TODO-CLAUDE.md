# Minigun Enhancement Plan

## Executive Summary

Minigun is a high-performance data processing pipeline framework for Ruby with support for threads, COW forks, and IPC forks. This document outlines a comprehensive enhancement plan based on the current codebase state and TODOS.md.

## Enhancement Roadmap

### Phase 1.0: Cross-Boundary Routing

- [x] **Cross-Boundary Routing** ✓ (Completed 2025-01-04)
  - [x] Remove "skip" from hanging example tests
  - [x] IPC fork getting input via `to` from various sources (IPC, COW, threads, master)
  - [x] IPC fork doing output routing
  - [x] IPC to COW, COW to IPC, IPC to master routing
  - [x] IPC/COW fan-out/fan-in patterns
  - Routing patterns
    - [x] output.to of IpcQueues - implemented via IpcRoutedOutputQueue
    - [x] cow_fork getting IPC input via to from IPC
    - [x] cow_fork getting IPC input via to from COW
    - [x] cow_fork getting IPC input via to from threads
    - [x] cow_fork getting IPC input via to from master
    - [x] cow_fork doing IPC output - COW now uses IpcOutputQueue
    - [x] ipc 2 cow, cow to ipc, ipc to master - all working
    - [x] ipc/cow fan-out/fan-in - examples 80, 81, 82, 84 working
    - [ ] routing to inner stages of pipelines
    - [ ] routing to inner stages of cow and ipc fork via an ingress delegator
  - Additional scenarios
    - [ ] test reroute with IPC/COW complex scenarios, inner routing, etc. - all tests passing
    - [ ] producers inside IPC/COW forks
    - [ ] routing with multiple forked processes - round-robin via IPC workers
    - [ ] start of IPC/COW stage should not require await - added await: true option
  - [ ] :worker_finished event seems like it should not work like it does. It resends back into the master... hmmm
  - [ ] Transmit stats across forks
  - [ ] Transmit logs across forks--look at Puma
  - [ ] Support MINIGUN_LOG_LEVEL var

### Phase 1.1: QoL Improvements

- [ ] **Graceful shutdown**
  - [ ] signal trapping, child state management/killing
  - [ ] Kill child threads/forks/ractors
  - [ ] Ctrl+C once to start graceful shutdown (send end signals from all producers)
  - [ ] Press Ctrl+C again to force quit.


- [ ] to_mermaid
- [ ] child culling (look at puma)
- [ ] supervision tree of processes
- [ ] htop-like monitoring dashboard (CLI)
- [ ] Interactive examples in web docs
- [ ] ASCII art drawing of tree
- [ ] IPC batches?
- [ ] Acks on queued items, guaranteed delivery?

- [ ] **Hooks** (fork, stage, nesting)

- [ ] Add process supervision tree?

- [ ] **IPC Reliability**
  - Address potential reliability issues with IPC
  - Add timeout handling
  - Handle pipe failures gracefully
  - Stats reporting back to parent process via IPC

- [ ] **Execution Context Improvements**
  - Implement proposed DSL:
    ```ruby
    threads(10) do ... end
    processes(10) do ... end
    ractors(10) do ... end
    thread_per_batch(max: 10) do ... end
    process_per_batch(max: 10) do ... end
    ractor_per_batch(max: 10) do ... end
    ```
#### 1.2 Error Handling & Reliability
**Priority: HIGH**

- [ ] **Comprehensive Error Handling**
  - Define error handling strategy for each executor type
  - Implement retry mechanisms with backoff
  - Add circuit breaker patterns for failing stages
  - Handle errors in hooks properly

- [ ] **Process Management**
  - Signal trapping for graceful shutdown
  - Child process state management
  - Child process culling (reference Puma's implementation)
  - Supervision tree for processes
  - Wait for last forked process to finish properly

### Phase 2: Features & Functionality (Medium Priority)

#### 2.1 New Stage Types & Operators
**Priority: MEDIUM**

- [ ] **Batch Operators**
  - `batch` - create batches from stream
  - `debatch` - flatten batches back to stream
  - `rebatch` - change batch size

- [ ] **Flush Timers**
  - Time-based batch flushing
  - Consolidate accumulator and batch logic

#### 2.2 Execution Strategies
**Priority: MEDIUM**

- [ ] **Fiber Support**
  - Add Fiber-based executor
  - Implement fiber pool
  - Add `fibers(n)` DSL method
  - Test fiber interop with other executors

- [ ] **Ractor Support** (Ruby 3.0+)
  - Complete ractor executor implementation
  - Add examples for ractor usage
  - Test ractor limitations and workarounds

#### 2.3 Routing & Connectivity
**Priority: MEDIUM**

- [ ] **Advanced Routing**
  - Weighted routing / load balancing
  - Better name resolution (local -> up the chain)
  - Routing to inner stages of pipelines (double nested)
  - Ambiguous routing error handling (error unless immediate neighbor)
  - Aliases: `produce_to_stage`, `consume_from_stage`

#### 2.4 Configuration System
**Priority: MEDIUM**

- [ ] **Configuration Infrastructure**
  - Global configuration object
  - Pipeline-level scoped limits
  - Stage-level configuration overrides
  - Configurable queue lengths per stage
  - Validation: warn if stage explicit value > global limit

- [ ] **Configuration Options**
  - `min_threads`, `max_threads`
  - `max_processes`, `max_ractors`
  - `max_retries`, `batch_size`
  - `keepalive_seconds` (nil, 0, 5, infinity)
  - Mark & sweep GC for keepalive management

#### 2.5 Hooks & Lifecycle
**Priority: MEDIUM**

- [ ] **Hook System**
  - Implement comprehensive hook DSL
  - `before_fork`, `after_fork` - currently exist, test coverage
  - `after_each_fork` - per-fork execution
  - `after_each` - generic lifecycle hook
  - `rescue_error` - error handling hook (accepts error class)
  - Hook prepending mechanism
  - Test that pipeline-level hooks apply to ALL children
  - Hooks for nesting scenarios

### Phase 3: Developer Experience (Medium Priority)

#### 3.1 Documentation
**Priority: MEDIUM**

- [ ] **README Updates**
  - Document sequential routing vs explicit routing (`to`/`from`)
  - Document parallel execution behavior
  - Document fan-out/fan-in architecture:
    - Every consumer has an input queue
    - Fan-out adds producer output queues + router (load balancer)
    - Fan-in connects producers directly to consumer queue
  - Document `emit_to_stage` direct routing
  - Document yield syntax (classes use `yield` instead of `|output|`)
  - String/symbol name handling (always convert to string)

- [ ] **Architecture Documentation**
  - Multi-parent scenarios - end of queue detection
  - Threading model vs fork model
  - Concurrent execution abstractions (ractor, thread, fork)
  - Pipeline to stage, stage to pipeline routing patterns
  - Make pipeline and DAG accessible/inspectable

- [ ] **API Documentation**
  - Document all DSL methods
  - Document stage lifecycle
  - Document executor selection criteria
  - Add more real-world examples

#### 3.2 Observability
**Priority: MEDIUM**

- [ ] **Stats & Monitoring**
  - Move stats tracking from Runner to Task
  - Make per-item latency tracking optional
  - Make stats collection optional for performance
  - IPC stats reporting back to parent
  - Verbose logging of fork events
  - Custom logging levels per stage

- [ ] **Monitoring Dashboard**
  - htop-like CLI dashboard
  - Real-time pipeline visualization
  - Stage throughput metrics
  - Queue depth monitoring
  - Worker pool utilization

- [ ] **Visualization**
  - Generate Mermaid diagrams from pipeline definition
  - DAG visualization
  - Execution flow diagrams

### Phase 4: Advanced Features (Lower Priority)

#### 4.1 Dynamic Behavior
**Priority: LOW**

- [ ] **Dynamic Scaling**
  - Auto-scale thread/process pools based on queue depth
  - Adaptive pipeline behavior
  - Dynamic stage addition/removal

- [ ] **Named Stage Keepalive**
  - Keep named stages alive for reuse
  - Keepalive timeout configurations
  - Mark & sweep GC for stage lifecycle

#### 4.2 DSL Enhancements
**Priority: LOW**

- [ ] **Control Flow Keywords**
  - `parallel` blocks for explicit parallel execution
  - `sequential`/`sequence`/`series` blocks
  - Influence DAG building based on keywords

- [ ] **Custom Stage Types**
  - Better support for custom stage classes
  - Stage class registry
  - Plugin system for third-party stages

#### 4.3 Advanced Capabilities
**Priority: LOW**

- [ ] **Pipeline Coordination**
  - Lock DAG/pipelines/task when running (prevent modification)
  - Auto-start triggers: `auto_start = false`, `trigger(:stage)`
  - Pipeline/stage introspection methods:
    ```ruby
    task.pipeline(:foo)
    task.stages(:bar)
    task.minigun.dag
    task.pipeline(:foo).stage(:bar)
    task.pipelines
    task.stages
    ```

- [ ] **Better ID Generation**
  - Replace current ID generation with better system
  - Consider format like `_jf02ASj3`
  - Ensure uniqueness across distributed scenarios

- [ ] **Input/Output Streams**
  - Harden with `InputOutputStream` abstraction
  - Unified interface for queue operations
  - Better separation of concerns

## Testing Strategy

### Test Coverage Priorities

1. **Unit Tests**
   - [ ] Stats tracking for all stage types
   - [ ] All executor types
   - [ ] Hook execution and propagation
   - [ ] Signal handling
   - [ ] Error propagation

2. **Integration Tests**
   - [ ] Cross-pipeline routing scenarios
   - [ ] Complex DAG topologies
   - [ ] All executor combinations
   - [ ] Graceful shutdown scenarios

3. **Example Tests**
   - [ ] All examples in `/examples` should have specs
   - [ ] Examples should demonstrate best practices
   - [ ] Extract more real-world use cases

## Breaking Changes to Consider

### Potential Breaking Changes (Discuss with users first)

1. **Stage Names**: Already completed (name as first arg)
2. **Executor Naming**: Consider renaming for clarity
   - `threaded` → `spawn_threads`?
   - `fork_accumulate` → `spawn_forks`?
   - `ractor_accumulate` → `spawn_ractors`?
3. **Signal System**: New signal classes may change APIs
4. **Hook System**: New hook names may conflict

## Implementation Priority

### Quarter 1: Stability
1. Stage to Worker refactoring
2. Signal system cleanup
3. Error handling improvements
4. Process management

### Quarter 2: Features
1. Batch operators
2. Fiber support
3. Configuration system
4. Hook system completion

### Quarter 3: Developer Experience
1. Documentation updates
2. Monitoring dashboard
3. Mermaid diagram generation
4. More examples

### Quarter 4: Polish
1. Dynamic scaling
2. Advanced routing
3. Performance optimizations
4. API stabilization for 1.0

## Open Questions

1. **Naming**: What should the gem be called?
   - Current: minigun
   - Alternatives: nordstream, permian (from todos)

2. **Execution Context**: Should execution contexts be implicit or explicit?
   - Risk of conflicts with base context

3. **Pipeline Locking**: Should running pipelines be immutable?
   - Pro: Safety, no race conditions
   - Con: Less flexibility for dynamic scenarios

4. **Stats Overhead**: Should stats be opt-in or opt-out?
   - Consider performance-critical scenarios

5. **Cross-Executor Routing**: How to handle IPC/COW/thread boundaries?
   - Serialization requirements
   - Performance implications

## Notes from TODOS.md

### Suss Code to Review

```ruby
# From TODOS.md - marked as suspicious
def execute(context, item: nil, _input_queue: nil, output_queue: nil)
  return unless @block
  context.instance_exec(item, output_queue, &@block)
end
```

This method should be reviewed for:
- Safety of instance_exec
- Parameter naming consistency
- Error handling

### Registry Pattern

```ruby
# From TODOS.md - registry registration pattern
pipeline_name = @pipeline.is_a?(Pipeline) ? @pipeline.name : nil
task.registry.register(self, pipeline_name: pipeline_name)
```

This pattern is already implemented but may need review.

## Success Metrics

- [ ] All tests passing on Ruby 3.0+, 3.1+, 3.2+, 3.3+
- [ ] JRuby compatibility maintained
- [ ] Documentation completeness >90%
- [ ] Example coverage for all major features
- [ ] Performance benchmarks established
- [ ] Memory leak testing automated
- [ ] Production usage in at least 3 projects

## Contributing Guidelines Needed

- [ ] CONTRIBUTING.md with development setup
- [ ] Code style guide (RuboCop configuration)
- [ ] PR template
- [ ] Issue templates
- [ ] Changelog maintenance process
- [ ] Release process documentation
