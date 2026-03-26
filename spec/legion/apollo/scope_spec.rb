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

    context 'when both global (co-located) and local return overlapping results' do
      let(:shared_hash) { 'dupe_hash_001' }
      let(:global_entry) do
        { id: 10, content: 'shared fact', content_hash: shared_hash, confidence: 0.9, content_type: 'fact', tags: [] }
      end
      let(:local_entry) { { id: 20, content: 'shared fact', content_hash: shared_hash, confidence: 0.7, tags: '[]' } }
      let(:unique_local) do
        { id: 21, content: 'unique local', content_hash: 'unique_001', confidence: 0.5, tags: '[]' }
      end

      before do
        allow(described_class).to receive(:co_located_reader?).and_return(true)
        allow(described_class).to receive(:direct_query).and_return(
          { success: true, entries: [global_entry] }
        )
        allow(Legion::Apollo::Local).to receive(:started?).and_return(true)
        allow(Legion::Apollo::Local).to receive(:query).and_return(
          { success: true, results: [local_entry, unique_local] }
        )
      end

      it 'deduplicates entries by content_hash, keeping the higher-confidence version' do
        result = described_class.query(text: 'test', scope: :all)
        expect(result[:success]).to be true
        hashes = result[:entries].map { |e| e[:content_hash] }
        expect(hashes.uniq).to eq(hashes)
        shared = result[:entries].find { |e| e[:content_hash] == shared_hash }
        expect(shared[:confidence]).to eq(0.9)
      end

      it 'ranks entries by confidence descending' do
        result = described_class.query(text: 'test', scope: :all)
        confidences = result[:entries].map { |e| e[:confidence] }
        expect(confidences).to eq(confidences.sort.reverse)
      end

      it 'respects the limit parameter' do
        result = described_class.query(text: 'test', limit: 1, scope: :all)
        expect(result[:entries].size).to eq(1)
      end
    end

    context 'when both sources fail' do
      before do
        allow(described_class).to receive(:co_located_reader?).and_return(true)
        allow(described_class).to receive(:direct_query).and_return({ success: false, error: 'db error' })
        allow(Legion::Apollo::Local).to receive(:started?).and_return(true)
        allow(Legion::Apollo::Local).to receive(:query).and_return({ success: false, error: 'local error' })
      end

      it 'returns success: false with combined error message' do
        result = described_class.query(text: 'test', scope: :all)
        expect(result[:success]).to be false
        expect(result[:error]).to include('db error')
        expect(result[:error]).to include('local error')
      end
    end

    context 'when no sources are available' do
      before do
        allow(described_class).to receive(:co_located_reader?).and_return(false)
        allow(Legion::Apollo::Local).to receive(:started?).and_return(false)
      end

      it 'returns no_path_available' do
        result = described_class.query(text: 'test', scope: :all)
        expect(result).to eq({ success: false, error: :no_path_available })
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

    it 'forwards extra kwargs through to query' do
      allow(described_class).to receive(:query).and_return({ success: true, entries: [], count: 0 })
      described_class.retrieve(text: 'test', scope: :all, min_confidence: 0.6)
      expect(described_class).to have_received(:query).with(
        hash_including(min_confidence: 0.6, scope: :all)
      )
    end
  end
end
