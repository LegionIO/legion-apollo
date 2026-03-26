# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Apollo do
  before { described_class.start }

  describe '.query with scope: :local' do
    context 'when Local is started' do
      before do
        allow(Legion::Apollo::Local).to receive(:started?).and_return(true)
        allow(Legion::Apollo::Local).to receive(:query).and_return(
          { success: true,
results: [{ id: 1, content: 'local fact', content_hash: 'abc', confidence: 0.8, tags: '[]' }], count: 1, mode: :local }
        )
      end

      it 'delegates to Local and normalizes to entries:' do
        result = described_class.query(text: 'test', scope: :local)
        expect(result[:success]).to be true
        expect(result[:entries]).to be_an(Array)
        expect(result[:entries].first[:content]).to eq('local fact')
      end
    end

    context 'when Local is not started' do
      it 'returns no_path_available' do
        result = described_class.query(text: 'test', scope: :local)
        expect(result).to eq({ success: false, error: :no_path_available })
      end
    end
  end

  describe '.query with scope: :all' do
    context 'when only Local is started' do
      before do
        allow(Legion::Apollo::Local).to receive(:started?).and_return(true)
        allow(Legion::Apollo::Local).to receive(:query).and_return(
          { success: true,
results: [{ id: 1, content: 'local fact', content_hash: 'abc', confidence: 0.8, tags: '[]' }], count: 1, mode: :local }
        )
      end

      it 'returns local entries in entries: key' do
        result = described_class.query(text: 'test', scope: :all)
        expect(result[:success]).to be true
        expect(result[:entries].first[:content]).to eq('local fact')
      end
    end
  end

  describe '.retrieve with scope: :all' do
    it 'delegates to query with scope: :all' do
      allow(described_class).to receive(:query).with(text: 'test', limit: 5,
                                                     scope: :all).and_return({ success: true, entries: [], count: 0 })
      described_class.retrieve(text: 'test', limit: 5, scope: :all)
      expect(described_class).to have_received(:query).with(text: 'test', limit: 5, scope: :all)
    end
  end
end
