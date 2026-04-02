# frozen_string_literal: true

require 'spec_helper'
require 'sequel'
require 'sequel/extensions/migration'

RSpec.describe Legion::Apollo::Local::Graph do
  let(:db) { Sequel.sqlite }

  before do
    local_db = db
    migration_path = File.expand_path('../../../../lib/legion/apollo/local/migrations', __dir__)
    Sequel::Migrator.run(local_db, migration_path, table: :schema_migrations_apollo_local)

    stub_const('Legion::Data::Local', Module.new do
      extend self

      define_method(:connected?) { true }
      define_method(:connection) { local_db }
      define_method(:register_migrations) { |**_| nil }
    end)
  end

  # --- helpers ---
  def make_entity(type: 'service', name: 'svc', domain: nil, attributes: {})
    described_class.create_entity(type: type, name: name, domain: domain, attributes: attributes)
  end

  def make_rel(src, tgt, type: 'DEPENDS_ON')
    described_class.create_relationship(source_id: src, target_id: tgt, relation_type: type)
  end

  # ============================================================
  # Entity CRUD
  # ============================================================
  describe '.create_entity' do
    it 'returns success with an integer id' do
      result = make_entity
      expect(result[:success]).to be true
      expect(result[:id]).to be_a(Integer)
    end

    it 'persists entity_type, name, and domain' do
      id = make_entity(type: 'team', name: 'platform', domain: 'engineering')[:id]
      row = db[:local_entities].where(id: id).first
      expect(row[:entity_type]).to eq('team')
      expect(row[:name]).to eq('platform')
      expect(row[:domain]).to eq('engineering')
    end

    it 'stores JSON-encoded attributes' do
      id = make_entity(attributes: { owner: 'alice' })[:id]
      row = db[:local_entities].where(id: id).first
      expect(row[:attributes]).to include('alice')
    end

    it 'sets created_at and updated_at' do
      id = make_entity[:id]
      row = db[:local_entities].where(id: id).first
      expect(row[:created_at]).not_to be_nil
      expect(row[:updated_at]).not_to be_nil
    end
  end

  describe '.find_entity' do
    it 'returns the entity by id' do
      id = make_entity(type: 'api', name: 'my-api')[:id]
      result = described_class.find_entity(id: id)
      expect(result[:success]).to be true
      expect(result[:entity][:name]).to eq('my-api')
      expect(result[:entity][:entity_type]).to eq('api')
    end

    it 'returns not_found for unknown id' do
      result = described_class.find_entity(id: 99_999)
      expect(result[:success]).to be false
      expect(result[:error]).to eq(:not_found)
    end

    it 'decodes attributes hash' do
      id = make_entity(attributes: { env: 'prod' })[:id]
      entity = described_class.find_entity(id: id)[:entity]
      expect(entity[:attributes][:env]).to eq('prod')
    end
  end

  describe '.find_entities_by_type' do
    before do
      make_entity(type: 'service', name: 'svc-a')
      make_entity(type: 'service', name: 'svc-b')
      make_entity(type: 'team',    name: 'team-x')
    end

    it 'returns only entities of the requested type' do
      result = described_class.find_entities_by_type(type: 'service')
      expect(result[:success]).to be true
      expect(result[:count]).to eq(2)
      expect(result[:entities].map { |e| e[:entity_type] }.uniq).to eq(['service'])
    end

    it 'returns empty list for unknown type' do
      result = described_class.find_entities_by_type(type: 'unknown')
      expect(result[:count]).to eq(0)
      expect(result[:entities]).to be_empty
    end

    it 'respects limit' do
      result = described_class.find_entities_by_type(type: 'service', limit: 1)
      expect(result[:count]).to eq(1)
    end
  end

  describe '.find_entities_by_name' do
    before do
      make_entity(type: 'service', name: 'consul')
      make_entity(type: 'api',     name: 'consul')
      make_entity(type: 'service', name: 'vault')
    end

    it 'returns all entities with the given name' do
      result = described_class.find_entities_by_name(name: 'consul')
      expect(result[:success]).to be true
      expect(result[:count]).to eq(2)
    end
  end

  describe '.update_entity' do
    it 'updates name and entity_type' do
      id = make_entity(type: 'service', name: 'old-name')[:id]
      described_class.update_entity(id: id, name: 'new-name', entity_type: 'api')
      entity = described_class.find_entity(id: id)[:entity]
      expect(entity[:name]).to eq('new-name')
      expect(entity[:entity_type]).to eq('api')
    end

    it 'updates attributes' do
      id = make_entity(attributes: { env: 'dev' })[:id]
      described_class.update_entity(id: id, attributes: { env: 'prod', region: 'us-east-2' })
      entity = described_class.find_entity(id: id)[:entity]
      expect(entity[:attributes][:env]).to eq('prod')
      expect(entity[:attributes][:region]).to eq('us-east-2')
    end

    it 'returns not_found for unknown id' do
      result = described_class.update_entity(id: 99_999, name: 'x')
      expect(result[:success]).to be false
      expect(result[:error]).to eq(:not_found)
    end
  end

  describe '.delete_entity' do
    it 'removes the entity' do
      id = make_entity[:id]
      described_class.delete_entity(id: id)
      expect(described_class.find_entity(id: id)[:error]).to eq(:not_found)
    end

    it 'cascades and removes related relationships' do
      src = make_entity(name: 'src')[:id]
      tgt = make_entity(name: 'tgt')[:id]
      make_rel(src, tgt)
      described_class.delete_entity(id: src)
      rels = db[:local_relationships].where(source_entity_id: src).all
      expect(rels).to be_empty
    end

    it 'returns not_found for unknown id' do
      result = described_class.delete_entity(id: 99_999)
      expect(result[:success]).to be false
      expect(result[:error]).to eq(:not_found)
    end

    it 'rolls back relationship deletes when entity deletion fails' do
      src = make_entity(name: 'src')[:id]
      tgt = make_entity(name: 'tgt')[:id]
      make_rel(src, tgt)

      allow(described_class).to receive(:delete_entity_row).and_raise(Sequel::Error, 'delete failed')

      result = described_class.delete_entity(id: src)

      expect(result[:success]).to be false
      expect(result[:error]).to eq('delete failed')
      expect(db[:local_entities].where(id: src).count).to eq(1)
      expect(db[:local_relationships].where(source_entity_id: src).count).to eq(1)
    end
  end

  # ============================================================
  # Relationship CRUD
  # ============================================================
  describe '.create_relationship' do
    let(:src) { make_entity(name: 'src')[:id] }
    let(:tgt) { make_entity(name: 'tgt')[:id] }

    it 'returns success with an integer id' do
      result = make_rel(src, tgt)
      expect(result[:success]).to be true
      expect(result[:id]).to be_a(Integer)
    end

    it 'upcases relation_type' do
      id = make_rel(src, tgt, type: 'affects')[:id]
      row = db[:local_relationships].where(id: id).first
      expect(row[:relation_type]).to eq('AFFECTS')
    end

    it 'persists source_id and target_id' do
      id = make_rel(src, tgt)[:id]
      row = db[:local_relationships].where(id: id).first
      expect(row[:source_entity_id]).to eq(src)
      expect(row[:target_entity_id]).to eq(tgt)
    end

    it 'rejects invalid relation types' do
      result = make_rel(src, tgt, type: 'BROKEN_EDGE')

      expect(result[:success]).to be false
      expect(result[:error]).to eq(:invalid_relation_type)
      expect(db[:local_relationships].count).to eq(0)
    end

    it 'deduplicates duplicate semantic edges' do
      first = make_rel(src, tgt, type: 'DEPENDS_ON')
      second = make_rel(src, tgt, type: 'depends_on')

      expect(first[:success]).to be true
      expect(second[:success]).to be true
      expect(second[:mode]).to eq(:deduplicated)
      expect(second[:id]).to eq(first[:id])
      expect(db[:local_relationships].count).to eq(1)
    end
  end

  describe '.find_relationships' do
    let(:svc)  { make_entity(type: 'service', name: 'svc')[:id] }
    let(:db_e) { make_entity(type: 'db',      name: 'pg')[:id] }
    let(:team) { make_entity(type: 'team',    name: 'eng')[:id] }

    before do
      make_rel(svc, db_e, type: 'DEPENDS_ON')
      make_rel(team, svc, type: 'OWNED_BY')
    end

    it 'returns outbound relationships by default' do
      result = described_class.find_relationships(entity_id: svc)
      expect(result[:success]).to be true
      expect(result[:count]).to eq(1)
      expect(result[:relationships].first[:relation_type]).to eq('DEPENDS_ON')
    end

    it 'returns inbound relationships' do
      result = described_class.find_relationships(entity_id: svc, direction: :inbound)
      expect(result[:count]).to eq(1)
      expect(result[:relationships].first[:relation_type]).to eq('OWNED_BY')
    end

    it 'returns both directions' do
      result = described_class.find_relationships(entity_id: svc, direction: :both)
      expect(result[:count]).to eq(2)
    end

    it 'filters by relation_type' do
      result = described_class.find_relationships(entity_id: svc, relation_type: 'DEPENDS_ON')
      expect(result[:count]).to eq(1)
    end

    it 'returns empty when no matching type' do
      result = described_class.find_relationships(entity_id: svc, relation_type: 'AFFECTS')
      expect(result[:count]).to eq(0)
    end
  end

  describe '.delete_relationship' do
    it 'removes the relationship' do
      src = make_entity(name: 'a')[:id]
      tgt = make_entity(name: 'b')[:id]
      rel_id = make_rel(src, tgt)[:id]
      described_class.delete_relationship(id: rel_id)
      expect(db[:local_relationships].where(id: rel_id).first).to be_nil
    end

    it 'returns not_found for unknown id' do
      result = described_class.delete_relationship(id: 99_999)
      expect(result[:success]).to be false
      expect(result[:error]).to eq(:not_found)
    end
  end

  # ============================================================
  # Graph Traversal
  # ============================================================
  describe '.traverse' do
    # Build: A -> B -> C -> D  (DEPENDS_ON chain)
    let!(:id_a) { make_entity(name: 'A')[:id] }
    let!(:id_b) { make_entity(name: 'B')[:id] }
    let!(:id_c) { make_entity(name: 'C')[:id] }
    let!(:id_d) { make_entity(name: 'D')[:id] }

    before do
      make_rel(id_a, id_b, type: 'DEPENDS_ON')
      make_rel(id_b, id_c, type: 'DEPENDS_ON')
      make_rel(id_c, id_d, type: 'DEPENDS_ON')
    end

    it 'returns success' do
      result = described_class.traverse(entity_id: id_a)
      expect(result[:success]).to be true
    end

    it 'returns nodes and edges' do
      result = described_class.traverse(entity_id: id_a, depth: 3)
      expect(result[:nodes]).to be_an(Array)
      expect(result[:edges]).to be_an(Array)
    end

    it 'traverses the full chain within depth' do
      result = described_class.traverse(entity_id: id_a, depth: 3)
      node_ids = result[:nodes].map { |n| n[:id] }
      expect(node_ids).to include(id_a, id_b, id_c, id_d)
    end

    it 'respects depth limit — depth 1 stops at direct neighbors' do
      result = described_class.traverse(entity_id: id_a, depth: 1)
      node_ids = result[:nodes].map { |n| n[:id] }
      expect(node_ids).to include(id_a, id_b)
      expect(node_ids).not_to include(id_c, id_d)
    end

    it 'respects depth limit — depth 2 reaches two hops' do
      result = described_class.traverse(entity_id: id_a, depth: 2)
      node_ids = result[:nodes].map { |n| n[:id] }
      expect(node_ids).to include(id_a, id_b, id_c)
      expect(node_ids).not_to include(id_d)
    end

    it 'clamps depth to maximum of 10' do
      result = described_class.traverse(entity_id: id_a, depth: 999)
      expect(result[:success]).to be true
    end

    it 'filters by relation_type' do
      # Add an AFFECTS edge that should be excluded
      make_rel(id_a, id_d, type: 'AFFECTS')
      result = described_class.traverse(entity_id: id_a, relation_type: 'DEPENDS_ON', depth: 1)
      node_ids = result[:nodes].map { |n| n[:id] }
      expect(node_ids).to include(id_b)
      expect(node_ids).not_to include(id_d)
    end

    it 'traverses inbound direction' do
      result = described_class.traverse(entity_id: id_d, relation_type: 'DEPENDS_ON',
                                        depth: 3, direction: :inbound)
      node_ids = result[:nodes].map { |n| n[:id] }
      expect(node_ids).to include(id_c, id_b, id_a)
    end

    it 'includes entity for starting node' do
      result = described_class.traverse(entity_id: id_a, depth: 1)
      node_ids = result[:nodes].map { |n| n[:id] }
      expect(node_ids).to include(id_a)
    end

    it 'does not duplicate nodes in a diamond graph' do
      # B and C both point to D — traversal from A should still return D once
      id_e = make_entity(name: 'E')[:id]
      make_rel(id_a, id_e, type: 'RELATED_TO')
      make_rel(id_e, id_b, type: 'RELATED_TO') # second path to B

      result = described_class.traverse(entity_id: id_a, depth: 5)
      node_ids = result[:nodes].map { |n| n[:id] }
      expect(node_ids.uniq).to eq(node_ids)
    end

    it 'returns nodes with decoded entity fields' do
      result = described_class.traverse(entity_id: id_a, depth: 1)
      node = result[:nodes].find { |n| n[:id] == id_a }
      expect(node).to include(:name, :entity_type, :attributes)
    end

    it 'returns edges with decoded relationship fields' do
      result = described_class.traverse(entity_id: id_a, depth: 1)
      edge = result[:edges].first
      expect(edge).to include(:source_entity_id, :target_entity_id, :relation_type)
    end

    it 'batches frontier expansion for larger graphs' do
      previous_id = id_d
      12.times do |index|
        next_id = make_entity(name: "N#{index}")[:id]
        make_rel(previous_id, next_id, type: 'DEPENDS_ON')
        previous_id = next_id
      end

      allow(described_class).to receive(:fetch_frontier_edges).and_call_original

      result = described_class.traverse(entity_id: id_a, depth: 10)

      expect(result[:success]).to be true
      expect(result[:count]).to eq(11)
      expect(described_class).to have_received(:fetch_frontier_edges).exactly(10).times
    end

    context 'with no outbound edges' do
      it 'returns only the start node' do
        isolated = make_entity(name: 'isolated')[:id]
        result = described_class.traverse(entity_id: isolated, depth: 3)
        expect(result[:nodes].map { |n| n[:id] }).to eq([isolated])
        expect(result[:edges]).to be_empty
      end
    end
  end
end
