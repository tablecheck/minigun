# frozen_string_literal: true

require 'concurrent'
require 'securerandom'
require 'logger'
require 'English'

# Minigun is a high-performance data pipeline framework for Ruby
module Minigun
  class Error < StandardError; end

  # Simple logger
  @logger = Logger.new($stdout)
  @logger.level = Logger::INFO

  class << self
    attr_accessor :logger
  end
end

require_relative 'minigun/version'
require_relative 'minigun/configuration'
require_relative 'minigun/message'
require_relative 'minigun/queue_wrappers'
require_relative 'minigun/worker'
require_relative 'minigun/execution/executor'
require_relative 'minigun/stats'
require_relative 'minigun/stage'
require_relative 'minigun/dag'
require_relative 'minigun/pipeline'
require_relative 'minigun/runner'
require_relative 'minigun/task'
require_relative 'minigun/dsl'
