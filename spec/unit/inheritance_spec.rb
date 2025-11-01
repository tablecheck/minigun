# frozen_string_literal: true

require 'spec_helper'
require 'tempfile'

RSpec.describe 'Class Inheritance with Minigun DSL' do
  before do
    allow(Minigun.logger).to receive(:info)
  end

  describe 'basic inheritance' do
    let(:parent_class) do
      Class.new do
        include Minigun::DSL

        max_threads 10
        max_processes 2

        attr_accessor :results

        def initialize
          @results = []
        end

        pipeline do
          producer :generate do |output|
            output << 1
            output << 2
          end

          processor :transform do |num, output|
            output << (num * 2)
          end

          consumer :collect do |num|
            @results << num
          end
        end
      end
    end

    let(:child_class) do
      Class.new(parent_class)
    end

    it 'child inherits parent stages' do
      child = child_class.new
      child.run

      expect(child.results).to contain_exactly(2, 4)
    end

    it 'child has its own task instance' do
      expect(child_class._minigun_task).not_to be(parent_class._minigun_task)
    end

    it 'child has a copy of parent pipeline (stages)' do
      # Pipelines are duplicated, not shared
      expect(child_class._minigun_task.root_pipeline).not_to be(parent_class._minigun_task.root_pipeline)

      # But they should have the same stages
      expect(child_class._minigun_task.root_pipeline.find_stage(:producer)&.name).to eq(parent_class._minigun_task.root_pipeline.find_stage(:producer)&.name)
    end

    it 'child inherits parent config' do
      parent_config = parent_class._minigun_task.config
      child_config = child_class._minigun_task.config

      expect(child_config[:max_threads]).to eq(10)
      expect(child_config[:max_processes]).to eq(2)
      expect(parent_config).not_to be(child_config) # Different objects
    end
  end

  describe 'child can add stages' do
    let(:parent_class) do
      Class.new do
        include Minigun::DSL

        attr_accessor :results

        def initialize
          @results = []
        end

        pipeline do
          producer :generate do |output|
            output << 1
            output << 2
          end

          consumer :collect do |num|
            @results << num
          end
        end
      end
    end

    let(:child_class) do
      Class.new(parent_class) do
        pipeline do
          processor :double do |num, output|
            output << (num * 2)
          end

          # Reroute: generate -> double -> collect (instead of generate -> collect)
          reroute_stage :generate, to: :double
          reroute_stage :double, to: :collect
        end
      end
    end

    it 'child can add new stages to inherited pipeline' do
      child = child_class.new
      child.run

      # With processor added, values should be doubled
      expect(child.results).to contain_exactly(2, 4)
    end

    it 'parent is unaffected by child stages' do
      parent = parent_class.new
      parent.run

      # Parent doesn't have the processor
      expect(parent.results).to contain_exactly(1, 2)
    end
  end

  describe 'child inherits hooks' do
    let(:parent_class) do
      Class.new do
        include Minigun::DSL

        attr_accessor :events

        def initialize
          @events = []
        end

        pipeline do
          before_run do
            @events << :parent_before_run
          end

          after_run do
            @events << :parent_after_run
          end

          producer :generate do |output|
            @events << :generate
            output << 1
          end

          after :generate do
            @events << :parent_after_generate
          end

          consumer :collect do |num|
          end
        end
      end
    end

    let(:child_class) do
      Class.new(parent_class)
    end

    it 'child executes parent hooks' do
      child = child_class.new
      child.run

      expect(child.events).to include(:parent_before_run)
      expect(child.events).to include(:parent_after_run)
      expect(child.events).to include(:parent_after_generate)
    end
  end

  describe 'child can add hooks' do
    let(:parent_class) do
      Class.new do
        include Minigun::DSL

        attr_accessor :events

        def initialize
          @events = []
        end

        pipeline do
          producer :generate do |output|
            @events << :generate
            output << 1
          end

          consumer :collect do |num|
          end
        end
      end
    end

    let(:child_class) do
      Class.new(parent_class) do
        pipeline do
          before_run do
            @events << :child_before_run
          end

          after :generate do
            @events << :child_after_generate
          end
        end
      end
    end

    it 'child can add its own hooks' do
      child = child_class.new
      child.run

      expect(child.events).to include(:child_before_run)
      expect(child.events).to include(:child_after_generate)
    end
  end

  describe 'child can override config' do
    let(:parent_class) do
      Class.new do
        include Minigun::DSL

        max_threads 5
        max_processes 2

        pipeline do
          producer :generate do |output|
            output << 1
          end

          consumer :collect do |num|
          end
        end
      end
    end

    let(:child_class) do
      Class.new(parent_class) do
        max_threads 20
      end
    end

    it 'child has different config from parent' do
      expect(parent_class._minigun_task.config[:max_threads]).to eq(5)
      expect(child_class._minigun_task.config[:max_threads]).to eq(20)
    end

    it 'child inherits non-overridden config' do
      expect(child_class._minigun_task.config[:max_processes]).to eq(2)
    end
  end

  describe 'multi-level inheritance' do
    let(:grandparent_class) do
      Class.new do
        include Minigun::DSL

        max_threads 10

        attr_accessor :results

        def initialize
          @results = []
        end

        pipeline do
          producer :generate do |output|
            output << 1
          end

          consumer :collect do |num|
            @results << num
          end
        end
      end
    end

    let(:parent_class) do
      Class.new(grandparent_class) do
        max_threads 20

        pipeline do
          processor :double do |num, output|
            output << (num * 2)
          end

          # Reroute: generate -> double -> collect (instead of generate -> collect)
          reroute_stage :generate, to: :double
          reroute_stage :double, to: :collect
        end
      end
    end

    let(:child_class) do
      Class.new(parent_class) do
        max_threads 30

        pipeline do
          processor :add_ten do |num, output|
            output << (num + 10)
          end

          # Reroute: generate -> double -> add_ten -> collect
          reroute_stage :double, to: :add_ten
          reroute_stage :add_ten, to: :collect
        end
      end
    end

    it 'grandchild inherits all ancestor stages' do
      child = child_class.new
      child.run

      # 1 -> double (2) -> add_ten (12)
      expect(child.results).to eq([12])
    end

    it 'grandchild has correct config' do
      expect(child_class._minigun_task.config[:max_threads]).to eq(30)
    end

    it 'each level can run independently' do
      grandparent = grandparent_class.new
      grandparent.run
      expect(grandparent.results).to eq([1])

      parent = parent_class.new
      parent.run
      expect(parent.results).to eq([2])

      child = child_class.new
      child.run
      expect(child.results).to eq([12])
    end
  end

  describe 'sibling classes independence' do
    let(:parent_class) do
      Class.new do
        include Minigun::DSL

        attr_accessor :results

        def initialize
          @results = []
        end

        pipeline do
          producer :generate do |output|
            output << 10
          end

          consumer :collect do |num|
            @results << num
          end
        end
      end
    end

    let(:child_a) do
      Class.new(parent_class) do
        pipeline do
          processor :double do |num, output|
            output << (num * 2)
          end

          # Reroute: generate -> double -> collect
          reroute_stage :generate, to: :double
          reroute_stage :double, to: :collect
        end
      end
    end

    let(:child_b) do
      Class.new(parent_class) do
        pipeline do
          processor :triple do |num, output|
            output << (num * 3)
          end

          # Reroute: generate -> triple -> collect
          reroute_stage :generate, to: :triple
          reroute_stage :triple, to: :collect
        end
      end
    end

    it 'siblings have independent stages' do
      a = child_a.new
      a.run
      expect(a.results).to eq([20])

      b = child_b.new
      b.run
      expect(b.results).to eq([30])
    end
  end

  describe 'real-world pattern: base publisher with subclasses' do
    let(:base_publisher) do
      Class.new do
        include Minigun::DSL

        max_threads 10
        max_processes 2

        attr_accessor :published, :connected, :disconnected

        def initialize
          @published = []
          @connected = false
          @disconnected = false
          @temp_file = Tempfile.new(['minigun_inheritance', '.txt'])
          @temp_file.close
        end

        def cleanup
          File.unlink(@temp_file.path) if @temp_file && File.exist?(@temp_file.path)
        end

        pipeline do
          before_fork do
            disconnect_db
          end

          after_fork do
            connect_db
          end

          producer :fetch_ids do |output|
            items_to_publish.each { |item| output << item }
          end

          accumulator :batch

          process_per_batch(max: 1) do
            consumer :publish do |batch|
              # process_per_batch receives batches from accumulator
              # Write to temp file (fork-safe)
              File.open(@temp_file.path, 'a') do |f|
                f.flock(File::LOCK_EX)
                batch.each { |item| f.puts(publish_item(item)) }
                f.flock(File::LOCK_UN)
              end
            end
          end

          after_run do
            # Read fork results from temp file
            @published = File.readlines(@temp_file.path).map(&:strip) if File.exist?(@temp_file.path)
          end
        end

        def items_to_publish
          raise NotImplementedError, 'Subclass must implement'
        end

        def publish_item(item)
          raise NotImplementedError, 'Subclass must implement'
        end

        def disconnect_db
          @disconnected = true
        end

        def connect_db
          @connected = true
        end
      end
    end

    let(:customer_publisher) do
      Class.new(base_publisher) do
        def items_to_publish
          %w[customer_1 customer_2]
        end

        def publish_item(item)
          "Customer: #{item}"
        end
      end
    end

    let(:order_publisher) do
      Class.new(base_publisher) do
        max_threads 20 # Override for more throughput

        def items_to_publish
          %w[order_1 order_2 order_3]
        end

        def publish_item(item)
          "Order: #{item}"
        end
      end
    end

    it 'customer publisher works' do
      publisher = customer_publisher.new
      begin
        publisher.run

        expect(publisher.published).to include('Customer: customer_1', 'Customer: customer_2')
      ensure
        publisher.cleanup
      end
    end

    it 'order publisher works with overridden config' do
      publisher = order_publisher.new
      begin
        publisher.run

        expect(publisher.published).to include('Order: order_1', 'Order: order_2', 'Order: order_3')
        expect(order_publisher._minigun_task.config[:max_threads]).to eq(20)
      ensure
        publisher.cleanup
      end
    end

    it 'base publisher cannot run (abstract)' do
      publisher = base_publisher.new
      expect { publisher.run }.to raise_error(NotImplementedError)
    end
  end
end
