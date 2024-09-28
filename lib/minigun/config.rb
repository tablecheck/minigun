# frozen_string_literal: true

module Minigun
  class Config
    extend self

    attr_writer :logger,
                :log_format,
                :log_writer,
                :max_processes,
                :max_threads,
                :max_retries
  end
end
