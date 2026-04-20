# frozen_string_literal: true

require 'spec_helper'
require 'sequel'
require 'sequel/extensions/migration'

RSpec.describe 'Apollo::Local tiered retrieval' do
  let(:db) { Sequel.sqlite }

  # 300-char content built from real words so FTS5 can tokenize and match
  let(:alpha_content) { ('alpha ' * 50).strip }

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

    Legion::Apollo::Local.ingest(content: alpha_content, tags: %w[test])

    now = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%S.%LZ')
    local_db[:local_knowledge].where(content: alpha_content).update(
      summary_l0: 'Short summary',
      summary_l1: 'Medium paragraph summary of the content',
      knowledge_tier: 'L0',
      l0_generated_at: now,
      l1_generated_at: now
    )
  end

  after { Legion::Apollo::Local.shutdown }

  it 'returns full content at default tier (no tier param)' do
    result = Legion::Apollo::Local.query(text: 'alpha')
    expect(result[:results].first[:content]).to eq(alpha_content)
  end

  it 'returns l0 summary projection' do
    result = Legion::Apollo::Local.query(text: 'alpha', tier: :l0)
    entry = result[:results].first
    expect(entry[:summary]).to eq('Short summary')
    expect(entry).not_to have_key(:content)
    expect(result[:tier]).to eq(:l0)
  end

  it 'returns l1 summary projection' do
    result = Legion::Apollo::Local.query(text: 'alpha', tier: :l1)
    entry = result[:results].first
    expect(entry[:summary]).to eq('Medium paragraph summary of the content')
    expect(entry).not_to have_key(:content)
    expect(result[:tier]).to eq(:l1)
  end

  it 'falls back to truncated content when l0 summary missing' do
    beta_content = ('beta ' * 60).strip
    Legion::Apollo::Local.ingest(content: beta_content, tags: %w[test])
    result = Legion::Apollo::Local.query(text: 'beta', tier: :l0)
    entry = result[:results].first
    expect(entry[:summary].length).to be <= 200
  end

  it 'falls back to truncated content when l1 summary missing' do
    gamma_content = ('gamma ' * 250).strip
    Legion::Apollo::Local.ingest(content: gamma_content, tags: %w[test])
    result = Legion::Apollo::Local.query(text: 'gamma', tier: :l1)
    entry = result[:results].first
    expect(entry[:summary].length).to be <= 1000
  end

  it 'returns full content at tier :l2' do
    result = Legion::Apollo::Local.query(text: 'alpha', tier: :l2)
    expect(result[:results].first[:content]).to eq(alpha_content)
    expect(result[:tier]).to eq(:l2)
  end
end
