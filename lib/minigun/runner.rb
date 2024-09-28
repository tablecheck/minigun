# frozen_string_literal: true

module Minigun
  class Runner
    module InstanceMethods
      def _producers
        @producers ||= []
      end

      # Takes a class, proc, block
      def producer(callable = nil, &block)
        if block_given?
          _producers << block
        elsif callable.is_a?(Proc) || callable.respond_to?(:call)
          _producers << callable
        elsif callable.is_a?(Class) && callable.instance_methods.include?(:call)
          _producers << callable.new
        elsif callable.is_a?(Symbol)
          _producers << -> { instance_eval { send(proc_or_symbol) }
        end
      end
      alias_method :produce, :producer

      # Takes a class, proc, block
      def accumulator(*args, &block)

      end
      alias_method :accumulate, :accumulator

      # Takes a class, proc, block
      def consumer(*args, &block)

      end
      alias_method :consume, :consumer
    end

    class << self

      def end_object
        :eoq
      end

      def log_writer
        @log_writer ||= LogWriter.new
      end

      %i[
        max_processes
        max_threads
        max_retries
      ].each do |setting|
        define_method(setting) do |value = nil|
          value.nil? ? Config.send(setting) : Config.send("#{setting}=", value)
        end
      end

      def config

      end

      def callbacks
        @callbacks ||= Hash.new { |h, k| h[k] = [] }
      end

      # before_job
      # after_job
      # before_job_start
      # after_job_done
      # before_consumer_fork
      # after_consumer_fork
      # before_consumer_thread_start
      # after_consumer_thread_start

    end

    TIME_ZONE = 'Asia/Tokyo'
    LOCALE = :en

    def initialize(queues: nil,
                   start_time: nil,
                   end_time: nil,
                   max_processes: nil,
                   max_threads: nil,
                   max_retries: nil)
      @raw_queues = Array(queues) if queues
      @start_time = start_time
      @end_time   = end_time
      time_range
      @max_processes = max_processes
      @max_threads = max_threads
      @max_retries = max_retries || DEFAULT_MAX_RETRIES
      @produced_count = 0
      @accumulated_count = 0
    end

    def perform
      in_time_zone_and_locale do
        callbacks.invoke(:before_bootstrap)
        bootstrap!
        callbacks.invoke(:before_job_start)
        memoize_job_started
        log_writer.log_job_started
        callbacks.invoke(:before_job_start)
        producer_thread = start_producer_thread
        accumulator_thread = start_accumulator_thread
        producer_thread.join
        accumulator_thread.join
        wait_all_consumer_processes
        log_writer.log_job_finished
        callbacks.invoke(:after_job)
      end
    end
    alias_method :perform, :go_brrr
    alias_method :perform, :go_brrr!

    private

    attr_reader :max_retries

    # def queues
    #   @queues ||= (@raw_queues || default_queues).map {|queue| load_queue(queue) }
    # end
    #
    # def load_queue(queue)
    #   return queue if queue.is_a?(Module)
    #   queue = "::#{queue}" unless queue.include?(':')
    #   Object.const_get(queue)
    # end




    def start_accumulator_thread
      @consumer_pids = []
      Thread.new do
        Rails.logger.info { "[Accumulator] Started accumulator thread." }
        accumulator_map = Hash.new {|h, k| h[k] = Set.new }

        i = 0
        until (queue, id = @accumulator_queue.pop) == end_object
          accumulator_map[queue] << id
          i += 1
          check_accumulator(accumulator_map) if i >= ACCUMULATOR_MAX_SINGLE_QUEUE && i % ACCUMULATOR_CHECK_INTERVAL == 0
        end

        # Handle any remaining IDs. Since the producer thread will have finished
        # by this point, there no need to fork a child consumer.
        consume_object_ids(accumulator_map)
        @accumulated_count += accumulator_map.values.sum(&:size)
      end
    end

    def check_accumulator(accumulator_map)
      # Fork if any queue contains more than N IDs
      accumulator_map.each do |queue, ids|
        next unless (count = ids.size) >= ACCUMULATOR_MAX_SINGLE_QUEUE
        fork_consumer({ queue => accumulator_map.delete(queue) })
        @accumulated_count += count
        GC.start
      end

      # Fork if all queues together contain more than M IDs
      if (count = accumulator_map.values.sum(&:size)) > ACCUMULATOR_MAX_ALL_QUEUES # rubocop:disable Style/GuardClause
        fork_consumer(accumulator_map)
        accumulator_map.clear
        @accumulated_count += count
        GC.start
      end
    end

    def fork_consumer(object_map)
      wait_max_consumer_processes
      before_consumer_fork!
      Rails.logger.info { "[Consumer] Forking..." }
      @consumer_pids << fork do
        after_consumer_fork!
        GC.start
        @pid = Process.pid
        Rails.logger.info { "[Consumer]#{format_pid} started." }
        consume_object_ids(object_map)
      end
    end

    def consume_object_ids(object_map)
      @consumer_thread_index = 0
      @consumed_count = 0
      @consumer_threads = []
      @consumer_mutex = Mutex.new
      @consumer_semaphore = Concurrent::Semaphore.new(max_threads)
      object_map.each do |queue, object_ids|
        object_ids.uniq.in_groups_of(CONSUMER_THREAD_BATCH_SIZE, false).each do |object_ids_batch|
          @consumer_threads << start_consumer_thread(queue, object_ids_batch)
        end
      end
      @consumer_threads.each(&:join)
      after_consumer_finished!
      Rails.logger.info { "[Consumer]#{format_pid}: Done. #{@consumed_count} objects consumed." }
    end

    def start_consumer_thread(queue, object_ids)
      @consumer_semaphore.acquire
      thread_index = @consumer_mutex.synchronize { @consumer_thread_index += 1 }
      Thread.new do
        with_mongo_secondary(queue) do
          queue_name = queue.to_s.demodulize
          Rails.logger.info { "[Consumer]#{format_pid}: Started thread #{thread_index}." }
          object_ids.in_groups_of(CONSUMER_QUERY_BATCH_SIZE, false).each do |object_ids_batch|
            on_retry   = ->(e, attempts) { Rails.logger.warn { "[Consumer]#{format_pid}, Thread #{thread_index}: Error consuming #{queue_name}, attempt #{attempts} of #{max_retries}: #{e.class}: #{e.message}. Retrying..." } }
            on_failure = ->(e, _attempts) { Rails.logger.error { "[Consumer]#{format_pid}, Thread #{thread_index}: Failed consuming #{queue_name} after #{max_retries} attempts: #{e.class}: #{e.message}. Skipping." } }
            with_retry(on_retry: on_retry, on_failure: on_failure) do
              count = consume_batch(queue, object_ids_batch)
              @consumer_mutex.synchronize { @consumed_count += count }
              Rails.logger.info { "[Consumer]#{format_pid}, Thread #{thread_index}: Consumed #{count} #{queue_name} objects." }
            end
          end
        end
        @consumer_semaphore.release
      end
    end

    def consume_batch(queue, object_ids)
      count = 0
      consumer_scope(queue, object_ids).each do |object|
        consume_object(object)
        count += 1
      rescue StandardError => e
        Bugsnag.notify(e) {|r| r.add_metadata('publisher', queue: queue.to_s, object_id: object&._id) }
      end
      count
    end

    def consumer_scope(queue, object_ids)
      includes = queue_INCLUDES[queue.to_s].presence
      scope = queue.unscoped.any_in(_id: object_ids)
      scope = scope.includes(includes) if includes
      scope
    end

    def wait_max_consumer_processes
      return if @consumer_pids.size < max_processes
      begin
        pid = Process.wait
        @consumer_pids.delete(pid)
      rescue Errno::ECHILD # rubocop:disable Lint/SuppressedException
      end
    end

    def wait_all_consumer_processes
      @consumer_pids.each do |pid|
        Process.wait(pid)
        @consumer_pids.delete(pid)
      rescue Errno::ECHILD
        @consumer_pids.delete(pid)
      end
    end

    def time_range
      @time_range ||= in_time_zone_and_locale do
        start_time = @start_time&.beginning_of_day if @start_time.is_a?(Date)
        start_time ||= @start_time&.in_time_zone
        raise ArgumentError.new('Must specify :start_time') unless start_time

        end_time = @end_time&.end_of_day if @end_time.is_a?(Date)
        end_time ||= @end_time&.in_time_zone

        start_time..end_time
      end
    end

    def time_range_in_batches(queue)
      time_ranges = []
      t = time_range.first
      t_end = time_range.end
      now = Time.current
      batch_size = time_range_batch_size(queue)
      while t < (t_end || now)
        t_next = t + batch_size
        t_batch_end = if t_end&.<=(t_next)
                        t_end
                      elsif now <= t_next
                        nil
                      else
                        t_next
                      end
        time_ranges << (t..t_batch_end)
        t = t_next
      end
      time_ranges
    end

    def time_range_batch_size(queue)
      @time_range_batch_size ||= queue.to_s.in?(queueS_TRANSACTIONAL) ? 1.hour : 1.day
    end

    def in_time_zone_and_locale(&block)
      Time.use_zone(TIME_ZONE) do
        I18n.with_locale(LOCALE, &block)
      end
    end

    def max_processes
      @max_processes ||= ENV['WEB_CONCURRENCY']&.to_i ||
        ENV['MAX_PROCESSES']&.to_i ||
        (Rails.env.in?(%w[production staging]) ? `nproc`.to_i : 1)
    end

    def max_threads
      @max_threads ||= ENV['RAILS_MAX_THREADS']&.to_i ||
        Mongoid.default_client.options['max_pool_size']
    end

    def job_start_at
      @job_start_at ||= Time.current
    end

    def job_consumer_start_at
      @job_consumer_start_at ||= Time.current
    end

    def job_end_at
      @job_end_at ||= Time.current
    end

    def bootstrap!
      max_processes
      max_threads
      Rails.application.eager_load!
    end

    def before_job_start!
      # Can be overridden in subclass
    end

    def before_consumer_fork!
      ::Mongoid.disconnect_clients
      # Can be overridden in subclass
    end

    def after_consumer_fork!
      ::Mongoid.reconnect_clients
      # Can be overridden in subclass
    end

    def after_consumer_finished!
      # Can be overridden in subclass
    end

    def after_job_finished!
      # Can be overridden in subclass
    end

    def with_retry(on_retry: nil, on_failure: nil)
      attempts = 0
      begin
        yield
      rescue StandardError => e
        attempts += 1
        if attempts <= max_retries
          on_retry&.call(e, attempts)
          sleep_with_backoff(attempts)
          retry
        else
          on_failure&.call(e, attempts)
        end
      end
    end

    def sleep_with_backoff(attempts)
      sleep((5**attempts) / 100.0 + rand(0.05..1))
    end

    def with_mongo_secondary(queue, &)
      read_opts = { mode: :secondary_preferred }
      queue.with(read: read_opts, &)
    end

    def report_job_started
      Rails.logger.info { "#{job_name} started.\n#{job_info_message}" }
    end

    def report_job_finished
      Rails.logger.info { "#{job_name} finished.\n#{job_info_message(finished: true)}" }
    end

    def job_name
      self.class.name.demodulize
    end

    def job_info_message(finished: false)
      data = job_info_data(finished: finished)
      just = data.keys.map(&:size).max
      data.map do |k, v|
        "  #{k.to_s.ljust(just)}  #{v}"
      end.join("\n")
    end

    def job_info_data(finished: false)
      data = { job_start_at: format_time(job_start_at) }
      if finished
        count   = @accumulated_count
        runtime = job_end_at - job_start_at
        rate    = count / (runtime / 60.0)
        data[:job_end_at]   = format_time(job_end_at)
        data[:object_count] = "#{count} objects published"
        data[:job_runtime]  = "#{runtime.round} seconds"
        data[:job_rate]     = "#{rate.round} objects / minute"
      end
      data[:query_start_at] = format_time(time_range.begin) || 'none'
      data[:query_end_at]   = format_time(time_range.end) || 'none'
      data[:max_processes]  = max_processes
      data[:max_threads]    = max_threads
      data[:max_retries]    = max_retries
      data.compact_blank!
    end

    def format_time_range(range)
      "#{format_time(range.begin)}..#{format_time(range.end)}"
    end

    def format_time(time)
      time&.strftime('%Y-%m-%d %H:%M:%S %z')
    end

    def format_pid
      " PID #{@pid}" if @pid
    end
  end
end
