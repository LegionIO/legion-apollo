# frozen_string_literal: true

require 'sequel'
require 'sequel/extensions/migration'

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
      let(:db) { Sequel.sqlite }

      before do
        local_db = db
        stub_const('Legion::Data::Local', Module.new do
          extend self

          define_method(:connected?) { true }
          define_method(:connection) { local_db }
          define_method(:register_migrations) { |**_| nil }
        end)
        allow(described_class).to receive(:started?).and_return(true)
        Sequel::Migrator.run(local_db, described_class::MIGRATION_PATH)

        now = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%S.%LZ')
        expires_at = (Time.now.utc + 3600).strftime('%Y-%m-%dT%H:%M:%S.%LZ')

        db[:local_knowledge].insert(
          content:      'unrelated first row',
          content_hash: 'hash-unrelated',
          tags:         '["other"]',
          confidence:   0.3,
          expires_at:   expires_at,
          created_at:   now,
          updated_at:   now
        )
        db[:local_knowledge].insert(
          content:      'matching row one',
          content_hash: 'hash-match-1',
          tags:         '["bond","calibration","weights"]',
          confidence:   0.8,
          expires_at:   expires_at,
          created_at:   now,
          updated_at:   now
        )
        db[:local_knowledge].insert(
          content:      'matching row two',
          content_hash: 'hash-match-2',
          tags:         '["bond","calibration","second"]',
          confidence:   0.7,
          expires_at:   expires_at,
          created_at:   now,
          updated_at:   now
        )
      end

      it 'filters by tag intersection' do
        result = described_class.query_by_tags(tags: %w[bond calibration])
        expect(result[:success]).to be true
        expect(result[:results].size).to eq(2)
      end

      it 'excludes entries missing requested tags' do
        result = described_class.query_by_tags(tags: %w[bond calibration nonexistent])
        expect(result[:success]).to be true
        expect(result[:results]).to be_empty
      end

      it 'applies limit after filtering matching tags' do
        result = described_class.query_by_tags(tags: %w[bond calibration], limit: 1)

        expect(result[:success]).to be true
        expect(result[:results].size).to eq(1)
        parsed_tags = Legion::JSON.parse(result[:results].first[:tags])
        expect(parsed_tags).to include('bond', 'calibration')
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
