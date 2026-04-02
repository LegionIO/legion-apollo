# frozen_string_literal: true

Sequel.migration do
  up do
    run <<~SQL
      DELETE FROM local_relationships
      WHERE id NOT IN (
        SELECT MIN(id)
        FROM local_relationships
        GROUP BY source_entity_id, target_entity_id, relation_type
      )
    SQL

    run <<~SQL
      CREATE UNIQUE INDEX IF NOT EXISTS idx_local_rel_unique
      ON local_relationships (source_entity_id, target_entity_id, relation_type)
    SQL
  end

  down do
    run 'DROP INDEX IF EXISTS idx_local_rel_unique'
  end
end
