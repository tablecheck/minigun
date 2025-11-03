#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'lib/minigun'

class TestIpcBoth
  include Minigun::DSL

  attr_reader :results

  def initialize
    @results = []
    @results_file = "/tmp/test_ipc_both_#{Process.pid}.txt"
  end

  def cleanup
    File.unlink(@results_file) if File.exist?(@results_file)
  end

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

    ipc_fork(2) do
      consumer :collect do |item|
        puts "[Collect:ipc] #{item[:id]} = #{item[:value]} (PID #{Process.pid})"
        File.open(@results_file, 'a') do |f|
          f.flock(File::LOCK_EX)
          f.puts "#{item[:id]}:#{item[:value]}"
          f.flock(File::LOCK_UN)
        end
      end
    end

    after_run do
      if File.exist?(@results_file)
        @results = File.readlines(@results_file).map do |line|
          id, value = line.strip.split(':')
          { id: id.to_i, value: value.to_i }
        end
      end
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  example = TestIpcBoth.new
  begin
    puts "Testing IPC processor -> IPC consumer..."

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
    puts "Results: #{example.results.inspect}"
    example.cleanup
  rescue NotImplementedError => e
    puts "Fork not available: #{e.message}"
  end
end
