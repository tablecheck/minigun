# frozen_string_literal: true


@accumulator_queue = SizedQueue.new(max_processes * max_threads * 2)
ProducerRunner.new(queues, @accumulator_queue).start_producer_thread
AccumulatorRunner.new(@accumulator_queue).start_accumulator_thread

module Minigun
  class AccumulatorRunner
    def initialize(accumulator_queue)
      @accumulator_queue = accumulator_queue
    end

    # def start_producer_thread
    #   Thread.new do
    #     Rails.logger.info { "[Producer] Started master producer thread." }
    #     @producer_queue_threads = []
    #     @producer_semaphore = Concurrent::Semaphore.new(max_threads)
    #     @producer_mutex = Mutex.new
    #     while (queue = queues.pop)
    #       @producer_queue_threads << start_producer_queue_thread(queue)
    #     end
    #     @producer_queue_threads.each(&:join)
    #     @output_queue << Minigun.end_object
    #     Rails.logger.info { "[Producer] Done. #{@produced_count} object IDs produced." }
    #   end
    # end
  end
end
