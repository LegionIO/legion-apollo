# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Apollo do
  before { described_class.start }

  describe '.ingest with scope: :local' do
    context 'when Local is started' do
      before do
        allow(Legion::Apollo::Local).to receive(:started?).and_return(true)
        allow(Legion::Apollo::Local).to receive(:ingest).and_return({ success: true, mode: :local, id: 42 })
      end

      it 'delegates to Local' do
        result = described_class.ingest(content: 'test fact', tags: %w[test], scope: :local)
        expect(result[:success]).to be true
        expect(result[:mode]).to eq(:local)
        expect(Legion::Apollo::Local).to have_received(:ingest).with(hash_including(content: 'test fact'))
      end
    end

    context 'when Local is not started' do
      it 'returns no_path_available' do
        result = described_class.ingest(content: 'test', scope: :local)
        expect(result).to eq({ success: false, error: :no_path_available })
      end
    end
  end

  describe '.ingest with scope: :all' do
    context 'when only local is started' do
      before do
        allow(Legion::Apollo::Local).to receive(:started?).and_return(true)
        allow(Legion::Apollo::Local).to receive(:ingest).and_return({ success: true, mode: :local, id: 1 })
      end

      it 'writes to local and returns success' do
        result = described_class.ingest(content: 'fact', tags: [], scope: :all)
        expect(result[:success]).to be true
        expect(Legion::Apollo::Local).to have_received(:ingest)
      end
    end
  end
end
