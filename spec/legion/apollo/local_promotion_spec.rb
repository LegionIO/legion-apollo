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

      it 'falls back to Ruby filtering for SQL compatibility errors while the DB is usable' do
        allow(db).to receive(:[]).and_raise(Sequel::DatabaseError, 'json_each unavailable')
        allow(described_class).to receive(:query_by_tags_via_ruby).and_return([{ content: 'fallback row' }])

        result = described_class.query_by_tags(tags: %w[bond calibration])

        expect(result[:success]).to be true
        expect(result[:results]).to eq([{ content: 'fallback row' }])
        expect(described_class).to have_received(:query_by_tags_via_ruby).with(
          db,
          tags:  %w[bond calibration],
          limit: 50
        )
      end
    end

    context 'when the local DB is unavailable' do
      before do
        stub_const('Legion::Data::Local', Module.new do
          extend self

          define_method(:connected?) { true }
          define_method(:connection) { nil }
        end)
        allow(described_class).to receive(:started?).and_return(true)
      end

      it 'returns not_started without querying SQL or Ruby fallback' do
        expect(described_class).not_to receive(:query_by_tags_via_sql)
        expect(described_class).not_to receive(:query_by_tags_via_ruby)

        result = described_class.query_by_tags(tags: %w[bond calibration])

        expect(result[:success]).to be false
        expect(result[:error]).to eq(:not_started)
      end
    end

    context 'when started changes before the query uses the DB' do
      let(:db) { Sequel.sqlite }

      before do
        local_db = db
        stub_const('Legion::Data::Local', Module.new do
          extend self

          define_method(:connected?) { true }
          define_method(:connection) { local_db }
        end)
        allow(described_class).to receive(:started?).and_return(true, false)
      end

      it 'returns not_started before SQL or Ruby fallback reads local_knowledge' do
        expect(described_class).not_to receive(:query_by_tags_via_sql)
        expect(described_class).not_to receive(:query_by_tags_via_ruby)

        result = described_class.query_by_tags(tags: %w[bond calibration])

        expect(result[:success]).to be false
        expect(result[:error]).to eq(:not_started)
      end
    end

    context 'when the DB becomes unavailable after SQL raises' do
      let(:db) { Sequel.sqlite }

      before do
        local_db = db
        stub_const('Legion::Data::Local', Module.new do
          extend self

          define_method(:connected?) { true }
          define_method(:connection) { local_db }
        end)
        allow(described_class).to receive(:started?).and_return(true, true, false)
        allow(db).to receive(:[]).and_raise(Sequel::DatabaseConnectionError, 'closed')
      end

      it 'does not fall back to Ruby filtering' do
        expect(described_class).not_to receive(:query_by_tags_via_ruby)

        result = described_class.query_by_tags(tags: %w[bond calibration])

        expect(result[:success]).to be false
        expect(result[:error]).to eq('closed')
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
        allow(described_class).to receive(:local_db_connection).and_return(double('local_db'))
        allow(described_class).to receive(:local_db_usable?).and_return(true)
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

    context 'when query_by_tags detects shutdown during promotion' do
      before do
        allow(described_class).to receive(:local_db_connection).and_return(double('local_db'))
        allow(described_class).to receive(:local_db_usable?).and_return(true)
        allow(described_class).to receive(:query_by_tags).and_return({ success: false, error: :not_started })
      end

      it 'propagates the availability failure instead of reporting zero promoted' do
        result = described_class.promote_to_global(tags: %w[bond])

        expect(result[:success]).to be false
        expect(result[:error]).to eq(:not_started)
      end
    end
  end
end
