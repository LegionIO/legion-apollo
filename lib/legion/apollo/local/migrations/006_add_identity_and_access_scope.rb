# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:local_knowledge) do
      add_column :access_scope,            String, null: false, default: 'global'
      add_column :identity_canonical_name, String, null: true
      add_column :identity_principal_id,   Integer, null: true
      add_column :identity_id,             Integer, null: true

      add_index :access_scope,            name: :idx_local_knowledge_access_scope
      add_index :identity_principal_id,   name: :idx_local_knowledge_identity_principal_id
      add_index :identity_id,             name: :idx_local_knowledge_identity_id
    end
  end

  down do
    alter_table(:local_knowledge) do
      drop_column :access_scope
      drop_column :identity_canonical_name
      drop_column :identity_principal_id
      drop_column :identity_id
    end
  end
end
