# frozen_string_literal: true

RSpec.describe Legion::Apollo do
  describe '.start' do
    it 'sets started? to true' do
      described_class.start
      expect(described_class.started?).to be true
    end

    it 'is idempotent' do
      described_class.start
      described_class.start
      expect(described_class.started?).to be true
    end
  end

  describe '.shutdown' do
    it 'sets started? to false' do
      described_class.start
      described_class.shutdown
      expect(described_class.started?).to be false
    end
  end

  describe '.query' do
    context 'when not started' do
      it 'returns not_started error' do
        result = described_class.query(text: 'test')
        expect(result).to eq({ success: false, error: :not_started })
      end
    end

    context 'when started but no transport or data' do
      before { described_class.start }

      it 'returns no_path_available' do
        result = described_class.query(text: 'test')
        expect(result).to eq({ success: false, error: :no_path_available })
      end
    end
  end

  describe '.ingest' do
    context 'when not started' do
      it 'returns not_started error' do
        result = described_class.ingest(content: 'test', tags: %w[test])
        expect(result).to eq({ success: false, error: :not_started })
      end
    end

    context 'when started but no transport or data' do
      before { described_class.start }

      it 'returns no_path_available' do
        result = described_class.ingest(content: 'test')
        expect(result).to eq({ success: false, error: :no_path_available })
      end
    end
  end

  describe '.retrieve' do
    it 'delegates to query' do
      described_class.start
      result = described_class.retrieve(text: 'test', limit: 3)
      expect(result).to eq({ success: false, error: :no_path_available })
    end
  end

  describe '.transport_available?' do
    it 'returns false by default' do
      described_class.start
      expect(described_class.transport_available?).to be false
    end

    it 'returns true when transport is connected' do
      Legion::Settings[:transport] = { connected: true }
      stub_const('Legion::Transport', Module.new)
      described_class.start
      expect(described_class.transport_available?).to be true
    end
  end

  describe '.data_available?' do
    it 'returns false by default' do
      described_class.start
      expect(described_class.data_available?).to be false
    end

    it 'returns true when data is connected' do
      Legion::Settings[:data] = { connected: true }
      stub_const('Legion::Data', Module.new)
      described_class.start
      expect(described_class.data_available?).to be true
    end
  end
end
