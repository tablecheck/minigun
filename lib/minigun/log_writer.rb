# frozen_string_literal: true

module Minigun
  class LogWriter
    extend self

    private

    def logger
      Minigun.logger
    end

    def log_job_started
      Rails.logger.info { "#{job_name} started.\n#{job_info_message}" }
    end

    def log_job_finished
      Rails.logger.info { "#{job_name} finished.\n#{job_info_message(finished: true)}" }
    end

    def log_producer_start
      Rails.logger.info { "[Producer] Started master producer thread." }
    end

    def log_producer_finished(produced_count)
      Rails.logger.info { "[Producer] Done. #{produced_count} object IDs produced." }
    end

    private

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
      " PID #{Process.pid}"
    end
  end
end
