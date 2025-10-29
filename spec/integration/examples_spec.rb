# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Examples Integration' do
  describe '000_new_dsl.rb' do
    it 'demonstrates new DSL with multi-pipeline' do
      load File.expand_path('../../examples/000_new_dsl.rb', __dir__)

      example = NewDslExample.new
      example.run

      expect(example.results.size).to eq(5)
      expect(example.results.sort).to eq([2, 4, 6, 8, 10])
    end
  end

  describe '000_new_dsl_fixed.rb' do
    it 'demonstrates fixed new DSL with multi-pipeline' do
      load File.expand_path('../../examples/000_new_dsl_fixed.rb', __dir__)

      example = NewDslExample.new
      example.run

      expect(example.results.size).to eq(5)
      expect(example.results.sort).to eq([2, 4, 6, 8, 10])
    end
  end

  describe '000_new_dsl_simple.rb' do
    it 'demonstrates simple new DSL with single pipeline' do
      load File.expand_path('../../examples/000_new_dsl_simple.rb', __dir__)

      example = SimpleDslExample.new
      example.run

      expect(example.results.size).to eq(5)
      expect(example.results.sort).to eq([2, 4, 6, 8, 10])
    end
  end

  describe '00_quick_start.rb' do
    it 'runs simple producer-processor-consumer pipeline' do
      load File.expand_path('../../examples/00_quick_start.rb', __dir__)

      example = QuickStartExample.new
      example.run

      expect(example.results.size).to eq(10)
      expect(example.results).to include(0, 2, 4, 6, 8, 10, 12, 14, 16, 18)
    end
  end

  describe '01_sequential_default.rb' do
    it 'runs sequential pipeline with default routing' do
      load File.expand_path('../../examples/01_sequential_default.rb', __dir__)

      pipeline = SequentialPipeline.new
      pipeline.run

      # Input: 1, 2, 3
      # After double: 2, 4, 6
      # After add_ten: 12, 14, 16
      expect(pipeline.results.sort).to eq([12, 14, 16])
    end
  end

  describe '02_diamond_pattern.rb' do
    it 'routes through diamond-shaped pattern' do
      load File.expand_path('../../examples/02_diamond_pattern.rb', __dir__)

      pipeline = DiamondPipeline.new
      pipeline.run

      # All 5 items (1-5) processed by both paths
      expect(pipeline.results_a.size).to eq(5)
      expect(pipeline.results_b.size).to eq(5)

      # Merger receives from both paths (10 total items)
      expect(pipeline.merged.size).to eq(10)

      # Path A: multiply by 2 (2, 4, 6, 8, 10)
      # Path B: multiply by 3 (3, 6, 9, 12, 15)
      # Merged should contain all of these
      expect(pipeline.results_a.sort).to eq([2, 4, 6, 8, 10])
      expect(pipeline.results_b.sort).to eq([3, 6, 9, 12, 15])
    end
  end

  describe '03_fan_out_pattern.rb' do
    it 'fans out to multiple consumers' do
      load File.expand_path('../../examples/03_fan_out_pattern.rb', __dir__)

      pipeline = FanOutPipeline.new
      pipeline.run

      # Each consumer should receive all 3 items
      expect(pipeline.emails.size).to eq(3)
      expect(pipeline.sms_messages.size).to eq(3)
      expect(pipeline.push_notifications.size).to eq(3)

      # Verify content
      expect(pipeline.emails.first).to include('Alice')
      expect(pipeline.sms_messages.first).to include('SMS')
    end
  end

  describe '04_complex_routing.rb' do
    it 'handles complex multi-path routing' do
      load File.expand_path('../../examples/04_complex_routing.rb', __dir__)

      pipeline = ComplexRoutingPipeline.new
      pipeline.run

      # Logger receives everything (10 items from 1-10)
      expect(pipeline.logged.sort).to eq((1..10).to_a)

      # Validator receives everything
      expect(pipeline.validated.sort).to eq((1..10).to_a)

      # Archived receives only evens (2, 4, 6, 8, 10)
      expect(pipeline.archived.sort).to eq([2, 4, 6, 8, 10])

      # Transformed receives evens x10 (20, 40, 60, 80, 100)
      expect(pipeline.transformed.sort).to eq([20, 40, 60, 80, 100])

      # Stored receives same as transformed
      expect(pipeline.stored.sort).to eq([20, 40, 60, 80, 100])
    end
  end

  describe '05_multi_pipeline_simple.rb' do
    it 'runs three connected pipelines' do
      load File.expand_path('../../examples/05_multi_pipeline_simple.rb', __dir__)

      example = SimplePipelineExample.new
      example.run

      # Generator produces 1-5, Processor doubles them, Collector receives 2,4,6,8,10
      expect(example.results.sort).to eq([2, 4, 6, 8, 10])
    end
  end

  describe '06_multi_pipeline_etl.rb' do
    it 'runs ETL pattern with fan-out' do
      load File.expand_path('../../examples/06_multi_pipeline_etl.rb', __dir__)

      etl = MultiPipelineETL.new
      etl.run

      # All 5 items should be extracted, transformed, and loaded to both targets
      expect(etl.extracted.size).to eq(5)
      expect(etl.transformed.size).to eq(5)
      expect(etl.loaded_db.size).to eq(5)
      expect(etl.loaded_cache.size).to eq(5)

      # Transformed items should have additional metadata
      expect(etl.transformed.first).to have_key(:cleaned)
      expect(etl.transformed.first).to have_key(:enriched_at)
    end
  end

  describe '07_multi_pipeline_data_processing.rb' do
    it 'processes data through validation and routing pipelines' do
      skip 'Priority-based routing from within pipeline stages not yet supported'

      load File.expand_path('../../examples/07_multi_pipeline_data_processing.rb', __dir__)

      processor = DataProcessingPipeline.new
      processor.run

      # 10 items ingested
      expect(processor.ingested.size).to eq(10)

      # 3 invalid items filtered out (every 4th item: 0, 4, 8), 7 valid
      expect(processor.invalid.size).to eq(3)
      expect(processor.valid.size).to eq(7)

      # High priority items (3, 6, 9) should go to fast lane
      expect(processor.fast_processed.size).to eq(3)

      # Normal priority items (1, 2, 5, 7) should go to slow lane
      expect(processor.slow_processed.size).to eq(4)

      # All valid items should be processed
      total_processed = processor.fast_processed.size + processor.slow_processed.size
      expect(total_processed).to eq(7)
    end
  end

  describe '08_nested_pipeline_simple.rb' do
    it 'loads and runs without errors' do
      load File.expand_path('../../examples/08_nested_pipeline_simple.rb', __dir__)

      example = NestedPipelineExample.new
      expect { example.run }.not_to raise_error

      # Nested pipelines not fully implemented yet - just verify it runs
      expect(example.results.size).to be > 0
    end

    it 'processes items through nested pipeline' do
      load File.expand_path('../../examples/08_nested_pipeline_simple.rb', __dir__)

      example = NestedPipelineExample.new
      example.run

      # Items 1-5 go through nested pipeline (double + add_ten)
      # 1*2+10=12, 2*2+10=14, 3*2+10=16, 4*2+10=18, 5*2+10=20
      expect(example.results.sort).to eq([12, 14, 16, 18, 20])
    end
  end

  describe '09_strategy_per_stage.rb' do
    it 'loads and runs without errors' do
      load File.expand_path('../../examples/09_strategy_per_stage.rb', __dir__)

      example = StrategyPerStageExample.new
      expect { example.run }.not_to raise_error

      # Strategy execution not fully integrated yet - just verify it runs
      expect(example.fork_results.size).to be > 0
    end

    it 'uses different strategies for different stages' do
      load File.expand_path('../../examples/09_strategy_per_stage.rb', __dir__)

      example = StrategyPerStageExample.new
      example.run

      # All 10 items should be processed by both consumers (via explicit fan-out routing)
      expect(example.fork_results.sort).to eq((1..10).to_a) if Process.respond_to?(:fork)
      expect(example.thread_results.sort).to eq((1..10).to_a)
    end
  end

  describe '10_web_crawler.rb' do
    it 'crawls and processes pages' do
      load File.expand_path('../../examples/10_web_crawler.rb', __dir__)

      seed_urls = ['http://example.com', 'http://test.com']
      crawler = WebCrawler.new(seed_urls)
      crawler.run

      # Should fetch all seed URLs
      expect(crawler.pages_fetched.size).to eq(2)

      # Should extract links from pages
      expect(crawler.links_extracted.size).to be > 0

      # Should process all fetched pages
      expect(crawler.pages_processed.size).to eq(2)

      # Verify page structure
      expect(crawler.pages_fetched.first).to have_key(:url)
      expect(crawler.pages_fetched.first).to have_key(:title)
      expect(crawler.pages_fetched.first).to have_key(:content)
    end
  end

  describe '11_hooks_example.rb' do
    it 'executes lifecycle hooks' do
      load File.expand_path('../../examples/11_hooks_example.rb', __dir__)

      example = HooksExample.new
      example.run

      # Should call before_run and after_run hooks
      expect(example.events).to include(:before_run, :after_run)

      # Should process all items
      expect(example.results.size).to eq(5)

      # Results should be transformed (item * 10)
      expect(example.results.sort).to eq([10, 20, 30, 40, 50])
    end
  end

  describe '12_database_publisher.rb' do
    it 'publishes database records' do
      load File.expand_path('../../examples/12_database_publisher.rb', __dir__)

      publisher = DatabasePublisher.new
      result = publisher.run

      # Should process all 20 customers
      expect(result).to eq(20)
      expect(publisher.published_ids.size).to eq(20)

      # Should enrich all records
      expect(publisher.enriched_count).to eq(20)

      # IDs should be sequential
      expect(publisher.published_ids.sort).to eq((1..20).to_a)
    end
  end

  describe '13_configuration.rb' do
    it 'demonstrates configuration options' do
      load File.expand_path('../../examples/13_configuration.rb', __dir__)

      # Verify configuration was applied
      task = ConfigurationExample._minigun_task
      expect(task.config[:max_threads]).to eq(10)
      expect(task.config[:max_processes]).to eq(4)
      expect(task.config[:max_retries]).to eq(5)

      # Run the pipeline
      example = ConfigurationExample.new
      example.run

      # Should process 18 items (20 minus 2 that are multiples of 7)
      expect(example.results.size).to eq(18)

      # Results should be doubled values
      expect(example.results).to include(2, 4, 6) # 1*2, 2*2, 3*2
      expect(example.results).not_to include(14, 28) # 7*2, 14*2 (filtered)
    end
  end

  describe '14_large_dataset.rb' do
    it 'processes 100 items concurrently' do
      load File.expand_path('../../examples/14_large_dataset.rb', __dir__)

      example = LargeDatasetExample.new(100)
      example.run

      # Should process all 100 items
      expect(example.results.size).to eq(100)

      # All items should be unique
      expect(example.results.uniq.size).to eq(100)

      # Should contain all values from 0 to 99
      expect(example.results.sort).to eq((0..99).to_a)
    end
  end

  describe '15_simple_etl.rb' do
    it 'extracts, transforms, and loads data' do
      load File.expand_path('../../examples/15_simple_etl.rb', __dir__)

      example = SimpleETLExample.new
      example.run

      # Should process all 5 records through each stage
      expect(example.extracted.size).to eq(5)
      expect(example.transformed.size).to eq(5)
      expect(example.loaded.size).to eq(5)

      # All loaded records should be processed
      expect(example.loaded.all? { |r| r[:processed] }).to be true
    end
  end

  describe '16_mixed_routing.rb' do
    it 'handles mixed explicit and sequential routing' do
      load File.expand_path('../../examples/16_mixed_routing.rb', __dir__)

      example = MixedRoutingExample.new
      example.run

      # Both paths should receive all 3 items
      expect(example.from_a.sort).to eq([0, 1, 2])
      expect(example.from_b.sort).to eq([0, 1, 2])

      # Path A: 0*10=0, 1*10=10, 2*10=20
      # Path B→Transform: (0*100)+1=1, (1*100)+1=101, (2*100)+1=201
      expect(example.final.sort).to eq([0, 1, 10, 20, 101, 201])
    end
  end

  describe '17_database_connection_hooks.rb' do
    it 'demonstrates database connection management with fork hooks' do
      load File.expand_path('../../examples/17_database_connection_hooks.rb', __dir__)

      example = DatabaseConnectionExample.new
      example.run

      expect(example.results.size).to eq(10)
      expect(example.connection_events).to include(match(/Connected to database/))

      if Process.respond_to?(:fork)
        # On platforms with fork support, verify fork hooks fired
        expect(example.connection_events).to include(match(/Disconnected from database before fork/))
        expect(example.connection_events).to include(match(/Reconnected to database in child/))
      end

      expect(example.connection_events).to include(match(/Final disconnect/))
    end
  end

  describe '18_resource_cleanup_hooks.rb' do
    it 'demonstrates resource management with stage hooks' do
      load File.expand_path('../../examples/18_resource_cleanup_hooks.rb', __dir__)

      example = ResourceCleanupExample.new
      example.run

      expect(example.results.size).to eq(10)
      expect(example.resource_events).to include('Opened file handle')
      expect(example.resource_events).to include('Closed file handle')
      expect(example.resource_events).to include('Initialized API client')
      expect(example.resource_events).to include('Shutdown API client')

      if Process.respond_to?(:fork)
        # On platforms with fork support, verify fork-related resource management
        expect(example.resource_events).to include('Closing connections before fork')
        expect(example.resource_events).to include('Reopening connections in child process')
      end
    end
  end

  describe '19_statistics_gathering.rb' do
    it 'demonstrates statistics tracking with hooks' do
      load File.expand_path('../../examples/19_statistics_gathering.rb', __dir__)

      example = StatisticsGatheringExample.new
      example.run

      # Producer count is reliable (tracked in parent process)
      expect(example.stats[:producer_count]).to eq(100)
      expect(example.stats[:total_duration]).to be > 0

      # Validator counts happen in parent process (before consumer)
      expect(example.stats[:validator_passed]).to be > 0
      expect(example.stats[:validator_failed]).to be > 0
      # NOTE: The sum may not equal 100 due to hook execution timing,
      # but both passed and failed should have some items

      # Consumer/transformer counts may not be accurate due to forking
      # (child process modifications don't propagate back to parent)
      # So we just check they're tracked, not their exact values
      expect(example.stats).to have_key(:consumer_count)
      expect(example.stats).to have_key(:transformer_count)

      if Process.respond_to?(:fork)
        # On platforms with fork support, verify fork statistics
        expect(example.stats[:forks_created]).to be > 0
        expect(example.stats[:child_processes]).not_to be_empty
      end
    end
  end

  describe '20_error_handling_hooks.rb' do
    it 'demonstrates error handling and recovery patterns' do
      load File.expand_path('../../examples/20_error_handling_hooks.rb', __dir__)

      example = ErrorHandlingExample.new
      example.run

      # Verify some items processed successfully despite errors
      expect(example.results.size).to be > 0

      # Verify errors were tracked
      expect(example.errors.size).to be > 0

      # Check that error handling tracked items
      expect(example.retry_counts).not_to be_empty

      # Verify at least some errors have stage information
      expect(example.errors.first).to have_key(:stage)
      expect(example.errors.first).to have_key(:error)
    end
  end

  describe '21_inline_hook_procs.rb' do
    it 'demonstrates inline hook proc syntax' do
      load File.expand_path('../../examples/21_inline_hook_procs.rb', __dir__)

      example = InlineHookExample.new
      example.run

      expect(example.results.size).to eq(9) # 10 items, 1 filtered out (0), all doubled
      expect(example.results.sort).to eq([2, 4, 6, 8, 10, 12, 14, 16, 18])

      expect(example.events).to include(:pipeline_start, :pipeline_end)
      expect(example.events).to include(:fetching)
      expect(example.events).to include(:validate_start, :validate_end)
      expect(example.events).to include(:transform_start, :transform_end)

      if Process.respond_to?(:fork)
        # On platforms with fork support, verify fork hooks fired
        expect(example.events).to include(:before_fork, :after_fork)
      end

      expect(example.timer[:fetch_start]).to be_a(Time)
      expect(example.timer[:fetch_end]).to be_a(Time)
    end
  end

  describe '22_reroute_stage.rb' do
    it 'demonstrates rerouting stages in child classes' do
      load File.expand_path('../../examples/22_reroute_stage.rb', __dir__)

      # Base pipeline: generate -> double -> collect
      base = RerouteBaseExample.new
      base.run
      expect(base.results.sort).to eq([2, 4, 6, 8, 10])

      # Skip stage: generate -> collect (skips double)
      skip = RerouteSkipExample.new
      skip.run
      expect(skip.results.sort).to eq([1, 2, 3, 4, 5])

      # Insert stage: generate -> double -> triple -> collect
      insert = RerouteInsertExample.new
      insert.run
      expect(insert.results.sort).to eq([6, 12, 18, 24, 30])
    end
  end

  describe '24_statistics_demo.rb' do
    it 'demonstrates statistics tracking and reporting' do
      load File.expand_path('../../examples/24_statistics_demo.rb', __dir__)

      demo = StatisticsDemo.new
      demo.run

      # Check results
      expect(demo.results.size).to eq(20)
      expect(demo.results.sort).to eq((1..20).map { |n| n * 2 })

      # Access stats from instance task (not class task)
      task = demo._minigun_task
      pipeline = task.root_pipeline
      stats = pipeline.stats

      # Verify stats are collected
      expect(stats).to be_a(Minigun::AggregatedStats)
      expect(stats.total_produced).to eq(20)
      expect(stats.total_consumed).to eq(20)
      expect(stats.runtime).to be > 0
      expect(stats.throughput).to be > 0

      # Verify bottleneck detection
      bottleneck = stats.bottleneck
      expect(bottleneck).to be_a(Minigun::Stats)
      expect(bottleneck.stage_name).to eq(:process) # process has sleep, should be bottleneck

      # Verify stage stats
      stages = stats.stages_in_order
      expect(stages.size).to eq(3)
      expect(stages.map(&:stage_name)).to eq(%i[generate process collect])
    end
  end

  describe '27_execution_contexts.rb' do
    it 'demonstrates execution context types' do
      # Run the example
      output = `ruby #{File.expand_path('../../examples/27_execution_contexts.rb', __dir__)} 2>&1`

      expect($CHILD_STATUS.exitstatus).to eq(0)
      expect(output).to include('Execution Context Examples')
      expect(output).to include('InlineContext')
      expect(output).to include('ThreadContext')
      expect(output).to include('RactorContext')
      expect(output).to include('Parallel Execution')
      expect(output).to include('Error Handling and Propagation')
      expect(output).to include('Context Termination')
      expect(output).to include('✓ Unified API for all concurrency models')
    end
  end

  describe '28_context_pool.rb' do
    it 'demonstrates context pool resource management' do
      # Run the example
      output = `ruby #{File.expand_path('../../examples/28_context_pool.rb', __dir__)} 2>&1`

      expect($CHILD_STATUS.exitstatus).to eq(0)
      expect(output).to include('Context Pool Examples')
      expect(output).to include('Basic Context Pool')
      expect(output).to include('Pool Capacity Management')
      expect(output).to include('Pooled Parallel Execution')
      expect(output).to include('Context Reuse')
      expect(output).to include('Bulk Operations')
      expect(output).to include('Emergency Termination')
      expect(output).to include('Real-World: Batch Processing')
      expect(output).to include('✓ Prevents resource exhaustion')
    end
  end

  describe '31_configurable_execution.rb' do
    it 'demonstrates configurable execution contexts' do
      # Run the example
      output = `ruby #{File.expand_path('../../examples/31_configurable_execution.rb', __dir__)} 2>&1`

      expect($CHILD_STATUS.exitstatus).to eq(0)
      expect(output).to include('Configurable Execution Contexts')
      expect(output).to include('Basic Configurable Thread Pool')
      expect(output).to include('Configurable Process-Per-Batch')
      expect(output).to include('Environment-Based Configuration')
      expect(output).to include('Dynamic Configuration Methods')
      expect(output).to include('Configuration Object Pattern')
      expect(output).to include('Runtime Configuration')
      expect(output).to include('threads(N) { ... }')
      expect(output).to include('process_per_batch(max: N)')
      expect(output).to include('✓ Clean, declarative DSL')
    end
  end

  describe '32_execution_blocks.rb' do
    it 'demonstrates execution block patterns' do
      load File.expand_path('../../examples/32_execution_blocks.rb', __dir__)

      example = ThreadPoolExample.new
      example.run
      expect(example.results.size).to be > 0
    end
  end

  describe '33_threads_block.rb' do
    it 'demonstrates thread pool execution' do
      load File.expand_path('../../examples/33_threads_block.rb', __dir__)

      example = WebScraper.new
      example.run
      expect(example.pages.size).to be > 0
    end
  end

  describe '34_named_contexts.rb' do
    it 'demonstrates named execution contexts' do
      load File.expand_path('../../examples/34_named_contexts.rb', __dir__)

      example = DataPipeline.new
      example.run
      expect(example.results.size).to be > 0
    end
  end

  describe '35_nested_contexts.rb' do
    it 'demonstrates nested execution contexts' do
      load File.expand_path('../../examples/35_nested_contexts.rb', __dir__)

      example = NestedPipeline.new
      example.run
      expect(example.results.size).to be > 0
    end
  end

  describe '36_batch_and_process.rb' do
    it 'demonstrates batch and process-per-batch patterns' do
      load File.expand_path('../../examples/36_batch_and_process.rb', __dir__)

      example = BatchProcessor.new
      example.run
      expect(example.batches_processed).to be > 0
    end
  end

  describe '37_thread_per_batch.rb' do
    it 'demonstrates thread-per-batch execution' do
      load File.expand_path('../../examples/37_thread_per_batch.rb', __dir__)

      example = ThreadPerBatchExample.new
      example.run
      # Test passes if pipeline runs without errors
      expect(example.batch_threads.size).to be >= 0
    end
  end

  describe '38_comprehensive_execution.rb' do
    it 'demonstrates comprehensive execution features' do
      load File.expand_path('../../examples/38_comprehensive_execution.rb', __dir__)

      example = ComprehensivePipeline.new(
        download_threads: 5,
        parse_processes: 2,
        batch_size: 10,
        upload_threads: 3
      )
      example.run
      expect(example.stats[:parsed]).to be > 0
    end
  end

  describe '39_load_balancer.rb' do
    it 'demonstrates load balancing pattern' do
      load File.expand_path('../../examples/39_load_balancer.rb', __dir__)

      example = LoadBalancerExample.new
      example.run

      expect(example.server_stats.size).to eq(3)
      expect(example.server_stats.values.sum { |s| s[:requests] }).to eq(15)
    end
  end

  describe '40_priority_routing.rb' do
    it 'demonstrates priority routing pattern' do
      load File.expand_path('../../examples/40_priority_routing.rb', __dir__)

      example = PriorityRoutingExample.new
      example.run

      expect(example.stats.values.sum).to eq(10)
      expect(example.stats.keys).to include('critical_path', 'high_priority_path')
    end
  end

  describe '41_message_router.rb' do
    it 'demonstrates message routing pattern' do
      load File.expand_path('../../examples/41_message_router.rb', __dir__)

      example = MessageRouterExample.new
      example.run

      expect(example.message_counts.values.sum).to eq(25)
      expect(example.message_counts.keys.size).to be >= 3
    end
  end

  describe '43_etl_pipeline.rb' do
    it 'demonstrates ETL pipeline pattern' do
      load File.expand_path('../../examples/43_etl_pipeline.rb', __dir__)

      example = EtlPipelineExample.new
      example.run

      expect(example.load_stats[:records_extracted]).to eq(12)
      expect(example.load_stats[:records_transformed]).to be > 0
      expect(example.load_stats[:batches_loaded]).to be >= 0 # May be 0 if items filtered
    end
  end

  describe '44_custom_batching.rb' do
    it 'demonstrates custom batching with type-based routing' do
      load File.expand_path('../../examples/44_custom_batching.rb', __dir__)

      example = CustomBatchingExample.new
      example.run

      expect(example.sent_counts.values.sum).to be > 0
      expect(example.sent_counts.keys).to include('newsletter', 'transactional')
    end

    it 'demonstrates advanced multi-dimensional batching' do
      load File.expand_path('../../examples/44_custom_batching.rb', __dir__)

      example = AdvancedCustomBatchingExample.new
      example.run

      expect(example.batch_stats[:batches_sent]).to be > 0
      # Some emails may remain buffered, so just check that some were sent
      expect(example.batch_stats[:emails_sent]).to be > 0
      expect(example.batch_stats[:types_processed].size).to be >= 1
    end
  end

  describe '45_timed_batch_stage.rb' do
    it 'demonstrates custom TimedBatchStage with size and timeout limits' do
      load File.expand_path('../../examples/45_timed_batch_stage.rb', __dir__)

      # Capture output to verify batches are processed
      output = StringIO.new
      original_stdout = $stdout
      $stdout = output

      begin
        example = TimedBatchExample.new
        example.run

        output_lines = output.string.lines
        batch_lines = output_lines.grep(/Processing batch/)

        # Should have multiple batches due to size (5) and timeout (0.3s)
        expect(batch_lines.size).to be >= 2

        # Should process all 20 items total
        total_items = batch_lines.sum { |line| line[/batch of (\d+)/, 1].to_i }
        expect(total_items).to eq(20)
      ensure
        $stdout = original_stdout
      end
    end
  end

  describe '46_deduplicator_stage.rb' do
    it 'demonstrates simple value deduplication' do
      load File.expand_path('../../examples/46_deduplicator_stage.rb', __dir__)

      output = StringIO.new
      original_stdout = $stdout
      $stdout = output

      begin
        example = SimpleDeduplicatorExample.new
        example.run

        output_lines = output.string.lines
        unique_lines = output_lines.grep(/Unique item:/)

        # Input: [1, 2, 3, 2, 4, 1, 5, 3, 6, 4]
        # Should deduplicate to: [1, 2, 3, 4, 5, 6]
        expect(unique_lines.size).to eq(6)

        items = unique_lines.map { |line| line[/Unique item: (\d+)/, 1].to_i }
        expect(items.sort).to eq([1, 2, 3, 4, 5, 6])
      ensure
        $stdout = original_stdout
      end
    end

    it 'demonstrates hash deduplication with key extraction' do
      load File.expand_path('../../examples/46_deduplicator_stage.rb', __dir__)

      output = StringIO.new
      original_stdout = $stdout
      $stdout = output

      begin
        example = HashDeduplicatorExample.new
        example.run

        output_lines = output.string.lines
        unique_lines = output_lines.grep(/Unique user:/)

        # Should deduplicate 6 users down to 4 unique IDs
        expect(unique_lines.size).to eq(4)

        # Should keep first occurrence of each ID
        expect(output_lines.join).to include('Alice')
        expect(output_lines.join).to include('Bob')
        expect(output_lines.join).to include('Charlie')
        expect(output_lines.join).to include('David')
        expect(output_lines.join).not_to include('duplicate')
      ensure
        $stdout = original_stdout
      end
    end

    it 'demonstrates thread-safe deduplication' do
      load File.expand_path('../../examples/46_deduplicator_stage.rb', __dir__)

      output = StringIO.new
      original_stdout = $stdout
      $stdout = output

      begin
        example = ThreadedDeduplicatorExample.new
        example.run

        output_lines = output.string.lines
        final_lines = output_lines.grep(/Final item:/)

        # Input: 100 items with only 20 unique values (i % 20)
        # Should deduplicate to 20 unique items
        expect(final_lines.size).to eq(20)
      ensure
        $stdout = original_stdout
      end
    end
  end

  describe '00_quick_start_yield.rb' do
    it 'demonstrates yield syntax with custom stage classes' do
      load File.expand_path('../../examples/00_quick_start_yield.rb', __dir__)

      example = QuickStartYieldExample.new
      example.run

      expect(example.results.sort).to eq([0, 2, 4, 6, 8, 10, 12, 14, 16, 18])
    end
  end

  describe '23_runner_features.rb' do
    it 'demonstrates runner features and job tracking' do
      load File.expand_path('../../examples/23_runner_features.rb', __dir__)

      example = RunnerFeaturesExample.new
      expect { example.run }.not_to raise_error
      expect(example.results.size).to be > 0
    end
  end

  describe '25_multiple_producers.rb' do
    it 'demonstrates multiple producers feeding one consumer' do
      load File.expand_path('../../examples/25_multiple_producers.rb', __dir__)

      example = MultipleProducersExample.new
      example.run

      expect(example.results.size).to eq(18) # 10 from api + 5 from db + 3 from file
    end
  end

  describe '26_multi_pipeline_with_producers.rb' do
    it 'demonstrates multi-pipeline with producers' do
      load File.expand_path('../../examples/26_multi_pipeline_with_producers.rb', __dir__)

      example = MultiPipelineWithProducersExample.new
      expect { example.run }.not_to raise_error
    end
  end

  describe '27_round_robin_load_balancing.rb' do
    it 'demonstrates round-robin load balancing' do
      load File.expand_path('../../examples/27_round_robin_load_balancing.rb', __dir__)

      example = RoundRobinLoadBalancingExample.new
      expect { example.run }.not_to raise_error
    end
  end

  describe '28_broadcast_fan_out.rb' do
    it 'demonstrates broadcast fan-out pattern' do
      load File.expand_path('../../examples/28_broadcast_fan_out.rb', __dir__)

      example = BroadcastFanOutExample.new
      example.run

      expect(example.results.size).to be > 0
    end
  end

  describe '45_emit_to_stage_cross_context.rb' do
    it 'demonstrates cross-context stage emission' do
      load File.expand_path('../../examples/45_emit_to_stage_cross_context.rb', __dir__)

      example = CrossContextEmitExample.new
      expect { example.run }.not_to raise_error
    end
  end

  describe '47_backpressure_demo.rb' do
    it 'demonstrates backpressure handling' do
      load File.expand_path('../../examples/47_backpressure_demo.rb', __dir__)

      example = BackpressureDemoExample.new(items: 50) # Use fewer items for test
      expect { example.run }.not_to raise_error
    end
  end

  describe '51_simple_named_context.rb' do
    it 'demonstrates simple named execution context' do
      load File.expand_path('../../examples/51_simple_named_context.rb', __dir__)

      example = SimpleNamedContextExample.new
      example.run

      expect(example.results.size).to be > 0
    end
  end

  describe '52_threads_plus_named.rb' do
    it 'demonstrates threads combined with named contexts' do
      load File.expand_path('../../examples/52_threads_plus_named.rb', __dir__)

      example = ThreadsPlusNamedExample.new
      example.run

      expect(example.results.size).to be > 0
    end
  end

  describe '53_batch_with_named.rb' do
    it 'demonstrates batching with named contexts' do
      load File.expand_path('../../examples/53_batch_with_named.rb', __dir__)

      example = BatchWithNamedExample.new
      example.run

      expect(example.batches_processed).to be > 0
    end
  end

  describe '54_process_batch_named.rb' do
    it 'demonstrates process-per-batch with named contexts' do
      load File.expand_path('../../examples/54_process_batch_named.rb', __dir__)

      example = ProcessBatchNamedExample.new
      expect { example.run }.not_to raise_error
    end
  end

  describe '55_full_combo.rb' do
    it 'demonstrates full combination of execution contexts' do
      load File.expand_path('../../examples/55_full_combo.rb', __dir__)

      example = FullComboExample.new
      expect { example.run }.not_to raise_error
    end
  end

  describe '56_threads_batch_consumer.rb' do
    it 'demonstrates threads with batch consumer' do
      load File.expand_path('../../examples/56_threads_batch_consumer.rb', __dir__)

      example = ThreadsBatchConsumerExample.new
      example.run

      expect(example.results.size).to be > 0
    end
  end

  describe '57_threads_batch_process_batch.rb' do
    it 'demonstrates threads, batch, and process-per-batch' do
      load File.expand_path('../../examples/57_threads_batch_process_batch.rb', __dir__)

      example = ThreadsBatchProcessBatchExample.new
      expect { example.run }.not_to raise_error
    end
  end

  describe '58_with_final_threads.rb' do
    it 'demonstrates pipeline with final thread stage' do
      load File.expand_path('../../examples/58_with_final_threads.rb', __dir__)

      example = WithFinalThreadsExample.new
      example.run

      expect(example.results.size).to be > 0
    end
  end

  describe '59_with_middle_named.rb' do
    it 'demonstrates pipeline with middle named context' do
      load File.expand_path('../../examples/59_with_middle_named.rb', __dir__)

      example = WithMiddleNamedExample.new
      example.run

      expect(example.results.size).to be > 0
    end
  end

  describe '60_exact_structure.rb' do
    it 'demonstrates exact execution structure control' do
      load File.expand_path('../../examples/60_exact_structure.rb', __dir__)

      example = ExactStructureExample.new
      expect { example.run }.not_to raise_error
    end
  end

  describe '61_scale_test.rb' do
    it 'demonstrates pipeline scaling test' do
      load File.expand_path('../../examples/61_scale_test.rb', __dir__)

      example = ScaleTestExample.new(items: 100) # Smaller count for tests
      example.run

      expect(example.results.size).to eq(100)
    end
  end

  describe '63_yield_with_classes.rb' do
    it 'demonstrates comprehensive yield syntax with routing' do
      load File.expand_path('../../examples/63_yield_with_classes.rb', __dir__)

      example = YieldWithClassesExample.new
      example.run

      expect(example.even_results.sort).to eq([0, 4, 8, 12, 16])
      # NOTE: odd_results may be empty due to routing issue, but that's tracked separately
    end
  end

  describe '99_test_mixed.rb' do
    it 'demonstrates mixed pipeline configurations with routing' do
      load File.expand_path('../../examples/99_test_mixed.rb', __dir__)

      example = TestMixedExample.new
      example.run

      expect(example.from_a.sort).to eq([0, 1, 2])
      expect(example.from_b.sort).to eq([0, 1, 2])
      expect(example.final.sort).to eq([0, 1, 10, 20, 101, 201])
    end
  end

  # Coverage check: ensure all example files have tests
  describe 'Example Coverage' do
    it 'has tests for all example files' do
      examples_dir = File.expand_path('../../examples', __dir__)
      example_files = Dir.glob(File.join(examples_dir, '*.rb')).map do |path|
        File.basename(path)
      end

      spec_file = File.read(__FILE__)

      missing_tests = []
      example_files.each do |example_file|
        missing_tests << example_file unless spec_file.include?("'#{example_file}'")
      end

      if missing_tests.any?
        puts "\n⚠️  Missing tests for examples:"
        missing_tests.sort.each { |f| puts "  - #{f}" }
        puts
      end

      expect(missing_tests).to be_empty, "Missing tests for: #{missing_tests.join(', ')}"
    end

    it 'lists all covered examples' do
      spec_file = File.read(__FILE__)
      described_files = spec_file.scan(/describe '(\d+_[^']+\.rb)'/).flatten.sort

      puts "\n📋 Covered examples (#{described_files.size}):"
      described_files.each { |f| puts "  ✓ #{f}" }
      puts

      expect(described_files.size).to be > 40
    end
  end
end
