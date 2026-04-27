# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:local_knowledge) do
      add_column :raw_content, :text, null: true
      add_column :valid_from, String, null: true
      add_column :valid_to, String, null: true

      add_index :valid_from, name: :idx_local_knowledge_valid_from
      add_index :valid_to, name: :idx_local_knowledge_valid_to
    end
  end

  down do
    alter_table(:local_knowledge) do
      drop_column :raw_content
      drop_column :valid_from
      drop_column :valid_to
    end
  end
end
