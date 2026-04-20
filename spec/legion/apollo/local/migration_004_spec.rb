# frozen_string_literal: true

require 'spec_helper'
require 'sequel'
require 'sequel/extensions/migration'

RSpec.describe 'Migration 004: versioning, tiers, inference' do
  let(:db) { Sequel.sqlite }

  before do
    migration_path = File.expand_path('../../../../lib/legion/apollo/local/migrations', __dir__)
    Sequel::Migrator.run(db, migration_path, table: :schema_migrations_apollo_local)
  end

  it 'adds versioning columns to local_knowledge' do
    cols = db.schema(:local_knowledge).map(&:first)
    expect(cols).to include(:parent_knowledge_id, :is_latest, :supersession_type)
  end

  it 'adds inference column to local_knowledge' do
    cols = db.schema(:local_knowledge).map(&:first)
    expect(cols).to include(:is_inference)
  end

  it 'adds expiry metadata column to local_knowledge' do
    cols = db.schema(:local_knowledge).map(&:first)
    expect(cols).to include(:forget_reason)
  end

  it 'adds tier columns to local_knowledge' do
    cols = db.schema(:local_knowledge).map(&:first)
    expect(cols).to include(:summary_l0, :summary_l1, :knowledge_tier, :l0_generated_at, :l1_generated_at)
  end

  it 'creates local_source_links table' do
    expect(db.table_exists?(:local_source_links)).to be true
    cols = db.schema(:local_source_links).map(&:first)
    expect(cols).to include(:entry_id, :source_uri, :source_hash, :relevance_score, :extraction_method)
  end

  it 'defaults is_latest to true' do
    now = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%S.%LZ')
    db[:local_knowledge].insert(
      content: 'test', content_hash: 'abc123', tags: '[]',
      confidence: 1.0, expires_at: now, created_at: now, updated_at: now
    )
    row = db[:local_knowledge].first
    expect(row[:is_latest]).to be_truthy
  end

  it 'defaults is_inference to false' do
    now = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%S.%LZ')
    db[:local_knowledge].insert(
      content: 'test2', content_hash: 'def456', tags: '[]',
      confidence: 1.0, expires_at: now, created_at: now, updated_at: now
    )
    row = db[:local_knowledge].first
    expect(row[:is_inference]).to be_falsey
  end

  it 'defaults knowledge_tier to L2' do
    now = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%S.%LZ')
    db[:local_knowledge].insert(
      content: 'test3', content_hash: 'ghi789', tags: '[]',
      confidence: 1.0, expires_at: now, created_at: now, updated_at: now
    )
    row = db[:local_knowledge].first
    expect(row[:knowledge_tier]).to eq('L2')
  end
end
