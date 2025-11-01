# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Minigun::EndOfSource do
  describe '#to_s and #inspect' do
    it 'provides readable string representation' do
      signal = described_class.new(:stage_a)

      expect(signal.to_s).to eq('EndOfSource(stage_a)')
      expect(signal.inspect).to eq('EndOfSource(stage_a)')
    end
  end

  describe 'inheritance' do
    it 'inherits from QueueSignal' do
      signal = described_class.new(:stage)

      expect(signal).to be_a(Minigun::QueueSignal)
    end
  end

  describe 'immutability' do
    it 'provides read-only access to source' do
      signal = described_class.new(:stage)

      expect { signal.source = :different }.to raise_error(NoMethodError)
    end
  end

  describe 'equality and comparison' do
    it 'creates distinct instances' do
      sig1 = described_class.new(:stage_a)
      sig2 = described_class.new(:stage_a)

      expect(sig1).not_to be(sig2)
    end

    it 'has same attributes for same parameters' do
      sig1 = described_class.new(:stage_a)
      sig2 = described_class.new(:stage_a)

      expect(sig1.stage).to eq(sig2.stage)
    end
  end
end

RSpec.describe Minigun::EndOfStage do
  describe '#to_s and #inspect' do
    it 'provides readable string representation' do
      signal = described_class.new(:my_stage)

      expect(signal.to_s).to eq('EndOfStage(my_stage)')
      expect(signal.inspect).to eq('EndOfStage(my_stage)')
    end
  end

  describe 'inheritance' do
    it 'inherits from QueueSignal' do
      signal = described_class.new(:stage)

      expect(signal).to be_a(Minigun::QueueSignal)
    end
  end

  describe 'immutability' do
    it 'provides read-only access to stage_name' do
      signal = described_class.new(:stage)

      expect { signal.stage_name = :different }.to raise_error(NoMethodError)
    end
  end
end

