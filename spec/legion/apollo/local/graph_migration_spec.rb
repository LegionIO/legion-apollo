# frozen_string_literal: true

require 'spec_helper'
require 'sequel'
require 'sequel/extensions/migration'

RSpec.describe 'graph tables migration' do
  let(:db) { Sequel.sqlite }

  before do
    migration_path = File.expand_path('../../../../lib/legion/apollo/local/migrations', __dir__)
    Sequel::Migrator.run(db, migration_path, table: :schema_migrations_apollo_local)
  end

  describe 'local_entities table' do
    it 'is created' do
      expect(db.table_exists?(:local_entities)).to be true
    end

    it 'has expected columns' do
      cols = db[:local_entities].columns
      %i[id entity_type name domain attributes created_at updated_at].each do |col|
        expect(cols).to include(col), "expected column :#{col}"
      end
    end

    it 'allows inserting an entity' do
      now = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%S.%LZ')
      id = db[:local_entities].insert(entity_type: 'service', name: 'my-svc',
                                      attributes: '{}', created_at: now, updated_at: now)
      expect(id).to be_a(Integer)
    end
  end

  describe 'local_relationships table' do
    let(:entity_id) do
      now = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%S.%LZ')
      db[:local_entities].insert(entity_type: 'svc', name: 'a', attributes: '{}',
                                 created_at: now, updated_at: now)
    end

    it 'is created' do
      expect(db.table_exists?(:local_relationships)).to be true
    end

    it 'has expected columns' do
      cols = db[:local_relationships].columns
      %i[id source_entity_id target_entity_id relation_type attributes created_at updated_at].each do |col|
        expect(cols).to include(col), "expected column :#{col}"
      end
    end

    it 'allows inserting a relationship between two entities' do
      now = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%S.%LZ')
      src = db[:local_entities].insert(entity_type: 'svc', name: 'src', attributes: '{}',
                                       created_at: now, updated_at: now)
      tgt = db[:local_entities].insert(entity_type: 'svc', name: 'tgt', attributes: '{}',
                                       created_at: now, updated_at: now)
      rel_id = db[:local_relationships].insert(
        source_entity_id: src, target_entity_id: tgt,
        relation_type: 'DEPENDS_ON', attributes: '{}',
        created_at: now, updated_at: now
      )
      expect(rel_id).to be_a(Integer)
    end

    it 'prevents duplicate semantic relationships' do
      now = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%S.%LZ')
      src = db[:local_entities].insert(entity_type: 'svc', name: 'src', attributes: '{}',
                                       created_at: now, updated_at: now)
      tgt = db[:local_entities].insert(entity_type: 'svc', name: 'tgt', attributes: '{}',
                                       created_at: now, updated_at: now)

      db[:local_relationships].insert(
        source_entity_id: src, target_entity_id: tgt,
        relation_type: 'DEPENDS_ON', attributes: '{}',
        created_at: now, updated_at: now
      )

      expect do
        db[:local_relationships].insert(
          source_entity_id: src, target_entity_id: tgt,
          relation_type: 'DEPENDS_ON', attributes: '{}',
          created_at: now, updated_at: now
        )
      end.to raise_error(Sequel::UniqueConstraintViolation)
    end
  end
end
