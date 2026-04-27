# frozen_string_literal: true

require 'spec_helper'
require 'sequel'
require 'sequel/extensions/migration'

RSpec.describe 'Apollo::Local query' do
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

    Legion::Apollo::Local.ingest(content: 'RabbitMQ clustering works by mirroring queues', tags: %w[rabbitmq amqp])
    Legion::Apollo::Local.ingest(content: 'Redis supports pub/sub messaging', tags: %w[redis cache])
    Legion::Apollo::Local.ingest(content: 'PostgreSQL has pgvector for embeddings', tags: %w[postgres vector])
  end

  after { Legion::Apollo::Local.shutdown }

  it 'returns matching results' do
    result = Legion::Apollo::Local.query(text: 'RabbitMQ')
    expect(result[:success]).to be true
    expect(result[:results]).not_to be_empty
    expect(result[:results].first[:content]).to include('RabbitMQ')
  end

  it 'flattens structured text blocks before FTS search and reranking' do
    result = Legion::Apollo::Local.query(text: [{ type: 'text', text: 'RabbitMQ' }])
    expect(result[:success]).to be true
    expect(result[:results]).not_to be_empty
    expect(result[:results].first[:content]).to include('RabbitMQ')
  end

  it 'respects limit' do
    result = Legion::Apollo::Local.query(text: 'messaging', limit: 1)
    expect(result[:results].size).to be <= 1
  end

  it 'filters by tags' do
    result = Legion::Apollo::Local.query(text: 'clustering', tags: %w[redis])
    matching = result[:results].select { |r| r[:content].include?('RabbitMQ') }
    expect(matching).to be_empty
  end

  it 'supports blank text queries when tags narrow the result set' do
    result = Legion::Apollo::Local.query(text: '', tags: %w[rabbitmq])

    expect(result[:success]).to be true
    expect(result[:results]).not_to be_empty
    expect(result[:results].map { |entry| entry[:content] }).to include('RabbitMQ clustering works by mirroring queues')
  end

  it 'normalizes filter tags for direct callers' do
    Legion::Apollo::Local.ingest(content: 'Bond state change', tags: ['Team Bond'])

    result = Legion::Apollo::Local.query(text: 'Bond', tags: ['team bond'])

    expect(result[:success]).to be true
    expect(result[:results].map { |entry| entry[:content] }).to include('Bond state change')
  end

  it 'filters by min_confidence' do
    Legion::Apollo::Local.ingest(content: 'low confidence entry about queues', tags: %w[test], confidence: 0.1)
    result = Legion::Apollo::Local.query(text: 'queues', min_confidence: 0.5)
    result[:results].each do |r|
      expect(r[:confidence]).to be >= 0.5
    end
  end

  it 'excludes expired entries' do
    now = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%S.%LZ')
    past = (Time.now.utc - 3600).strftime('%Y-%m-%dT%H:%M:%S.%LZ')
    db[:local_knowledge].insert(
      content: 'expired entry', content_hash: 'expired123', tags: '["test"]',
      confidence: 1.0, expires_at: past, created_at: now, updated_at: now
    )
    fts_id = db[:local_knowledge].max(:id)
    db.run("INSERT INTO local_knowledge_fts(rowid, content, tags) VALUES (#{fts_id}, 'expired entry', '[\"test\"]')")
    result = Legion::Apollo::Local.query(text: 'expired')
    expired_results = result[:results].select { |r| r[:content] == 'expired entry' }
    expect(expired_results).to be_empty
  end

  it 'filters local query results by temporal validity windows' do
    Legion::Apollo::Local.ingest(
      content:    'Q2 policy is active',
      tags:       %w[policy],
      valid_from: '2026-04-01T00:00:00Z',
      valid_to:   '2026-06-30T23:59:59Z'
    )
    Legion::Apollo::Local.ingest(
      content:    'Q3 policy is active',
      tags:       %w[policy],
      valid_from: '2026-07-01T00:00:00Z',
      valid_to:   '2026-09-30T23:59:59Z'
    )

    result = Legion::Apollo::Local.query(
      text:  'policy active',
      tags:  %w[policy],
      as_of: '2026-05-01T00:00:00Z'
    )

    expect(result[:success]).to be true
    expect(result[:results].map { |entry| entry[:content] }).to include('Q2 policy is active')
    expect(result[:results].map { |entry| entry[:content] }).not_to include('Q3 policy is active')
  end

  it 'applies temporal validity windows to blank local queries' do
    Legion::Apollo::Local.ingest(
      content:    'Current temporal fact',
      tags:       %w[temporal],
      valid_from: '2026-01-01T00:00:00Z',
      valid_to:   '2026-12-31T23:59:59Z'
    )
    Legion::Apollo::Local.ingest(
      content:    'Future temporal fact',
      tags:       %w[temporal],
      valid_from: '2027-01-01T00:00:00Z'
    )

    result = Legion::Apollo::Local.query(text: '', tags: %w[temporal], as_of: '2026-05-01T00:00:00Z')

    expect(result[:success]).to be true
    expect(result[:results].map { |entry| entry[:content] }).to include('Current temporal fact')
    expect(result[:results].map { |entry| entry[:content] }).not_to include('Future temporal fact')
  end

  it 'returns not_started when not started' do
    Legion::Apollo::Local.shutdown
    result = Legion::Apollo::Local.query(text: 'test')
    expect(result).to eq({ success: false, error: :not_started })
  end

  it 'retrieve is an alias for query' do
    result = Legion::Apollo::Local.retrieve(text: 'RabbitMQ')
    expect(result[:success]).to be true
    expect(result[:mode]).to eq(:local)
  end
end
