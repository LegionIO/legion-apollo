# frozen_string_literal: true

require 'spec_helper'
require 'sequel'
require 'sequel/extensions/migration'

RSpec.describe 'Apollo::Local ingest' do
  let(:db) { Sequel.sqlite }

  before do
    Legion::Apollo::Local.shutdown if Legion::Apollo::Local.started?

    local_db = db
    migration_path = File.expand_path('../../../../lib/legion/apollo/local/migrations', __dir__)
    Sequel::Migrator.run(local_db, migration_path, table: :schema_migrations_apollo_local)

    stub_const('Legion::Data::Local', Module.new do
      extend self

      define_method(:connected?) { true }
      define_method(:connection) { local_db }
      define_method(:register_migrations) { |**_| nil }
    end)

    Legion::Apollo::Local.start
  end

  after { Legion::Apollo::Local.shutdown }

  it 'inserts a knowledge entry' do
    result = Legion::Apollo::Local.ingest(content: 'Ruby is great', tags: %w[ruby])
    expect(result[:success]).to be true
    expect(result[:mode]).to eq(:local)
    expect(result[:id]).to be_a(Integer)
  end

  it 'stores content and tags' do
    Legion::Apollo::Local.ingest(content: 'Hello world', tags: %w[greeting])
    row = db[:local_knowledge].first
    expect(row[:content]).to eq('Hello world')
    expect(row[:tags]).to eq('["greeting"]')
  end

  it 'deduplicates by content hash' do
    Legion::Apollo::Local.ingest(content: 'same content', tags: %w[a])
    result = Legion::Apollo::Local.ingest(content: 'same content', tags: %w[b])
    expect(result[:mode]).to eq(:deduplicated)
    expect(db[:local_knowledge].count).to eq(1)
  end

  it 'sets expires_at based on retention_years setting' do
    Legion::Apollo::Local.ingest(content: 'test expiry', tags: [])
    row = db[:local_knowledge].first
    expires = Time.parse(row[:expires_at])
    expected_min = Time.now.utc + (4.9 * 365.25 * 24 * 3600)
    expect(expires).to be > expected_min
  end

  it 'stores embedding as nil when LLM is unavailable' do
    Legion::Apollo::Local.ingest(content: 'no embedding', tags: [])
    row = db[:local_knowledge].first
    expect(row[:embedding]).to be_nil
    expect(row[:embedded_at]).to be_nil
  end

  it 'stores embedding when LLM is available' do
    stub_const('Legion::LLM', Module.new do
      extend self

      define_method(:can_embed?) { true }
      define_method(:embed) { |_text, **_| { vector: Array.new(1024, 0.1), model: 'test' } }
    end)

    Legion::Apollo::Local.ingest(content: 'with embedding', tags: [])
    row = db[:local_knowledge].first
    expect(row[:embedding]).not_to be_nil
    expect(row[:embedded_at]).not_to be_nil
    parsed = Legion::JSON.parse(row[:embedding])
    expect(parsed.size).to eq(1024)
  end

  it 'returns not_started when not started' do
    Legion::Apollo::Local.shutdown
    result = Legion::Apollo::Local.ingest(content: 'test', tags: [])
    expect(result).to eq({ success: false, error: :not_started })
  end
end
