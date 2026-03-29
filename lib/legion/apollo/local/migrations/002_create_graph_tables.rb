# frozen_string_literal: true

Sequel.migration do # rubocop:disable Metrics/BlockLength
  up do # rubocop:disable Metrics/BlockLength
    create_table(:local_entities) do
      primary_key :id
      String  :entity_type, null: false, size: 128
      String  :name,        null: false, size: 512
      String  :domain,      size: 256
      String  :attributes,  text: true # JSON bag
      String  :created_at,  null: false
      String  :updated_at,  null: false

      index :entity_type, name: :idx_local_entities_type
      index :name,         name: :idx_local_entities_name
      index %i[entity_type name], name: :idx_local_entities_type_name
    end

    create_table(:local_relationships) do
      primary_key :id
      Integer :source_entity_id, null: false
      Integer :target_entity_id, null: false
      String  :relation_type, null: false, size: 128
      String  :attributes,    text: true # JSON bag
      String  :created_at,    null: false
      String  :updated_at,    null: false

      foreign_key [:source_entity_id], :local_entities, name: :fk_rel_source
      foreign_key [:target_entity_id], :local_entities, name: :fk_rel_target
      index :relation_type,                               name: :idx_local_rel_type
      index %i[source_entity_id relation_type],           name: :idx_local_rel_src_type
      index %i[target_entity_id relation_type],           name: :idx_local_rel_tgt_type
    end
  end

  down do
    drop_table(:local_relationships) if table_exists?(:local_relationships)
    drop_table(:local_entities)      if table_exists?(:local_entities)
  end
end
