#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'lib/minigun'

# Copy of working example 70
class TestWorking
  include Minigun::DSL

  pipeline do
    producer :generate do |output|
      3.times { |i| output << { id: i + 1 } }
    end

    thread_pool(2) do
      processor :process do |item, output|
        output << item
      end
    end

    ipc_fork(2) do
      consumer :collect do |item|
        puts "[Collect] #{item[:id]}"
      end
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  example = TestWorking.new
  begin
    puts "Testing working example..."

    # Evaluate pipeline blocks to build the task
    example.send(:_evaluate_pipeline_blocks!)
    task = example.instance_variable_get(:@_minigun_task)

    puts "\n=== DAG Structure ==="
    task.stage_registry.instance_variable_get(:@all_stages).each do |stage|
      puts "Stage: #{stage.name} (#{stage.class.name})"
      upstreams = task.dag.upstream(stage)
      puts "  Upstreams: #{upstreams.map(&:name).inspect}"
      downstreams = task.dag.downstream(stage)
      puts "  Downstreams: #{downstreams.map(&:name).inspect}"
    end
    puts "=" * 50

    example.run
  rescue NotImplementedError => e
    puts "Fork not available: #{e.message}"
  end
end
