
ADD to README / DOCS:
- stages route to each other sequentially, unless you add :to or :from keywords
- execute in paralle, and do NOT route to each other, unless unless you add :to or :from keywords.

- every consumer has an input queue
- if there is fan-out (multiple consumers for any 1 producer), add producer output queues and an intermediate router (load balancer) object. the router has an input queue and round-robin allocates to the consumers.
- fan-in without fan-out (i.e. a producer connects to 1 consumer, even if MULTIPLE producers connect to that consumer) is done by directly having the producer insert to the consumer's queue
- emit_to_stage emits DIRECTLY to the consumer input queue

add to architecture
- multi-parents --> how do we know end of queues?

========================================================================================

yield instead of |output|

=============================================

Support Cross-Pipeline Routing?
- use stage identifiers instead of names?
- Yes! We'd need to:
- Build a global queue registry in Task or Runner that includes ALL stages from ALL pipelines
- Pass this global registry to OutputQueue instead of just local stage_input_queues
- Handle END signals across pipelines (more complex - need to track which pipelines are done)
- Something like:

  task.pipeline(:foo)
  task.stages(:bar)

  task.minigun.dag


  task.pipeline(:foo).stage(:bar)
  task.pipelines
  task.stages

===============================================

fix DataProcessingPipeline spec
I see the issue now - when you're inside a pipeline block, the stages within it are part of a PipelineStage which doesn't support output.to(). The output parameter is just an Array for collecting items, not an OutputQueue.

====================================

This method looks suss:

    def execute(context, item: nil, _input_queue: nil, output_queue: nil)
      return unless @block

      context.instance_exec(item, output_queue, &@block)
    end

============================

- flush timers on batch
- consolidate accumulator and batch

=========================

- signal trapping, child state management/killing
- child culling (look at puma)

============================

- mermaid diagrams

===========================

- IPC Fork

==========================

- fibers

=======================

ProcessPoolExecutor --> cow_fork

================================

configs
- configurable queue length

=====================================

hooks

===============================

signals
result.is_a?(Hash) && result.key?(:item) && result.key?(:target)
--> tmake this a signal

====================================

error handling

=============================

weighted routing (load balancing)

==================================

- config
- hooks
- readme
- ractors
- fibers

==================================

stats needs IPC back to parent
are there reliability issues with IPC
consider threading model vs fork model, we have lots of thread spawn/join we need an abstraction for concurrent execution -- ractor, thread, fork

-----------------------------------------------

pipeline to stage
stage to pipeline
pipeline from stage
stage from pipeline

-------------------------------------------------

ipc, process, etc. for childs in dag

pipeline routing to a stage inside another pipeline double nested

emit_to_stage
consume_from_stage
produce as an alias to emit
produce_to_stage


move stats tracking from runner to task

verbose logging of fork, etc

logging of

custom stage types



wait for last forked process to finish

hooks or lifecycle
hooks prepend

- options
  - min_threads
  - max_threads
  - max_processes
  - max_ractors

- execution summary clean output
- print dag to mermaid


  -
  - use IPC to transmit back to parent process


Now in the DSL lets make producer method validate that block arity is zero
consumer validate that block arity >= 1
processor is alias to consumer

then add specs for the same



Strategies:
Stream (continuous): :threaded, :fork_ipc, :ractor
Spawn (per batch): :spawn thread, :spawn_fork, :spawn_ractor


auto_start = false
trigger(:stage)


      # Backward compatibility aliases
      alias fork_accumulate spawn_fork
      alias cow_fork spawn_fork
      alias ipc_fork consumer  # ipc_fork was just a consumer with different execution
SpawnFork
SpawnRactor
threaded --> spawn_threads
ractor_accumulate --> spawn_ractors
fork_accumulate --> spawn_forks

----------------------------

these should be pipeline-level scoped limits (or global if at root_pipeline)

  max_threads: config[:max_threads] || 5,
  max_processes: config[:max_processes] || 2,
  max_retries: config[:max_retries] || 3,

they should constrain child events, BUT we should allow at least one thread/process for each stage, and log a warning once if the stage has an explicit value set but it's constrained by the global limit

------------------------------

let's think about the hooks DSL

  # Pipeline-level fork hooks (apply to all consumers)
  before_fork do
    disconnect_database!
  end

  after_fork do
    reconnect_database!
  end

test that this applies to ALL children in the pipeline
- after_each_fork???
- after_each??
- rescue_error ?
- :class, error or standard error
