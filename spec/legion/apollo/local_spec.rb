# frozen_string_literal: true

require 'spec_helper'
require 'sequel'
require 'sequel/extensions/migration'

RSpec.describe Legion::Apollo::Local do
  before do
    described_class.shutdown if described_class.started?
  end

  describe '.start / .shutdown / .started?' do
    it 'is not started by default' do
      expect(described_class.started?).to be false
    end

    context 'when Data::Local is available' do
      let(:db) { Sequel.sqlite }

      before do
        stub_const('Legion::Data::Local', Module.new do
          extend self

          define_method(:connected?) { true }
          define_method(:connection) { db }
          define_method(:register_migrations) { |**_| nil }
        end)
        allow(Legion::Data::Local).to receive(:register_migrations)
      end

      it 'starts and registers migrations' do
        described_class.start
        expect(described_class.started?).to be true
        expect(Legion::Data::Local).to have_received(:register_migrations).with(
          name: :apollo_local, path: anything
        )
      end

      it 'shuts down cleanly' do
        described_class.start
        described_class.shutdown
        expect(described_class.started?).to be false
      end
    end

    context 'when Data::Local is not available' do
      it 'does not start' do
        described_class.start
        expect(described_class.started?).to be false
      end
    end

    context 'when disabled in settings' do
      before do
        Legion::Settings[:apollo][:local][:enabled] = false
      end

      it 'does not start' do
        described_class.start
        expect(described_class.started?).to be false
      end
    end
  end

  describe '#upsert' do
    let(:db) { Sequel.sqlite }

    before do
      local_db = db
      stub_const('Legion::Data::Local', Module.new do
        extend self

        define_method(:connected?) { true }
        define_method(:connection) { local_db }
        define_method(:register_migrations) { |**_| nil }
      end)
      Sequel::Migrator.run(local_db, described_class::MIGRATION_PATH)
      described_class.start
    end

    after { described_class.reset! }

    it 'inserts a new entry when no matching tags exist' do
      result = described_class.upsert(
        content:        'initial state',
        tags:           %w[social_graph reputation agent-123],
        source_channel: 'gaia',
        confidence:     0.9
      )
      expect(result[:success]).to be true
      expect(result[:mode]).to eq(:inserted)
    end

    it 'updates existing entry when matching tags found' do
      described_class.upsert(
        content:        'initial state',
        tags:           %w[social_graph reputation agent-123],
        source_channel: 'gaia'
      )
      result = described_class.upsert(
        content:        'updated state',
        tags:           %w[social_graph reputation agent-123],
        source_channel: 'gaia'
      )
      expect(result[:success]).to be true
      expect(result[:mode]).to eq(:updated)

      query_result = described_class.query(text: 'updated state', tags: %w[social_graph reputation agent-123])
      expect(query_result[:results].size).to eq(1)
      expect(query_result[:results].first[:content]).to eq('updated state')
    end

    it 'matches tags exactly — different tags create new entry' do
      described_class.upsert(content: 'A', tags: %w[social_graph reputation agent-123])
      described_class.upsert(content: 'B', tags: %w[social_graph reputation agent-456])

      result_a = described_class.query(text: '', tags: %w[agent-123])
      result_b = described_class.query(text: '', tags: %w[agent-456])
      expect(result_a[:results].size).to eq(1)
      expect(result_a[:results].first[:content]).to eq('A')
      expect(result_b[:results].size).to eq(1)
      expect(result_b[:results].first[:content]).to eq('B')
    end

    it 'returns not_started when store is not running' do
      described_class.reset!
      result = described_class.upsert(content: 'x', tags: ['a'])
      expect(result[:success]).to be false
    end

    it 'handles tag order normalization' do
      described_class.upsert(content: 'first', tags: %w[b a c])
      result = described_class.upsert(content: 'second', tags: %w[c a b])
      expect(result[:mode]).to eq(:updated)
    end

    it 'refreshes expires_at and embedding metadata when updating an expired row' do
      tags = %w[social_graph reputation agent-123]
      create_result = described_class.upsert(content: 'initial state', tags: tags, source_channel: 'gaia')
      row_id = create_result[:id]
      expired_at = (Time.now.utc - 3600).strftime('%Y-%m-%dT%H:%M:%S.%LZ')
      db[:local_knowledge].where(id: row_id).update(expires_at: expired_at, embedding: nil, embedded_at: nil)

      stub_const('Legion::LLM', Module.new do
        extend self

        define_method(:can_embed?) { true }
        define_method(:embed) { |_text, **_| { vector: Array.new(8, 0.25), model: 'test' } }
      end)

      result = described_class.upsert(content: 'refreshed state', tags: tags, source_channel: 'gaia')
      expect(result).to include(success: true, mode: :updated, id: row_id)

      row = db[:local_knowledge].where(id: row_id).first
      expect(Time.parse(row[:expires_at])).to be > Time.now.utc
      expect(row[:embedding]).not_to be_nil
      expect(row[:embedded_at]).not_to be_nil

      query_result = described_class.query(text: 'refreshed state', tags: tags)
      expect(query_result[:success]).to be true
      expect(query_result[:results].map { |entry| entry[:id] }).to include(row_id)
    end
  end

  describe '#seed_self_knowledge' do
    let(:db) { Sequel.sqlite }

    before do
      local_db = db
      stub_const('Legion::Data::Local', Module.new do
        extend self

        define_method(:connected?) { true }
        define_method(:connection) { local_db }
        define_method(:register_migrations) { |**_| nil }
      end)
      Sequel::Migrator.run(local_db, described_class::MIGRATION_PATH)
      described_class.start
    end

    after { described_class.reset! }

    it 'ingests the partner seed file' do
      described_class.seed_self_knowledge
      result = described_class.query(text: 'partner', tags: ['self-knowledge'])
      partner_entries = result[:results].select do |r|
        parsed_tags = begin
          Legion::JSON.parse(r[:tags])
        rescue StandardError
          []
        end
        parsed_tags.include?('11-my-partner')
      end
      expect(partner_entries).not_to be_empty
    end
  end
end
