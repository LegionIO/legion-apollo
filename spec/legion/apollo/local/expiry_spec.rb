# frozen_string_literal: true

require 'spec_helper'
require 'sequel'
require 'sequel/extensions/migration'

RSpec.describe 'Apollo::Local temporal expiry metadata' do
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

  it 'stores forget_reason on ingest' do
    Legion::Apollo::Local.ingest(
      content:       'Deployment freeze until June',
      tags:          %w[policy],
      forget_reason: 'policy: deployment freeze window ends'
    )
    row = db[:local_knowledge].where(content: 'Deployment freeze until June').first
    expect(row[:forget_reason]).to eq('policy: deployment freeze window ends')
  end

  it 'stores custom expires_at on ingest' do
    future = (Time.now.utc + 86_400).strftime('%Y-%m-%dT%H:%M:%S.%LZ')
    Legion::Apollo::Local.ingest(
      content:       'Short-lived policy note',
      tags:          %w[policy],
      expires_at:    future,
      forget_reason: 'policy: 24h window'
    )
    row = db[:local_knowledge].where(content: 'Short-lived policy note').first
    expect(row[:expires_at]).to eq(future)
  end

  it 'defaults forget_reason to nil' do
    Legion::Apollo::Local.ingest(content: 'Regular fact', tags: %w[general])
    row = db[:local_knowledge].where(content: 'Regular fact').first
    expect(row[:forget_reason]).to be_nil
  end

  it 'uses default retention when no explicit expires_at' do
    Legion::Apollo::Local.ingest(content: 'Default expiry fact', tags: %w[general])
    row = db[:local_knowledge].where(content: 'Default expiry fact').first
    expect(row[:expires_at]).not_to be_nil
    parsed = Time.parse(row[:expires_at])
    expect(parsed).to be > (Time.now.utc + (4 * 365.25 * 24 * 3600))
  end
end
