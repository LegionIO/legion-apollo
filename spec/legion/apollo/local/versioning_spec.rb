# frozen_string_literal: true

require 'spec_helper'
require 'sequel'
require 'sequel/extensions/migration'

RSpec.describe 'Apollo::Local versioning' do
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

  it 'creates versioned entry with parent_knowledge_id' do
    result1 = Legion::Apollo::Local.ingest(content: 'Original policy', tags: %w[policy])
    parent_id = result1[:id]

    result2 = Legion::Apollo::Local.ingest(
      content: 'Updated policy v2',
      tags: %w[policy],
      parent_knowledge_id: parent_id,
      supersession_type: 'updates'
    )

    parent = db[:local_knowledge].where(id: parent_id).first
    child = db[:local_knowledge].where(id: result2[:id]).first

    expect(parent[:is_latest]).to be_falsey
    expect(child[:is_latest]).to be_truthy
    expect(child[:parent_knowledge_id]).to eq(parent_id)
    expect(child[:supersession_type]).to eq('updates')
  end

  it 'default query only returns is_latest entries' do
    result1 = Legion::Apollo::Local.ingest(content: 'Deploy policy v1', tags: %w[deploy])
    Legion::Apollo::Local.ingest(
      content: 'Deploy policy v2',
      tags: %w[deploy],
      parent_knowledge_id: result1[:id],
      supersession_type: 'updates'
    )

    results = Legion::Apollo::Local.query(text: 'Deploy policy', tags: %w[deploy])
    contents = results[:results].map { |r| r[:content] }
    expect(contents).to include('Deploy policy v2')
    expect(contents).not_to include('Deploy policy v1')
  end

  it 'query with include_history returns all versions' do
    result1 = Legion::Apollo::Local.ingest(content: 'Auth policy v1', tags: %w[auth])
    Legion::Apollo::Local.ingest(
      content: 'Auth policy v2',
      tags: %w[auth],
      parent_knowledge_id: result1[:id],
      supersession_type: 'updates'
    )

    results = Legion::Apollo::Local.query(text: 'Auth policy', tags: %w[auth], include_history: true)
    contents = results[:results].map { |r| r[:content] }
    expect(contents).to include('Auth policy v1', 'Auth policy v2')
  end

  it 'version_chain returns ordered history' do
    r1 = Legion::Apollo::Local.ingest(content: 'Config v1', tags: %w[config])
    r2 = Legion::Apollo::Local.ingest(content: 'Config v2', tags: %w[config],
                                      parent_knowledge_id: r1[:id], supersession_type: 'updates')
    r3 = Legion::Apollo::Local.ingest(content: 'Config v3', tags: %w[config],
                                      parent_knowledge_id: r2[:id], supersession_type: 'updates')

    chain = Legion::Apollo::Local.version_chain(entry_id: r3[:id])
    expect(chain[:success]).to be true
    expect(chain[:chain].map { |e| e[:content] }).to eq(['Config v3', 'Config v2', 'Config v1'])
  end
end
