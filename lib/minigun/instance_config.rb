# frozen_string_literal: true

module Minigun
  class Config
    extend self

    # producer_batch_object_size
    attr_writer :logger,
                :log_format,
                :log_writer,
                :consumer_max_processes,
                :max_threads,
                :producer_max_threads,
                :consumer_max_threads,
                :max_retries,
                :producer_max_retries,
                :consumer_max_retries,
                :accumulator_max_per_queue,
                :accumulator_max_all_queues,
                :accumulator_check_seconds,
                :consumer_thread_object_size,
                :consumer_batch_object_size

    # ACCUMULATOR_MAX_SINGLE_QUEUE = 2000 # 10_000
    # ACCUMULATOR_MAX_ALL_QUEUES = ACCUMULATOR_MAX_SINGLE_QUEUE * 2 # 3
    # ACCUMULATOR_CHECK_INTERVAL = 100
    # CONSUMER_THREAD_BATCH_SIZE = 200 # 1000
    # CONSUMER_QUERY_BATCH_SIZE  = 200
    # DEFAULT_MAX_RETRIES = 10
  end
end

