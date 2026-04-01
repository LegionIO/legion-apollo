# frozen_string_literal: true

RSpec.describe Legion::Apollo::Local do
  describe '.hydrate_from_global' do
    context 'when not started' do
      before { allow(described_class).to receive(:started?).and_return(false) }

      it 'returns error' do
        result = described_class.hydrate_from_global
        expect(result[:success]).to be false
        expect(result[:error]).to eq(:not_started)
      end
    end

    context 'when local partner data exists' do
      before do
        allow(described_class).to receive(:started?).and_return(true)
        allow(described_class).to receive(:query_by_tags).and_return({
                                                                       success: true,
                                                                       results: [{ content: 'existing partner data' }]
                                                                     })
      end

      it 'skips hydration' do
        result = described_class.hydrate_from_global
        expect(result[:skipped]).to eq(:local_data_exists)
      end
    end

    context 'when no local data and global has entries' do
      before do
        allow(described_class).to receive(:started?).and_return(true)
        allow(described_class).to receive(:query_by_tags).and_return({ success: true, results: [] })
        allow(Legion::Apollo).to receive(:transport_available?).and_return(true)
        allow(Legion::Apollo).to receive(:data_available?).and_return(false)
        allow(Legion::Apollo).to receive(:retrieve).and_return({
                                                                 success: true,
                                                                 results: [
                                                                   { content: 'partner bond data',
tags: %w[bond attachment promoted_from_local], confidence: 0.8 }
                                                                 ]
                                                               })
        allow(described_class).to receive(:ingest).and_return({ success: true })
      end

      it 'hydrates from global' do
        result = described_class.hydrate_from_global
        expect(result[:success]).to be true
        expect(result[:hydrated]).to eq(1)
      end

      it 'applies 0.9 confidence discount' do
        expect(described_class).to receive(:ingest).with(hash_including(confidence: 0.72))
        described_class.hydrate_from_global
      end

      it 'strips promoted_from_local and adds hydrated_from_global tag' do
        described_class.hydrate_from_global
        expect(described_class).to have_received(:ingest) do |args|
          expect(args[:tags]).not_to include('promoted_from_local')
          expect(args[:tags]).to include('hydrated_from_global')
        end
      end
    end

    context 'when global unavailable' do
      before do
        allow(described_class).to receive(:started?).and_return(true)
        allow(described_class).to receive(:query_by_tags).and_return({ success: true, results: [] })
        allow(Legion::Apollo).to receive(:transport_available?).and_return(false)
        allow(Legion::Apollo).to receive(:data_available?).and_return(false)
      end

      it 'skips gracefully' do
        result = described_class.hydrate_from_global
        expect(result[:skipped]).to eq(:global_unavailable)
      end
    end
  end
end
