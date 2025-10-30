# frozen_string_literal: true

require 'minigun'
require 'rspec'
require 'timeout'
require 'benchmark'

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.filter_run_when_matching :focus
  config.example_status_persistence_file_path = 'spec/examples.txt'
  config.disable_monkey_patching!
  config.warnings = false

  config.default_formatter = 'doc' if config.files_to_run.one?

  config.order = :random
  Kernel.srand config.seed

  # Add timeout to all examples to prevent deadlocks
  config.around do |example|
    timeout_seconds = example.metadata[:timeout] || 3

    begin
      Timeout.timeout(timeout_seconds) do
        example.run
      end
    rescue Timeout::Error
      # Log detailed information about where the timeout occurred
      location = example.metadata[:location]
      description = example.metadata[:full_description]

      puts "\n#{'=' * 80}"
      puts "⚠️  TIMEOUT ERROR (#{timeout_seconds}s exceeded)"
      puts '=' * 80
      puts "Test: #{description}"
      puts "Location: #{location}"
      puts "#{'=' * 80}\n"

      # Re-raise with more context
      raise Timeout::Error, "Test timed out after #{timeout_seconds}s: #{description} (#{location})"
    end
  end
end
