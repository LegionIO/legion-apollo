# frozen_string_literal: true

require 'spec_helper'
require 'sequel'
require 'sequel/extensions/migration'

RSpec.describe 'local knowledge migration' do
  let(:db) { Sequel.sqlite }

  before do
    migration_path = File.expand_path('../../../../lib/legion/apollo/local/migrations', __dir__)
    Sequel::Migrator.run(db, migration_path, table: :schema_migrations_apollo_local)
  end

  it 'creates local_knowledge table' do
    expect(db.table_exists?(:local_knowledge)).to be true
  end

  it 'has expected columns' do
    cols = db[:local_knowledge].columns
    %i[id content content_hash tags embedding embedded_at source_channel
       source_agent submitted_by confidence expires_at created_at updated_at].each do |col|
      expect(cols).to include(col)
    end
  end

  it 'creates FTS5 virtual table' do
    result = db.fetch("SELECT name FROM sqlite_master WHERE type='table' AND name='local_knowledge_fts'").all
    expect(result).not_to be_empty
  end

  it 'enforces unique content_hash' do
    now = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%S.%LZ')
    row = { content: 'test', content_hash: 'abc123', tags: '[]', confidence: 1.0,
            expires_at: now, created_at: now, updated_at: now }
    db[:local_knowledge].insert(row)
    expect { db[:local_knowledge].insert(row) }.to raise_error(Sequel::UniqueConstraintViolation)
  end
end
