#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'lib/minigun'

class TestIpcDebug
  include Minigun::DSL

  pipeline do
    producer :generate do |output|
      puts '[Producer] Generating 3 items'
      3.times { |i| output << { id: i + 1, value: i + 1 } }
    end

    ipc_fork(2) do
      processor :double do |item, output|
        result = item.merge(value: item[:value] * 2)
        puts "[Double:ipc] #{item[:id]}: #{item[:value]} * 2 = #{result[:value]} (PID #{Process.pid})"
        output << result
      end
    end

    consumer :collect do |item|
      puts "[Collect] #{item[:id]} = #{item[:value]}"
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  require_relative 'lib/minigun/task'

  example = TestIpcDebug.new
  begin
    puts "Testing IPC processor -> inline consumer..."

    # Evaluate pipeline blocks to build the task
    example.send(:_evaluate_pipeline_blocks!)
    task = example.instance_variable_get(:@_minigun_task)

    puts "\n=== DAG Structure ==="
    task.stage_registry.instance_variable_get(:@all_stages).each do |stage|
      puts "Stage: #{stage.name} (#{stage.class.name})"
      puts "  Execution context: #{stage.execution_context&.inspect}"
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
