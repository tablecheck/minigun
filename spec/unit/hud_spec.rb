# frozen_string_literal: true

require 'spec_helper'
require 'minigun/hud'

RSpec.describe Minigun::HUD do
  describe 'Terminal' do
    let(:terminal) { Minigun::HUD::Terminal.new }

    it 'initializes with default dimensions' do
      expect(terminal.width).to be > 0
      expect(terminal.height).to be > 0
    end

    it 'has color constants defined' do
      expect(Minigun::HUD::Terminal::COLORS).to be_a(Hash)
      expect(Minigun::HUD::Terminal::COLORS[:reset]).to eq("\e[0m")
      expect(Minigun::HUD::Terminal::COLORS[:green]).to be_a(String)
    end

    it 'can reset buffers' do
      expect { terminal.reset_buffers }.not_to raise_error
    end
  end

  describe 'Theme' do
    it 'provides color methods' do
      expect(Minigun::HUD::Theme.primary).to be_a(String)
      expect(Minigun::HUD::Theme.secondary).to be_a(String)
      expect(Minigun::HUD::Theme.success).to be_a(String)
    end

    it 'provides stage icons' do
      expect(Minigun::HUD::Theme.stage_icon(:producer)).to eq("▶")
      expect(Minigun::HUD::Theme.stage_icon(:processor)).to eq("◆")
      expect(Minigun::HUD::Theme.stage_icon(:consumer)).to eq("◀")
    end

    it 'provides status indicators' do
      expect(Minigun::HUD::Theme.status_indicator(:active)).to eq("⚡")
      expect(Minigun::HUD::Theme.status_indicator(:idle)).to eq("⏸")
      expect(Minigun::HUD::Theme.status_indicator(:bottleneck)).to eq("⚠")
    end

    it 'formats throughput with color' do
      result = Minigun::HUD::Theme.format_throughput(100)
      expect(result).to include("100")
      expect(result).to include("\e[") # Has ANSI color code
    end
  end

  describe 'Keyboard' do
    it 'matches quit keys' do
      expect(Minigun::HUD::Keyboard.matches?('q', :quit)).to be true
      expect(Minigun::HUD::Keyboard.matches?('Q', :quit)).to be true
      expect(Minigun::HUD::Keyboard.matches?('x', :quit)).to be false
    end

    it 'matches pause key' do
      expect(Minigun::HUD::Keyboard.matches?(' ', :pause)).to be true
      expect(Minigun::HUD::Keyboard.matches?('p', :pause)).to be false
    end

    it 'matches help keys' do
      expect(Minigun::HUD::Keyboard.matches?('h', :help)).to be true
      expect(Minigun::HUD::Keyboard.matches?('H', :help)).to be true
      expect(Minigun::HUD::Keyboard.matches?('?', :help)).to be true
    end
  end

  describe 'FlowDiagram' do
    let(:flow_diagram) { Minigun::HUD::FlowDiagram.new(40, 20) }

    it 'initializes with dimensions' do
      expect(flow_diagram.width).to eq(40)
      expect(flow_diagram.height).to eq(20)
    end
  end

  describe 'ProcessList' do
    let(:process_list) { Minigun::HUD::ProcessList.new(60, 20) }

    it 'initializes with dimensions' do
      expect(process_list.width).to eq(60)
      expect(process_list.height).to eq(20)
    end

    it 'has scroll offset' do
      expect(process_list.scroll_offset).to eq(0)
      process_list.scroll_offset = 5
      expect(process_list.scroll_offset).to eq(5)
    end
  end

  describe 'StatsAggregator' do
    let(:pipeline) do
      Class.new do
        include Minigun::DSL

        pipeline do
          producer :test_producer do |output|
            5.times { |i| output << i }
          end

          consumer :test_consumer do |item, _output|
            item # no-op
          end
        end
      end.new
    end

    let(:stats_aggregator) do
      # Initialize pipeline
      pipeline.send(:_evaluate_pipeline_blocks!)
      task = pipeline.instance_variable_get(:@_minigun_task)
      pipe = task.root_pipeline

      # Initialize stats manually since we're not running the pipeline
      pipe.instance_variable_set(:@stats, Minigun::AggregatedStats.new(pipe, pipe.dag))

      Minigun::HUD::StatsAggregator.new(pipe)
    end

    it 'initializes with pipeline' do
      expect(stats_aggregator.pipeline).to be_a(Minigun::Pipeline)
    end

    it 'collects stats data' do
      data = stats_aggregator.collect
      expect(data).to be_a(Hash)
      expect(data).to have_key(:pipeline_name)
      expect(data).to have_key(:stages)
      expect(data[:stages]).to be_an(Array)
    end
  end

  describe 'Controller' do
    let(:pipeline) do
      Class.new do
        include Minigun::DSL

        pipeline do
          producer :gen do |output|
            output << 1
          end

          consumer :consume do |_item, _output|
            # no-op
          end
        end
      end.new
    end

    let(:controller) do
      # Initialize pipeline
      pipeline.send(:_evaluate_pipeline_blocks!)
      task = pipeline.instance_variable_get(:@_minigun_task)
      pipe = task.root_pipeline

      # Initialize stats
      pipe.instance_variable_set(:@stats, Minigun::AggregatedStats.new(pipe, pipe.dag))

      Minigun::HUD::Controller.new(pipe)
    end

    it 'initializes with pipeline' do
      expect(controller.terminal).to be_a(Minigun::HUD::Terminal)
      expect(controller.flow_diagram).to be_a(Minigun::HUD::FlowDiagram)
      expect(controller.process_list).to be_a(Minigun::HUD::ProcessList)
      expect(controller.stats_aggregator).to be_a(Minigun::HUD::StatsAggregator)
    end

    it 'starts not running' do
      expect(controller.running).to be false
      expect(controller.paused).to be false
    end

    it 'can be stopped' do
      expect { controller.stop }.not_to raise_error
      expect(controller.running).to be false
    end
  end

  describe '.run_with_hud' do
    it 'requires a task with pipeline' do
      expect do
        Minigun::HUD.run_with_hud(Object.new)
      end.to raise_error(ArgumentError, /pipeline/)
    end
  end
end
