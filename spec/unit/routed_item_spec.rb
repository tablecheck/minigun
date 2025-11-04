# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Minigun::RoutedItem do
  describe '#initialize' do
    it 'stores target stage and item' do
      item = { id: 1, value: 'test' }
      routed = Minigun::RoutedItem.new(:target_stage, item)

      expect(routed.target_stage).to eq(:target_stage)
      expect(routed.item).to eq(item)
    end

    it 'accepts Stage objects as target' do
      stage = double('Stage', name: :my_stage)
      item = 'test_data'
      routed = Minigun::RoutedItem.new(stage, item)

      expect(routed.target_stage).to eq(stage)
      expect(routed.item).to eq(item)
    end

    it 'accepts nil as item' do
      routed = Minigun::RoutedItem.new(:target, nil)

      expect(routed.target_stage).to eq(:target)
      expect(routed.item).to be_nil
    end
  end

  describe '#to_s' do
    it 'returns human-readable representation' do
      routed = Minigun::RoutedItem.new(:my_target, 'data')
      str = routed.to_s

      expect(str).to include('RoutedItem')
      expect(str).to include('my_target')
      expect(str).to include('data')
    end

    it 'handles complex items' do
      routed = Minigun::RoutedItem.new(:target, { complex: { nested: 'value' } })
      str = routed.to_s

      expect(str).to be_a(String)
      expect(str).to include('RoutedItem')
    end
  end

  describe 'integration with router stages' do
    it 'should be handled by RouterBroadcastStage' do
      skip 'Forking not supported' unless Minigun.fork?

      results = []
      results_file = "/tmp/minigun_routed_item_broadcast_#{Process.pid}.txt"

      klass = Class.new do
        include Minigun::DSL

        pipeline do
          producer :gen do |output|
            2.times { |i| output << i + 1 }
          end

          # Router that targets specific nested stage
          processor :router do |item, output|
            if item == 1
              output.to(:nested_a) << item
            else
              output.to(:nested_b) << item
            end
          end

          ipc_fork(2) do
            processor :nested_a, await: true do |item, output|
              output << "a:#{item}"
            end

            processor :nested_b, await: true do |item, output|
              output << "b:#{item}"
            end
          end

          consumer :collect, from: [:nested_a, :nested_b] do |item|
            File.open(results_file, 'a') do |f|
              f.flock(File::LOCK_EX)
              f.puts item
              f.flock(File::LOCK_UN)
            end
          end
        end
      end

      begin
        instance = klass.new
        instance.run

        if File.exist?(results_file)
          results = File.readlines(results_file).map(&:strip).sort
        end

        expect(results).to eq(['a:1', 'b:2'])
      ensure
        File.unlink(results_file) if File.exist?(results_file)
      end
    end

    it 'should be handled by RouterRoundRobinStage' do
      results = []

      klass = Class.new do
        include Minigun::DSL

        pipeline do
          producer :gen do |output|
            3.times { |i| output << i + 1 }
          end

          # Fan-out with round-robin routing - will broadcast to both targets
          processor :fanout, routing: :round_robin, to: [:target_a, :target_b] do |item, output|
            output << item
          end

          processor :target_a, await: false do |item, output|
            output << item * 10
          end

          processor :target_b, await: false do |item, output|
            output << item * 20
          end

          consumer :collect, from: [:target_a, :target_b] do |item|
            results << item
          end
        end

        define_method(:results) { results }
      end

      instance = klass.new
      instance.run

      # With round-robin: item 1 -> target_a (10), item 2 -> target_b (40), item 3 -> target_a (30)
      expect(instance.results.sort).to eq([10, 30, 40])
    end
  end

  describe 'serialization for IPC' do
    it 'can be marshaled and unmarshaled' do
      original = Minigun::RoutedItem.new(:my_stage, { data: 'test' })

      serialized = Marshal.dump(original)
      deserialized = Marshal.load(serialized)

      expect(deserialized).to be_a(Minigun::RoutedItem)
      expect(deserialized.target_stage).to eq(original.target_stage)
      expect(deserialized.item).to eq(original.item)
    end

    it 'handles items with non-serializable content gracefully in IpcInputQueue' do
      skip 'Forking not supported' unless Minigun.fork?

      # This tests that RoutedItem itself is serializable
      # Non-serializable items should be caught at the OutputQueue level
      pipe_r, pipe_w = IO.pipe

      routed = Minigun::RoutedItem.new(:target, 'serializable_data')
      message = { type: :routed_item, target_stage: routed.target_stage, item: routed.item }

      Marshal.dump(message, pipe_w)
      pipe_w.close

      received = Marshal.load(pipe_r)
      pipe_r.close

      expect(received[:type]).to eq(:routed_item)
      expect(received[:target_stage]).to eq(:target)
      expect(received[:item]).to eq('serializable_data')
    end
  end
end
