# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Apollo::Runners::Request do
  describe '.retrieve' do
    it 'delegates to Legion::Apollo.retrieve with scope: :all' do
      allow(Legion::Apollo).to receive(:retrieve).and_return({ success: true, entries: [], count: 0 })
      described_class.retrieve(text: 'test query', limit: 5)
      expect(Legion::Apollo).to have_received(:retrieve).with(text: 'test query', limit: 5, scope: :all)
    end

    it 'returns the result from Legion::Apollo.retrieve' do
      expected = { success: true, entries: [{ id: 1, content: 'fact' }], count: 1 }
      allow(Legion::Apollo).to receive(:retrieve).and_return(expected)
      result = described_class.retrieve(text: 'query')
      expect(result).to eq(expected)
    end

    it 'forwards extra kwargs to Legion::Apollo.retrieve' do
      allow(Legion::Apollo).to receive(:retrieve).and_return({ success: true, entries: [], count: 0 })
      described_class.retrieve(text: 'test', limit: 3, min_confidence: 0.7)
      expect(Legion::Apollo).to have_received(:retrieve).with(
        text: 'test', limit: 3, scope: :all, min_confidence: 0.7
      )
    end
  end
end
