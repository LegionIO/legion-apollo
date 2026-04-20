# frozen_string_literal: true

require 'spec_helper'
require 'sequel'
require 'sequel/extensions/migration'

RSpec.describe 'Apollo::Local FTS5 escaping' do
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

    Legion::Apollo::Local.ingest(content: 'Deploy version 1.2.3 to production', tags: %w[deploy])
    Legion::Apollo::Local.ingest(content: 'Check http://example.com for docs', tags: %w[docs])
    Legion::Apollo::Local.ingest(content: 'Use key:value pairs in config', tags: %w[config])
    Legion::Apollo::Local.ingest(content: 'Run test-suite with bundle exec rspec', tags: %w[testing])
    Legion::Apollo::Local.ingest(content: 'Add +1 reaction to approve PRs', tags: %w[workflow])
    Legion::Apollo::Local.ingest(content: 'Use NOT NULL constraints in migrations', tags: %w[database])
    Legion::Apollo::Local.ingest(content: 'Parentheses (like this) group expressions', tags: %w[syntax])
  end

  after { Legion::Apollo::Local.shutdown }

  it 'handles dots in query text and finds relevant content' do
    result = Legion::Apollo::Local.query(text: 'version 1.2.3')
    expect(result[:success]).to be true
    expect(result[:results]).not_to be_empty
    expect(result[:results].first[:content]).to include('version')
  end

  it 'handles colons in query text and finds relevant content' do
    result = Legion::Apollo::Local.query(text: 'key:value pairs')
    expect(result[:success]).to be true
    expect(result[:results]).not_to be_empty
    expect(result[:results].first[:content]).to include('key:value')
  end

  it 'handles hyphens in query text and finds relevant content' do
    result = Legion::Apollo::Local.query(text: 'test-suite bundle')
    expect(result[:success]).to be true
    expect(result[:results]).not_to be_empty
    expect(result[:results].first[:content]).to include('test-suite')
  end

  it 'handles plus signs in query text' do
    result = Legion::Apollo::Local.query(text: '+1 reaction')
    expect(result[:success]).to be true
    expect(result[:results]).not_to be_empty
  end

  it 'handles URLs in query text and finds relevant content' do
    result = Legion::Apollo::Local.query(text: 'http://example.com docs')
    expect(result[:success]).to be true
    expect(result[:results]).not_to be_empty
    expect(result[:results].first[:content]).to include('example')
  end

  it 'handles FTS5 keywords AND/OR/NOT in query text' do
    result = Legion::Apollo::Local.query(text: 'NOT NULL constraints')
    expect(result[:success]).to be true
    expect(result[:results]).not_to be_empty
  end

  it 'handles parentheses in query text' do
    result = Legion::Apollo::Local.query(text: 'expressions (like this)')
    expect(result[:success]).to be true
    expect(result[:results]).not_to be_empty
  end

  it 'uses FTS path without falling back to ILIKE for punctuated input' do
    expect(Legion::Apollo::Local).not_to receive(:handle_exception).with(
      anything, hash_including(fallback: :ilike)
    )
    result = Legion::Apollo::Local.query(text: 'version 1.2.3')
    expect(result[:success]).to be true
    expect(result[:results]).not_to be_empty
  end

  it 'falls back gracefully when query is only punctuation' do
    result = Legion::Apollo::Local.query(text: '...:---')
    expect(result[:success]).to be true
  end
end
