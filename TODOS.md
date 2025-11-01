
ADD to README / DOCS:
- stages route to each other sequentially, unless you add :to or :from keywords
- execute in parallel, and do NOT route to each other, unless you add :to or :from keywords.

- every consumer has an input queue
- if there is fan-out (multiple consumers for any 1 producer), add producer output queues and an intermediate router (load balancer) object. the router has an input queue and round-robin allocates to the consumers.
- fan-in without fan-out (i.e. a producer connects to 1 consumer, even if MULTIPLE producers connect to that consumer) is done by directly having the producer insert to the consumer's queue
- emit_to_stage emits DIRECTLY to the consumer input queue

add to readme: Classes use yield instead of |output|

add to architecture
- multi-parents --> how do we know end of queues?

========================================================================================

TODO: Refactor so more things are moved from Stage to Worker, e.g.
- queue creation
- start/end stats tracking (need tests for all stage types) -- make some stages silent?
- error catching
- sending of end signals?
- rename #run_worker_loop as its not a loop. Maybe #run_in_worker? other ideas? --> DONE: renamed to #run_stage

=======================================

@stage_name == :_entrance and :_exit (YUCK)

================================

This needs to be in all stage:

stage_stats = stage_ctx.stage_stats
stage_stats.start!
log_info(stage_ctx, 'Starting')

====================

batch / debatch / rebatch operators

=======================

cleanup signal
+ break if item.is_a?(AllUpstreamsDone)
+ break if item.is_a?(Message) && item.end_of_stream?

====================

make pipeline and dag accessible

=============

names:
- nordstream
- permian
- ???

======================

fiber
fibers(10) do <-- all childs within fiber scope. should threads be joined within fiber scope?

thread
threads(10) do

cow_fork
cow_forks(10) do # creates a pipeline
end

ipc_fork
ipc_forks(10) do # creates a pipeline

ractors
=

=====================================================

think about potential for conflicts with the base context

thread_pool
cow_fork_pool


      # Execution block methods
      def threads(pool_size, &)
        context = { type: :threads, pool_size: pool_size, mode: :pool }
        _with_execution_context(context, &)
      end

      def processes(pool_size, &)
        context = { type: :cow_forks, pool_size: pool_size, mode: :pool }
        _with_execution_context(context, &)
      end

      def ractors(pool_size, &)
        context = { type: :ractors, pool_size: pool_size, mode: :pool }
        _with_execution_context(context, &)
      end

      def thread_per_batch(max:, &)
        context = { type: :threads, max: max, mode: :per_batch }
        _with_execution_context(context, &)
      end

      def process_per_batch(max:, &)
        context = { type: :cow_forks, max: max, mode: :per_batch }
        _with_execution_context(context, &)
      end

      def ractor_per_batch(max:, &)
        context = { type: :ractors, max: max, mode: :per_batch }
        _with_execution_context(context, &)
      end


===============================

dynamic scaling

==============================

parallel and sequential/sequence/series keywords --> influences DAG building

==============================

make per item latency tracking optional (and stats?)

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

- hooks (fork, stage, nesting)
- output.to of IpcQueues
- Fork/Thread etc should create an implicit pipeline
- cow_fork getting IPC input via to from IPC
- cow_fork getting IPC input via to from COW
- cow_fork getting IPC input via to from threads
- cow_fork getting IPC input via to from master(?)
- cow_fork doing IPC output
- ipc 2 cow, cow to ipc, ipc to master
- ipc/cow fan-out/fan-in
- routing to inner stages of pipelines
- routing to inner stages of cow and ipc fork via an ingress delegator

===================================

        # Skip router stages - they're added during insert_router_stages_for_fan_out
        # which happens before validation, so they should exist
        next if node_name.to_s.end_with?('_router')

        # Skip internal stages that are created dynamically
        next if node_name == :_entrance || node_name == :_exit

        # Skip if it's a hash (shouldn't happen, but defensive)
        next if node_name.is_a?(Hash)

        unless find_stage(node_name)
          raise Minigun::Error, "[Pipeline:#{@name}] Routing references non-existent stage '#{node_name}'"

============================

- rename end_of_stage --> end_of_all_upstreams?

==================================

- harden --> add inputoutputstream

==================================

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


==========================

- fibers

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
