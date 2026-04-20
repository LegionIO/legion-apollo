# frozen_string_literal: true

require 'spec_helper'
require 'sequel'
require 'sequel/extensions/migration'

RSpec.describe 'Apollo::Local source linkage' do
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

  it 'stores source link on ingest when source metadata provided' do
    result = Legion::Apollo::Local.ingest(
      content: 'Extracted fact from wiki',
      tags: %w[wiki],
      source_uri: 'https://wiki.example.com/page',
      source_hash: 'abc123',
      relevance_score: 0.95,
      extraction_method: 'ner'
    )
    links = db[:local_source_links].where(entry_id: result[:id]).all
    expect(links.size).to eq(1)
    expect(links.first[:source_uri]).to eq('https://wiki.example.com/page')
    expect(links.first[:relevance_score]).to eq(0.95)
    expect(links.first[:extraction_method]).to eq('ner')
  end

  it 'does not create source link when no source_uri' do
    result = Legion::Apollo::Local.ingest(content: 'No source fact', tags: %w[general])
    links = db[:local_source_links].where(entry_id: result[:id]).all
    expect(links).to be_empty
  end

  it 'source_links_for returns links for an entry' do
    result = Legion::Apollo::Local.ingest(
      content: 'Linked fact',
      tags: %w[linked],
      source_uri: 'https://docs.example.com/api',
      relevance_score: 0.8
    )
    links = Legion::Apollo::Local.source_links_for(entry_id: result[:id])
    expect(links[:success]).to be true
    expect(links[:links].size).to eq(1)
    expect(links[:links].first[:source_uri]).to eq('https://docs.example.com/api')
  end

  it 'source_links_for returns empty for entry with no links' do
    result = Legion::Apollo::Local.ingest(content: 'Unlinked fact', tags: %w[general])
    links = Legion::Apollo::Local.source_links_for(entry_id: result[:id])
    expect(links[:success]).to be true
    expect(links[:links]).to be_empty
  end

  it 'defaults relevance_score to 1.0 when not specified' do
    result = Legion::Apollo::Local.ingest(
      content: 'Default score fact',
      tags: %w[test],
      source_uri: 'https://example.com/doc'
    )
    link = db[:local_source_links].where(entry_id: result[:id]).first
    expect(link[:relevance_score]).to eq(1.0)
  end
end
