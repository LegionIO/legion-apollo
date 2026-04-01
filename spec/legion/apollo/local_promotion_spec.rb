# frozen_string_literal: true

RSpec.describe Legion::Apollo::Local do
  describe '.query_by_tags' do
    context 'when not started' do
      before { allow(described_class).to receive(:started?).and_return(false) }

      it 'returns error' do
        result = described_class.query_by_tags(tags: %w[bond calibration])
        expect(result[:success]).to be false
        expect(result[:error]).to eq(:not_started)
      end
    end

    context 'when started' do
      let(:mock_db) { double('db') }
      let(:mock_dataset) { double('dataset') }

      before do
        stub_const('Legion::Data::Local', Module.new do
          def self.connection; end
        end)
        allow(described_class).to receive(:started?).and_return(true)
        allow(Legion::Data::Local).to receive(:connection).and_return(mock_db)
        allow(mock_db).to receive(:[]).with(:local_knowledge).and_return(mock_dataset)
        allow(mock_dataset).to receive(:where).and_return(mock_dataset)
        allow(mock_dataset).to receive(:limit).and_return(mock_dataset)
        allow(mock_dataset).to receive(:all).and_return([
                                                          { id: 1, content: 'test',
tags: '["bond","calibration","weights"]', confidence: 0.8 }
                                                        ])
      end

      it 'filters by tag intersection' do
        result = described_class.query_by_tags(tags: %w[bond calibration])
        expect(result[:success]).to be true
        expect(result[:results].size).to eq(1)
      end

      it 'excludes entries missing requested tags' do
        result = described_class.query_by_tags(tags: %w[bond calibration nonexistent])
        expect(result[:success]).to be true
        expect(result[:results]).to be_empty
      end
    end
  end

  describe '.promote_to_global' do
    context 'when not started' do
      before { allow(described_class).to receive(:started?).and_return(false) }

      it 'returns error' do
        result = described_class.promote_to_global(tags: %w[bond])
        expect(result[:success]).to be false
        expect(result[:error]).to eq(:not_started)
      end
    end

    context 'when started with entries' do
      before do
        allow(described_class).to receive(:started?).and_return(true)
        allow(described_class).to receive(:query_by_tags).and_return({
                                                                       success: true,
                                                                       results: [
                                                                         { content: 'test data',
tags: '["bond","attachment"]', confidence: 0.8 }
                                                                       ]
                                                                     })
        allow(Legion::Apollo).to receive(:ingest).and_return({ success: true })
      end

      it 'promotes entries above confidence threshold' do
        result = described_class.promote_to_global(tags: %w[bond attachment], min_confidence: 0.6)
        expect(result[:success]).to be true
        expect(result[:promoted]).to eq(1)
      end

      it 'skips entries below confidence threshold' do
        allow(described_class).to receive(:query_by_tags).and_return({
                                                                       success: true,
                                                                       results: [{ content: 'low', tags: '["bond"]',
confidence: 0.3 }]
                                                                     })
        result = described_class.promote_to_global(tags: %w[bond], min_confidence: 0.6)
        expect(result[:promoted]).to eq(0)
      end

      it 'adds promoted_from_local tag' do
        expect(Legion::Apollo).to receive(:ingest).with(hash_including(
                                                          tags:           array_including('promoted_from_local'),
                                                          source_channel: 'local_promotion',
                                                          scope:          :global
                                                        ))
        described_class.promote_to_global(tags: %w[bond attachment])
      end
    end
  end
end
