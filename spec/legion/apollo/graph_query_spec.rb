# frozen_string_literal: true

require 'spec_helper'
require 'sequel'
require 'sequel/extensions/migration'

RSpec.describe 'Legion::Apollo.graph_query' do
  let(:db) { Sequel.sqlite }

  before do
    Legion::Apollo.shutdown if Legion::Apollo.started?
    Legion::Apollo::Local.shutdown if Legion::Apollo::Local.started?

    local_db = db
    migration_path = File.expand_path('../../../lib/legion/apollo/local/migrations', __dir__)
    Sequel::Migrator.run(local_db, migration_path, table: :schema_migrations_apollo_local)

    stub_const('Legion::Data::Local', Module.new do
      extend self

      define_method(:connected?) { true }
      define_method(:connection) { local_db }
      define_method(:register_migrations) { |**_| nil }
    end)

    Legion::Apollo.start
  end

  after do
    Legion::Apollo::Local.shutdown
    Legion::Apollo.shutdown
  end

  def make_entity(name:, type: 'service')
    Legion::Apollo::Local::Graph.create_entity(type: type, name: name)[:id]
  end

  def make_rel(src, tgt, type: 'DEPENDS_ON')
    Legion::Apollo::Local::Graph.create_relationship(source_id: src, target_id: tgt, relation_type: type)
  end

  it 'returns not_started when Apollo not started' do
    Legion::Apollo.shutdown
    result = Legion::Apollo.graph_query(entity_id: 1)
    expect(result[:success]).to be false
    expect(result[:error]).to eq(:not_started)
  end

  it 'delegates to Local::Graph.traverse' do
    src = make_entity(name: 'web')
    tgt = make_entity(name: 'db')
    make_rel(src, tgt)

    result = Legion::Apollo.graph_query(entity_id: src, depth: 2)
    expect(result[:success]).to be true
    node_ids = result[:nodes].map { |n| n[:id] }
    expect(node_ids).to include(src, tgt)
  end

  it 'passes relation_type filter through' do
    src  = make_entity(name: 'svc')
    tgt1 = make_entity(name: 'dep')
    tgt2 = make_entity(name: 'owner', type: 'team')
    make_rel(src, tgt1, type: 'DEPENDS_ON')
    make_rel(src, tgt2, type: 'OWNED_BY')

    result = Legion::Apollo.graph_query(entity_id: src, relation_type: 'DEPENDS_ON', depth: 1)
    node_ids = result[:nodes].map { |n| n[:id] }
    expect(node_ids).to include(tgt1)
    expect(node_ids).not_to include(tgt2)
  end

  it 'passes direction through' do
    parent = make_entity(name: 'parent')
    child  = make_entity(name: 'child')
    make_rel(parent, child, type: 'AFFECTS')

    inbound = Legion::Apollo.graph_query(entity_id: child, relation_type: 'AFFECTS',
                                         depth: 1, direction: :inbound)
    node_ids = inbound[:nodes].map { |n| n[:id] }
    expect(node_ids).to include(parent)
  end

  it 'returns local_not_started when Local is not running' do
    Legion::Apollo::Local.shutdown
    result = Legion::Apollo.graph_query(entity_id: 1)
    expect(result[:success]).to be false
    expect(result[:error]).to eq(:local_not_started)
  end
end
