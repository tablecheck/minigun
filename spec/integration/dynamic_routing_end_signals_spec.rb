# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Dynamic routing END signal propagation' do
  it 'sends END signals to stages routed via .to()' do
    task_class = Class.new do
      include Minigun::DSL

      attr_reader :results

      def initialize
        @results = []
        @mutex = Mutex.new
      end

      pipeline do
        producer :source do |output|
          # Route only to target using .to()
          3.times { |i| output.to(:sink) << i }
        end

        consumer :sink do |item|
          @mutex.synchronize { @results << item }
        end
      end
    end

    task = task_class.new
    task.run

    # Should receive all items and terminate properly
    expect(task.results.sort).to eq([0, 1, 2])
  end

  it 'handles multiple .to() targets' do
    task_class = Class.new do
      include Minigun::DSL

      attr_reader :even_results, :odd_results

      def initialize
        @even_results = []
        @odd_results = []
        @mutex = Mutex.new
      end

      pipeline do
        producer :source do |output|
          # Route to different targets dynamically
          output.to(:even) << 2
          output.to(:odd) << 3
          output.to(:even) << 4
          output.to(:odd) << 5
        end

        consumer :even do |item|
          @mutex.synchronize { @even_results << item }
        end

        consumer :odd do |item|
          @mutex.synchronize { @odd_results << item }
        end
      end
    end

    task = task_class.new
    task.run

    expect(task.even_results.sort).to eq([2, 4])
    expect(task.odd_results.sort).to eq([3, 5])
  end

  it 'properly terminates stages with both static and dynamic inputs' do
    task_class = Class.new do
      include Minigun::DSL

      attr_reader :results

      def initialize
        @results = []
        @mutex = Mutex.new
      end

      pipeline do
        producer :static_source, to: :sink do |output|
          output << 1
          output << 2
        end

        producer :dynamic_source do |output|
          output.to(:sink) << 3
          output.to(:sink) << 4
        end

        consumer :sink do |item|
          @mutex.synchronize { @results << item }
        end
      end
    end

    task = task_class.new
    task.run

    # Should receive all items from both sources
    expect(task.results.sort).to eq([1, 2, 3, 4])
  end
end
