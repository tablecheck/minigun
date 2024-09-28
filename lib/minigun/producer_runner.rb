# frozen_string_literal: true


@accumulator_queue = SizedQueue.new(max_processes * max_threads * 2)
ProducerRunner.new(queues, @accumulator_queue).start_producer_thread
AccumulatorRunner.new(@accumulator_queue).start_accumulator_thread


module Minigun
  class ProducerRunner

    def initialize(producers,
                   queues,
                   output_queue,
                   log_writer,
                   callbacks,
                   on_retry: nil,
                   on_failure: nil)
      @queues = queues.dup
      @output_queue = output_queue
      @callbacks = callbacks

      @on_retry   = on_retry || ->(e, attempts) { Rails.logger.warn { "[Producer] #{queue_name}: Error fetching IDs in #{format_time_range(range)}, attempt #{attempts} of #{max_retries}: #{e.class}: #{e.message}. Retrying..." } }
      @on_failure = on_failure || ->(e, _attempts) { Rails.logger.error { "[Producer] #{queue_name}: Failed fetching IDs in #{format_time_range(range)} after #{max_retries} attempts: #{e.class}: #{e.message}. Skipping." } }
      @produce_in_batches = ->(queue) { yield }
    end

    def start_producer_thread
      Thread.new do
        log_writer.log_producer_start
        @producer_queue_threads = []
        @producer_semaphore = Concurrent::Semaphore.new(max_threads)
        @producer_mutex = Mutex.new
        while (queue = queues.pop)
          @producer_queue_threads << start_producer_queue_thread(queue)
        end
        @producer_queue_threads.each(&:join)
        @output_queue << Minigun.end_object
        log_writer.log_producer_finished(@produced_count)
      end
    end

    private

    attr_reader :log_writer,
                :callbacks,
                :on_retry,
                :on_failure,
                :producer_batches

    def start_producer_queue_thread(queue)
      @producer_semaphore.acquire
      Thread.new do
        callbacks.invoke(:before_produce_queue, queue)
        callbacks.invoke(:around_produce_queue, queue) do
          queue_name = queue.to_s.demodulize
          Rails.logger.info { "[Producer] #{queue_name}: Started queue thread." }
          producer_batches.call(queue).each do |range|
            with_retry do
              log_writer.log_producer_queue_start(queue, batch)
              Rails.logger.info { "[Producer] #{queue_name}: Producing time range #{format_time_range(range)}..." }
              count = produce_queue_batch(queue, batch)
              Rails.logger.info { "[Producer] #{queue_name}: Produced #{count} IDs in time range #{format_time_range(range)}." }
            end
          end
        end
        callbacks.invoke(:after_produce_queue)
        GC.start
        @producer_semaphore.release
      end
    end

    def produce_queue(queue, range)
      count = 0
      queue.unscoped.where(updated_at: range).pluck_each(:_id) do |id|
        @accumulator_queue << [queue, id.to_s.freeze].freeze
        @producer_mutex.synchronize { @produced_count += 1 }
        count += 1
      end
      count
    end

    def with_retry(&block)
      Minigun::Util.with_retry(on_retry: on_retry, on_failure: on_failure, &block)
    end
  end
end
