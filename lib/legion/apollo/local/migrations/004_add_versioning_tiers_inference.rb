# frozen_string_literal: true

Sequel.migration do # rubocop:disable Metrics/BlockLength
  up do # rubocop:disable Metrics/BlockLength
    alter_table(:local_knowledge) do
      add_column :is_inference, :boolean, default: false, null: false
      add_column :parent_knowledge_id, Integer, null: true
      add_column :is_latest, :boolean, default: true, null: false
      add_column :supersession_type, String, size: 32, null: true
      add_column :forget_reason, String, size: 128, null: true
      add_column :summary_l0, String, size: 500, null: true
      add_column :summary_l1, :text, null: true
      add_column :knowledge_tier, String, size: 4, null: false, default: 'L2'
      add_column :l0_generated_at, String, null: true
      add_column :l1_generated_at, String, null: true

      add_index :is_latest, name: :idx_local_knowledge_is_latest
      add_index :is_inference, name: :idx_local_knowledge_is_inference
      add_index :knowledge_tier, name: :idx_local_knowledge_tier
      add_index :parent_knowledge_id, name: :idx_local_knowledge_parent
    end

    create_table(:local_source_links) do
      primary_key :id
      Integer :entry_id, null: false
      String  :source_uri, text: true
      String  :source_hash, size: 64
      Float   :relevance_score, default: 1.0
      String  :extraction_method, size: 64
      String  :created_at, null: false

      index :entry_id, name: :idx_source_links_entry
      index :source_hash, name: :idx_source_links_hash
    end
  end

  down do
    drop_table(:local_source_links) if table_exists?(:local_source_links)

    alter_table(:local_knowledge) do
      drop_column :is_inference
      drop_column :parent_knowledge_id
      drop_column :is_latest
      drop_column :supersession_type
      drop_column :forget_reason
      drop_column :summary_l0
      drop_column :summary_l1
      drop_column :knowledge_tier
      drop_column :l0_generated_at
      drop_column :l1_generated_at
    end
  end
end
