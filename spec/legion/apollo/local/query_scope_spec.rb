# frozen_string_literal: true

require 'spec_helper'
require 'sequel'
require 'sequel/extensions/migration'

RSpec.describe Legion::Apollo::Local, '.query access_scope filter' do
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

  def ingest(content, access_scope:, principal_id: nil)
    described_class.ingest(
      content: content, tags: [],
      access_scope: access_scope,
      identity_principal_id: principal_id
    )
  end

  it 'returns global entries to any principal' do
    ingest('global fact', access_scope: 'global')
    result = described_class.query(text: 'global fact', requesting_principal_id: 99)
    expect(result[:results].map { |r| r[:content] }).to include('global fact')
  end

  it 'returns private entries only to the owning principal' do
    ingest('alice private', access_scope: 'private', principal_id: 1)
    result_owner = described_class.query(text: 'alice private', requesting_principal_id: 1)
    result_other = described_class.query(text: 'alice private', requesting_principal_id: 2)
    expect(result_owner[:results].map { |r| r[:content] }).to include('alice private')
    expect(result_other[:results].map { |r| r[:content] }).not_to include('alice private')
  end

  it 'returns all entries when requesting_principal_id is nil (system/background tasks)' do
    ingest('private row', access_scope: 'private', principal_id: 1)
    result = described_class.query(text: 'private row')
    expect(result[:results].map { |r| r[:content] }).to include('private row')
  end
end
