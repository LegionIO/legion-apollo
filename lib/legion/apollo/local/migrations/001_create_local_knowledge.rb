# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:local_knowledge) do
      primary_key :id
      String   :content,        null: false, text: true
      String   :content_hash,   null: false, size: 32
      String   :tags,           text: true
      String   :embedding,      text: true
      String   :embedded_at
      String   :source_channel
      String   :source_agent
      String   :submitted_by
      Float    :confidence,     default: 1.0
      String   :expires_at,     null: false
      String   :created_at,     null: false
      String   :updated_at,     null: false

      unique :content_hash, name: :idx_local_knowledge_hash
      index :expires_at, name: :idx_local_knowledge_expires
      index :embedded_at, name: :idx_local_knowledge_embedded
    end

    run "CREATE VIRTUAL TABLE IF NOT EXISTS local_knowledge_fts USING fts5(content, tags, content='local_knowledge', content_rowid='id')"
  end

  down do
    run 'DROP TABLE IF EXISTS local_knowledge_fts'
    drop_table(:local_knowledge) if table_exists?(:local_knowledge)
  end
end
