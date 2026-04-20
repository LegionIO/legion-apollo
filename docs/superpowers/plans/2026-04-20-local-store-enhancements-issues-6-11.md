# Local Store Enhancements: Issues #6-#11

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add versioning, inference tagging, temporal expiry metadata, tiered retrieval, source linkage, and enhanced graph capabilities to the local SQLite store — delivering the local-store portions of issues #6-#11 so the API surface is ready when global PG migrations (legion-data#11, #12) land.

**Architecture:** One new migration (004) adds all new columns to `local_knowledge` plus a `local_source_links` table. The `ingest` and `query` APIs gain new keyword parameters that pass through existing `**opts`/`**` splats. Each feature is self-contained: `is_inference` flag on write/filter on read, `forget_reason` on ingest/expiry, `parent_knowledge_id`/`is_latest` for versioning, `tier:` parameter for projected retrieval, and source links for provenance tracking. Graph gets `SUPERSEDES` relation type.

**Tech Stack:** Ruby, SQLite, Sequel, RSpec

---

## File Map

| File | Responsibility | Action |
|------|---------------|--------|
| `lib/legion/apollo/local/migrations/004_add_versioning_tiers_inference.rb` | Migration: add columns + source_links table | Create |
| `lib/legion/apollo/local.rb` | Local store: ingest, query, versioning, expiry | Modify |
| `lib/legion/apollo/local/graph.rb` | Graph: add SUPERSEDES relation type | Modify |
| `lib/legion/apollo/helpers/confidence.rb` | Add INITIAL_INFERENCE_CONFIDENCE constant | Modify |
| `lib/legion/apollo/settings.rb` | Add versioning/expiry/tier settings defaults | Modify |
| `lib/legion/apollo.rb` | Public API: pass through new params | Modify |
| `lib/legion/apollo/routes.rb` | Routes: pass through tier/inference params | Modify |
| `spec/legion/apollo/local/migration_004_spec.rb` | Migration spec | Create |
| `spec/legion/apollo/local/versioning_spec.rb` | Versioning specs | Create |
| `spec/legion/apollo/local/inference_spec.rb` | Inference tagging specs | Create |
| `spec/legion/apollo/local/expiry_spec.rb` | Temporal expiry specs | Create |
| `spec/legion/apollo/local/tiered_query_spec.rb` | Tiered retrieval specs | Create |
| `spec/legion/apollo/local/source_links_spec.rb` | Source linkage specs | Create |

---

### Task 1: Migration 004 — Add All New Columns and Tables

**Files:**
- Create: `lib/legion/apollo/local/migrations/004_add_versioning_tiers_inference.rb`
- Create: `spec/legion/apollo/local/migration_004_spec.rb`

- [ ] **Step 1: Create the migration file**

```ruby
# frozen_string_literal: true

Sequel.migration do # rubocop:disable Metrics/BlockLength
  up do # rubocop:disable Metrics/BlockLength
    alter_table(:local_knowledge) do
      # Issue #9: inference tagging
      add_column :is_inference, :boolean, default: false, null: false

      # Issue #7: versioning
      add_column :parent_knowledge_id, Integer, null: true
      add_column :is_latest, :boolean, default: true, null: false
      add_column :supersession_type, String, size: 32, null: true

      # Issue #8: temporal expiry metadata
      add_column :forget_reason, String, size: 128, null: true

      # Issue #6: tiered knowledge
      add_column :summary_l0, String, size: 500, null: true
      add_column :summary_l1, :text, null: true
      add_column :knowledge_tier, String, size: 4, null: false, default: 'L2'
      add_column :l0_generated_at, String, null: true
      add_column :l1_generated_at, String, null: true

      index :is_latest, name: :idx_local_knowledge_is_latest
      index :is_inference, name: :idx_local_knowledge_is_inference
      index :knowledge_tier, name: :idx_local_knowledge_tier
      index :parent_knowledge_id, name: :idx_local_knowledge_parent
    end

    # Issue #10: source-to-fact linkage
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
      drop_index :is_latest, name: :idx_local_knowledge_is_latest if @db.indexes(:local_knowledge)[:idx_local_knowledge_is_latest]
      drop_index :is_inference, name: :idx_local_knowledge_is_inference if @db.indexes(:local_knowledge)[:idx_local_knowledge_is_inference]
      drop_index :knowledge_tier, name: :idx_local_knowledge_tier if @db.indexes(:local_knowledge)[:idx_local_knowledge_tier]
      drop_index :parent_knowledge_id, name: :idx_local_knowledge_parent if @db.indexes(:local_knowledge)[:idx_local_knowledge_parent]

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
```

- [ ] **Step 2: Create migration spec**

```ruby
# frozen_string_literal: true

require 'spec_helper'
require 'sequel'
require 'sequel/extensions/migration'

RSpec.describe 'Migration 004: versioning, tiers, inference' do
  let(:db) { Sequel.sqlite }

  before do
    migration_path = File.expand_path('../../../../lib/legion/apollo/local/migrations', __dir__)
    Sequel::Migrator.run(db, migration_path, table: :schema_migrations_apollo_local)
  end

  it 'adds versioning columns to local_knowledge' do
    cols = db.schema(:local_knowledge).map(&:first)
    expect(cols).to include(:parent_knowledge_id, :is_latest, :supersession_type)
  end

  it 'adds inference column to local_knowledge' do
    cols = db.schema(:local_knowledge).map(&:first)
    expect(cols).to include(:is_inference)
  end

  it 'adds expiry metadata column to local_knowledge' do
    cols = db.schema(:local_knowledge).map(&:first)
    expect(cols).to include(:forget_reason)
  end

  it 'adds tier columns to local_knowledge' do
    cols = db.schema(:local_knowledge).map(&:first)
    expect(cols).to include(:summary_l0, :summary_l1, :knowledge_tier, :l0_generated_at, :l1_generated_at)
  end

  it 'creates local_source_links table' do
    expect(db.table_exists?(:local_source_links)).to be true
    cols = db.schema(:local_source_links).map(&:first)
    expect(cols).to include(:entry_id, :source_uri, :source_hash, :relevance_score, :extraction_method)
  end

  it 'defaults is_latest to true' do
    now = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%S.%LZ')
    db[:local_knowledge].insert(
      content: 'test', content_hash: 'abc123', tags: '[]',
      confidence: 1.0, expires_at: now, created_at: now, updated_at: now
    )
    row = db[:local_knowledge].first
    expect(row[:is_latest]).to eq(1) # SQLite boolean
  end

  it 'defaults is_inference to false' do
    now = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%S.%LZ')
    db[:local_knowledge].insert(
      content: 'test2', content_hash: 'def456', tags: '[]',
      confidence: 1.0, expires_at: now, created_at: now, updated_at: now
    )
    row = db[:local_knowledge].first
    expect(row[:is_inference]).to eq(0) # SQLite boolean
  end

  it 'defaults knowledge_tier to L2' do
    now = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%S.%LZ')
    db[:local_knowledge].insert(
      content: 'test3', content_hash: 'ghi789', tags: '[]',
      confidence: 1.0, expires_at: now, created_at: now, updated_at: now
    )
    row = db[:local_knowledge].first
    expect(row[:knowledge_tier]).to eq('L2')
  end
end
```

- [ ] **Step 3: Run migration spec**

Run: `bundle exec rspec spec/legion/apollo/local/migration_004_spec.rb -v`
Expected: All pass.

- [ ] **Step 4: Run existing migration spec for regression**

Run: `bundle exec rspec spec/legion/apollo/local/migration_spec.rb -v`
Expected: All pass.

- [ ] **Step 5: Commit**

```bash
git add lib/legion/apollo/local/migrations/004_add_versioning_tiers_inference.rb spec/legion/apollo/local/migration_004_spec.rb
git commit -m "feat: migration 004 — versioning, tiers, inference, expiry, source links (#6-#11)"
```

---

### Task 2: Settings Defaults and Confidence Constants

**Files:**
- Modify: `lib/legion/apollo/settings.rb`
- Modify: `lib/legion/apollo/helpers/confidence.rb`

- [ ] **Step 1: Add settings defaults**

In `lib/legion/apollo/settings.rb`, replace the `self.default` method:

Old:
```ruby
      def self.default
        {
          enabled:        true,
          max_tags:       20,
          default_limit:  5,
          min_confidence: 0.3,
          local:          local_defaults
        }
      end
```

New:
```ruby
      def self.default
        {
          enabled:        true,
          max_tags:       20,
          default_limit:  5,
          min_confidence: 0.3,
          local:          local_defaults,
          versioning:     versioning_defaults,
          expiry:         expiry_defaults
        }
      end
```

Then add these new class methods after `local_defaults`:

```ruby
      def self.versioning_defaults
        {
          enabled:                  true,
          supersession_threshold:   0.85,
          max_chain_depth:          50
        }
      end

      def self.expiry_defaults
        {
          enabled:            true,
          sweep_interval:     3600,
          warn_before_expiry: 86_400
        }
      end
```

- [ ] **Step 2: Add inference confidence constant**

In `lib/legion/apollo/helpers/confidence.rb`, add after the `ARCHIVE_THRESHOLD` line:

```ruby
        INITIAL_INFERENCE_CONFIDENCE = 0.35
```

- [ ] **Step 3: Run settings and confidence specs**

Run: `bundle exec rspec spec/legion/apollo/settings_spec.rb spec/legion/apollo/helpers/confidence_spec.rb -v`
Expected: All pass (existing specs don't check specific keys, just that defaults exist).

- [ ] **Step 4: Commit**

```bash
git add lib/legion/apollo/settings.rb lib/legion/apollo/helpers/confidence.rb
git commit -m "feat: add versioning/expiry settings defaults and INITIAL_INFERENCE_CONFIDENCE (#7-#9)"
```

---

### Task 3: Inference Tagging (#9) — Ingest and Query

**Files:**
- Modify: `lib/legion/apollo/local.rb`
- Create: `spec/legion/apollo/local/inference_spec.rb`

- [ ] **Step 1: Create inference spec**

```ruby
# frozen_string_literal: true

require 'spec_helper'
require 'sequel'
require 'sequel/extensions/migration'

RSpec.describe 'Apollo::Local inference tagging' do
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

  it 'stores is_inference flag on ingest' do
    Legion::Apollo::Local.ingest(content: 'LLM synthesized fact', tags: %w[ai], is_inference: true)
    row = db[:local_knowledge].where(content: 'LLM synthesized fact').first
    expect(row[:is_inference]).to eq(1)
  end

  it 'defaults is_inference to false' do
    Legion::Apollo::Local.ingest(content: 'Extracted fact from doc', tags: %w[doc])
    row = db[:local_knowledge].where(content: 'Extracted fact from doc').first
    expect(row[:is_inference]).to eq(0)
  end

  it 'uses INITIAL_INFERENCE_CONFIDENCE when is_inference and no explicit confidence' do
    Legion::Apollo::Local.ingest(content: 'Inferred knowledge', tags: %w[ai], is_inference: true)
    row = db[:local_knowledge].where(content: 'Inferred knowledge').first
    expect(row[:confidence]).to eq(Legion::Apollo::Helpers::Confidence::INITIAL_INFERENCE_CONFIDENCE)
  end

  it 'respects explicit confidence even for inferences' do
    Legion::Apollo::Local.ingest(content: 'High confidence inference', tags: %w[ai], is_inference: true, confidence: 0.8)
    row = db[:local_knowledge].where(content: 'High confidence inference').first
    expect(row[:confidence]).to eq(0.8)
  end

  it 'query includes inferences by default' do
    Legion::Apollo::Local.ingest(content: 'Extracted: Ruby is great', tags: %w[lang])
    Legion::Apollo::Local.ingest(content: 'Inferred: Ruby community is strong', tags: %w[lang], is_inference: true)
    result = Legion::Apollo::Local.query(text: 'Ruby', tags: %w[lang])
    expect(result[:results].size).to eq(2)
  end

  it 'query filters out inferences when include_inferences: false' do
    Legion::Apollo::Local.ingest(content: 'Extracted: Python is popular', tags: %w[lang])
    Legion::Apollo::Local.ingest(content: 'Inferred: Python will dominate', tags: %w[lang], is_inference: true)
    result = Legion::Apollo::Local.query(text: 'Python', tags: %w[lang], include_inferences: false)
    contents = result[:results].map { |r| r[:content] }
    expect(contents).to include('Extracted: Python is popular')
    expect(contents).not_to include('Inferred: Python will dominate')
  end
end
```

- [ ] **Step 2: Run to verify failures**

Run: `bundle exec rspec spec/legion/apollo/local/inference_spec.rb -v`
Expected: Failures because `is_inference` isn't written by `build_ingest_row` and `filter_candidates` doesn't filter on it.

- [ ] **Step 3: Modify `build_ingest_row` in `local.rb`**

In `lib/legion/apollo/local.rb`, find `build_ingest_row` (around line 388). Replace:

```ruby
        def build_ingest_row(content:, hash:, tags:, **opts)
          {
            content:        content,
            content_hash:   hash,
            tags:           serialized_tags(tags),
            source_channel: opts[:source_channel],
            source_agent:   opts[:source_agent],
            submitted_by:   opts[:submitted_by],
            confidence:     opts[:confidence] || 1.0
          }.merge(embedding_columns(content)).merge(timestamp_columns)
        end
```

New:
```ruby
        def build_ingest_row(content:, hash:, tags:, **opts)
          is_inference = opts[:is_inference] == true
          default_confidence = is_inference ? Legion::Apollo::Helpers::Confidence::INITIAL_INFERENCE_CONFIDENCE : 1.0
          {
            content:        content,
            content_hash:   hash,
            tags:           serialized_tags(tags),
            source_channel: opts[:source_channel],
            source_agent:   opts[:source_agent],
            submitted_by:   opts[:submitted_by],
            confidence:     opts[:confidence] || default_confidence,
            is_inference:   is_inference
          }.merge(embedding_columns(content)).merge(timestamp_columns)
        end
```

- [ ] **Step 4: Add `include_inferences` filter to `filter_candidates`**

In `lib/legion/apollo/local.rb`, find `filter_candidates` (around line 494). Replace:

```ruby
        def filter_candidates(candidates, min_confidence:, tags:)
          candidates = candidates.select { |c| (c[:confidence] || 0) >= min_confidence }
          if tags && !tags.empty?
            tag_set = Array(tags).map(&:to_s)
            candidates = candidates.select do |c|
              entry_tags = parse_tags(c[:tags])
              tag_set.intersect?(entry_tags)
            end
          end
          candidates
        end
```

New:
```ruby
        def filter_candidates(candidates, min_confidence:, tags:, include_inferences: true)
          candidates = candidates.select { |c| (c[:confidence] || 0) >= min_confidence }
          unless include_inferences
            candidates = candidates.reject { |c| c[:is_inference] == 1 || c[:is_inference] == true }
          end
          if tags && !tags.empty?
            tag_set = Array(tags).map(&:to_s)
            candidates = candidates.select do |c|
              entry_tags = parse_tags(c[:tags])
              tag_set.intersect?(entry_tags)
            end
          end
          candidates
        end
```

- [ ] **Step 5: Pass `include_inferences` through `query`**

In `lib/legion/apollo/local.rb`, find the `query` method. Change the call to `filter_candidates` to pass through the new parameter. Find:

```ruby
          candidates = filter_candidates(candidates, min_confidence: min_confidence, tags: tags)
```

Replace with:

```ruby
          include_inferences = opts.fetch(:include_inferences, true)
          candidates = filter_candidates(candidates, min_confidence: min_confidence, tags: tags,
                                                     include_inferences: include_inferences)
```

Also update the `query` method signature to capture `**opts`:

Change:
```ruby
        def query(text:, limit: nil, min_confidence: nil, tags: nil, **) # rubocop:disable Metrics/MethodLength,Metrics/AbcSize
```

To:
```ruby
        def query(text:, limit: nil, min_confidence: nil, tags: nil, **opts) # rubocop:disable Metrics/MethodLength,Metrics/AbcSize
```

- [ ] **Step 6: Run inference specs**

Run: `bundle exec rspec spec/legion/apollo/local/inference_spec.rb -v`
Expected: All pass.

- [ ] **Step 7: Run existing query specs for regression**

Run: `bundle exec rspec spec/legion/apollo/local/query_spec.rb spec/legion/apollo/local/fts_escaping_spec.rb -v`
Expected: All pass.

- [ ] **Step 8: Commit**

```bash
git add lib/legion/apollo/local.rb spec/legion/apollo/local/inference_spec.rb
git commit -m "feat: inference tagging on ingest/query with INITIAL_INFERENCE_CONFIDENCE (#9)"
```

---

### Task 4: Temporal Expiry Metadata (#8) — forget_reason on Ingest

**Files:**
- Modify: `lib/legion/apollo/local.rb`
- Create: `spec/legion/apollo/local/expiry_spec.rb`

- [ ] **Step 1: Create expiry spec**

```ruby
# frozen_string_literal: true

require 'spec_helper'
require 'sequel'
require 'sequel/extensions/migration'

RSpec.describe 'Apollo::Local temporal expiry metadata' do
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

  it 'stores forget_reason on ingest' do
    Legion::Apollo::Local.ingest(
      content: 'Deployment freeze until June',
      tags: %w[policy],
      forget_reason: 'policy: deployment freeze window ends'
    )
    row = db[:local_knowledge].where(content: 'Deployment freeze until June').first
    expect(row[:forget_reason]).to eq('policy: deployment freeze window ends')
  end

  it 'stores custom expires_at on ingest' do
    future = (Time.now.utc + 86_400).strftime('%Y-%m-%dT%H:%M:%S.%LZ')
    Legion::Apollo::Local.ingest(
      content: 'Short-lived policy note',
      tags: %w[policy],
      expires_at: future,
      forget_reason: 'policy: 24h window'
    )
    row = db[:local_knowledge].where(content: 'Short-lived policy note').first
    expect(row[:expires_at]).to eq(future)
  end

  it 'defaults forget_reason to nil' do
    Legion::Apollo::Local.ingest(content: 'Regular fact', tags: %w[general])
    row = db[:local_knowledge].where(content: 'Regular fact').first
    expect(row[:forget_reason]).to be_nil
  end

  it 'uses default retention when no explicit expires_at' do
    Legion::Apollo::Local.ingest(content: 'Default expiry fact', tags: %w[general])
    row = db[:local_knowledge].where(content: 'Default expiry fact').first
    expect(row[:expires_at]).not_to be_nil
    parsed = Time.parse(row[:expires_at])
    expect(parsed).to be > (Time.now.utc + (4 * 365.25 * 24 * 3600))
  end
end
```

- [ ] **Step 2: Modify `build_ingest_row` to include `forget_reason` and custom `expires_at`**

In `lib/legion/apollo/local.rb`, update `build_ingest_row` (the version from Task 3). Replace:

```ruby
          }.merge(embedding_columns(content)).merge(timestamp_columns)
```

With:

```ruby
            forget_reason: opts[:forget_reason]
          }.merge(embedding_columns(content, opts)).merge(timestamp_columns)
```

Then modify `embedding_columns` to accept and pass through `opts[:expires_at]`. Find:

```ruby
        def embedding_columns(content)
          embedding, embedded_at = generate_embedding(content)

          {
            embedding:   embedding ? Legion::JSON.dump(embedding) : nil,
            embedded_at: embedded_at,
            expires_at:  compute_expires_at
          }
        end
```

Replace with:

```ruby
        def embedding_columns(content, opts = {})
          embedding, embedded_at = generate_embedding(content)

          {
            embedding:   embedding ? Legion::JSON.dump(embedding) : nil,
            embedded_at: embedded_at,
            expires_at:  opts[:expires_at] || compute_expires_at
          }
        end
```

- [ ] **Step 3: Run expiry specs**

Run: `bundle exec rspec spec/legion/apollo/local/expiry_spec.rb -v`
Expected: All pass.

- [ ] **Step 4: Run existing specs for regression**

Run: `bundle exec rspec spec/legion/apollo/local/ingest_spec.rb spec/legion/apollo/local/query_spec.rb -v`
Expected: All pass.

- [ ] **Step 5: Commit**

```bash
git add lib/legion/apollo/local.rb spec/legion/apollo/local/expiry_spec.rb
git commit -m "feat: temporal expiry metadata — forget_reason and custom expires_at on ingest (#8)"
```

---

### Task 5: Versioned Knowledge (#7) — Supersession on Ingest and Version Chain

**Files:**
- Modify: `lib/legion/apollo/local.rb`
- Modify: `lib/legion/apollo/local/graph.rb`
- Create: `spec/legion/apollo/local/versioning_spec.rb`

- [ ] **Step 1: Create versioning spec**

```ruby
# frozen_string_literal: true

require 'spec_helper'
require 'sequel'
require 'sequel/extensions/migration'

RSpec.describe 'Apollo::Local versioning' do
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

  it 'creates versioned entry with parent_knowledge_id' do
    result1 = Legion::Apollo::Local.ingest(content: 'Original policy', tags: %w[policy])
    parent_id = result1[:id]

    result2 = Legion::Apollo::Local.ingest(
      content: 'Updated policy v2',
      tags: %w[policy],
      parent_knowledge_id: parent_id,
      supersession_type: 'updates'
    )

    parent = db[:local_knowledge].where(id: parent_id).first
    child = db[:local_knowledge].where(id: result2[:id]).first

    expect(parent[:is_latest]).to eq(0)
    expect(child[:is_latest]).to eq(1)
    expect(child[:parent_knowledge_id]).to eq(parent_id)
    expect(child[:supersession_type]).to eq('updates')
  end

  it 'default query only returns is_latest entries' do
    result1 = Legion::Apollo::Local.ingest(content: 'Deploy policy v1', tags: %w[deploy])
    Legion::Apollo::Local.ingest(
      content: 'Deploy policy v2',
      tags: %w[deploy],
      parent_knowledge_id: result1[:id],
      supersession_type: 'updates'
    )

    results = Legion::Apollo::Local.query(text: 'Deploy policy', tags: %w[deploy])
    contents = results[:results].map { |r| r[:content] }
    expect(contents).to include('Deploy policy v2')
    expect(contents).not_to include('Deploy policy v1')
  end

  it 'query with include_history returns all versions' do
    result1 = Legion::Apollo::Local.ingest(content: 'Auth policy v1', tags: %w[auth])
    Legion::Apollo::Local.ingest(
      content: 'Auth policy v2',
      tags: %w[auth],
      parent_knowledge_id: result1[:id],
      supersession_type: 'updates'
    )

    results = Legion::Apollo::Local.query(text: 'Auth policy', tags: %w[auth], include_history: true)
    contents = results[:results].map { |r| r[:content] }
    expect(contents).to include('Auth policy v1', 'Auth policy v2')
  end

  it 'version_chain returns ordered history' do
    r1 = Legion::Apollo::Local.ingest(content: 'Config v1', tags: %w[config])
    r2 = Legion::Apollo::Local.ingest(content: 'Config v2', tags: %w[config],
                                      parent_knowledge_id: r1[:id], supersession_type: 'updates')
    r3 = Legion::Apollo::Local.ingest(content: 'Config v3', tags: %w[config],
                                      parent_knowledge_id: r2[:id], supersession_type: 'updates')

    chain = Legion::Apollo::Local.version_chain(entry_id: r3[:id])
    expect(chain[:success]).to be true
    expect(chain[:chain].map { |e| e[:content] }).to eq(['Config v3', 'Config v2', 'Config v1'])
  end
end
```

- [ ] **Step 2: Add SUPERSEDES to graph VALID_RELATION_TYPES**

In `lib/legion/apollo/local/graph.rb`, change:

```ruby
        VALID_RELATION_TYPES = %w[AFFECTS OWNED_BY DEPENDS_ON RELATED_TO].freeze
```

To:

```ruby
        VALID_RELATION_TYPES = %w[AFFECTS OWNED_BY DEPENDS_ON RELATED_TO SUPERSEDES].freeze
```

- [ ] **Step 3: Add versioning logic to `build_ingest_row` and post-ingest hook**

In `lib/legion/apollo/local.rb`, modify `ingest_without_lock` to handle supersession. Replace:

```ruby
        def ingest_without_lock(content:, tags:, **opts) # rubocop:disable Metrics/MethodLength,Metrics/AbcSize
          hash = content_hash(content)
          return deduplicated_ingest(hash) if duplicate?(hash)

          log.info do
            "Apollo::Local ingest accepted content_length=#{content.to_s.length} " \
              "tags=#{Array(tags).size} source_channel=#{opts[:source_channel]}"
          end
          log.debug { "Apollo::Local ingest hash=#{hash} tags=#{Array(tags).size} source_channel=#{opts[:source_channel]}" }

          row = build_ingest_row(content: content, hash: hash, tags: tags, **opts)
          id = persist_ingest_row(row)

          log.info { "Apollo::Local ingest stored id=#{id} hash=#{hash}" }
          { success: true, mode: :local, id: id }
        rescue Sequel::UniqueConstraintViolation
          raise unless duplicate?(hash)

          deduplicated_ingest(hash)
        end
```

New:

```ruby
        def ingest_without_lock(content:, tags:, **opts) # rubocop:disable Metrics/MethodLength,Metrics/AbcSize
          hash = content_hash(content)
          return deduplicated_ingest(hash) if duplicate?(hash)

          log.info do
            "Apollo::Local ingest accepted content_length=#{content.to_s.length} " \
              "tags=#{Array(tags).size} source_channel=#{opts[:source_channel]}"
          end
          log.debug { "Apollo::Local ingest hash=#{hash} tags=#{Array(tags).size} source_channel=#{opts[:source_channel]}" }

          row = build_ingest_row(content: content, hash: hash, tags: tags, **opts)
          id = persist_ingest_row(row)
          mark_parent_superseded(opts[:parent_knowledge_id]) if opts[:parent_knowledge_id]

          log.info { "Apollo::Local ingest stored id=#{id} hash=#{hash}" }
          { success: true, mode: :local, id: id }
        rescue Sequel::UniqueConstraintViolation
          raise unless duplicate?(hash)

          deduplicated_ingest(hash)
        end
```

Add `mark_parent_superseded` private method and `version_chain` public method. Add these private methods after `deduplicated_ingest`:

```ruby
        def mark_parent_superseded(parent_id)
          return unless parent_id

          db[:local_knowledge].where(id: parent_id).update(is_latest: false)
          log.info { "Apollo::Local marked entry id=#{parent_id} as superseded" }
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'apollo.local.mark_parent_superseded', parent_id: parent_id)
        end
```

Add the `version_chain` as a public method (inside `class << self`, before `private`):

```ruby
        def version_chain(entry_id:, max_depth: 50) # rubocop:disable Metrics/MethodLength
          return not_started_error unless started?

          chain = []
          current_id = entry_id
          seen = Set.new

          max_depth.times do
            break unless current_id
            break if seen.include?(current_id)

            seen.add(current_id)
            row = db[:local_knowledge].where(id: current_id).first
            break unless row

            chain << row
            current_id = row[:parent_knowledge_id]
          end

          { success: true, chain: chain, count: chain.size }
        rescue StandardError => e
          handle_exception(e, level: :error, operation: 'apollo.local.version_chain', entry_id: entry_id)
          { success: false, error: e.message }
        end
```

- [ ] **Step 4: Add `parent_knowledge_id` and `supersession_type` to `build_ingest_row`**

Update `build_ingest_row` to include versioning columns. After the `is_inference` line, add:

```ruby
            parent_knowledge_id: opts[:parent_knowledge_id],
            supersession_type:   opts[:supersession_type],
```

- [ ] **Step 5: Add `is_latest` filter to `filter_candidates`**

In `filter_candidates`, add a filter for `is_latest` after the `include_inferences` filter. Add:

```ruby
          include_history = opts_hash.fetch(:include_history, false)
          unless include_history
            candidates = candidates.select { |c| c[:is_latest] != 0 && c[:is_latest] != false }
          end
```

Wait — `filter_candidates` doesn't receive `opts` yet. Update the `query` method to pass `include_history`:

In the `query` method, after the `include_inferences` line, add:

```ruby
          include_history = opts.fetch(:include_history, false)
```

And update the `filter_candidates` call:

```ruby
          candidates = filter_candidates(candidates, min_confidence: min_confidence, tags: tags,
                                                     include_inferences: include_inferences,
                                                     include_history: include_history)
```

Then update `filter_candidates` signature and body:

```ruby
        def filter_candidates(candidates, min_confidence:, tags:, include_inferences: true, include_history: false) # rubocop:disable Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity,Metrics/MethodLength
          candidates = candidates.select { |c| (c[:confidence] || 0) >= min_confidence }
          unless include_inferences
            candidates = candidates.reject { |c| c[:is_inference] == 1 || c[:is_inference] == true }
          end
          unless include_history
            candidates = candidates.select { |c| c[:is_latest].nil? || c[:is_latest] == 1 || c[:is_latest] == true }
          end
          if tags && !tags.empty?
            tag_set = Array(tags).map(&:to_s)
            candidates = candidates.select do |c|
              entry_tags = parse_tags(c[:tags])
              tag_set.intersect?(entry_tags)
            end
          end
          candidates
        end
```

Note: `c[:is_latest].nil?` handles pre-migration entries that don't have the column.

- [ ] **Step 6: Run versioning specs**

Run: `bundle exec rspec spec/legion/apollo/local/versioning_spec.rb -v`
Expected: All pass.

- [ ] **Step 7: Run all local specs for regression**

Run: `bundle exec rspec spec/legion/apollo/local/ -v`
Expected: All pass.

- [ ] **Step 8: Commit**

```bash
git add lib/legion/apollo/local.rb lib/legion/apollo/local/graph.rb spec/legion/apollo/local/versioning_spec.rb
git commit -m "feat: versioned knowledge entries with supersession and version_chain (#7)"
```

---

### Task 6: Tiered Retrieval (#6) — L0/L1/L2 Projection on Query

**Files:**
- Modify: `lib/legion/apollo/local.rb`
- Create: `spec/legion/apollo/local/tiered_query_spec.rb`

- [ ] **Step 1: Create tiered query spec**

```ruby
# frozen_string_literal: true

require 'spec_helper'
require 'sequel'
require 'sequel/extensions/migration'

RSpec.describe 'Apollo::Local tiered retrieval' do
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

    Legion::Apollo::Local.ingest(content: 'A' * 300, tags: %w[test])

    now = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%S.%LZ')
    db[:local_knowledge].where(content: 'A' * 300).update(
      summary_l0: 'Short summary',
      summary_l1: 'Medium paragraph summary of the content',
      knowledge_tier: 'L0',
      l0_generated_at: now,
      l1_generated_at: now
    )
  end

  after { Legion::Apollo::Local.shutdown }

  it 'returns full content at tier :l2 (default)' do
    result = Legion::Apollo::Local.query(text: 'AAAA')
    expect(result[:results].first[:content]).to eq('A' * 300)
    expect(result[:tier]).to be_nil
  end

  it 'returns l0 summary projection' do
    result = Legion::Apollo::Local.query(text: 'AAAA', tier: :l0)
    entry = result[:results].first
    expect(entry[:summary]).to eq('Short summary')
    expect(entry).not_to have_key(:content)
    expect(result[:tier]).to eq(:l0)
  end

  it 'returns l1 summary projection' do
    result = Legion::Apollo::Local.query(text: 'AAAA', tier: :l1)
    entry = result[:results].first
    expect(entry[:summary]).to eq('Medium paragraph summary of the content')
    expect(entry).not_to have_key(:content)
    expect(result[:tier]).to eq(:l1)
  end

  it 'falls back to truncated content when l0 summary missing' do
    Legion::Apollo::Local.ingest(content: 'B' * 300, tags: %w[test])
    result = Legion::Apollo::Local.query(text: 'BBBB', tier: :l0)
    entry = result[:results].first
    expect(entry[:summary].length).to be <= 200
  end

  it 'falls back to truncated content when l1 summary missing' do
    Legion::Apollo::Local.ingest(content: 'C' * 1500, tags: %w[test])
    result = Legion::Apollo::Local.query(text: 'CCCC', tier: :l1)
    entry = result[:results].first
    expect(entry[:summary].length).to be <= 1000
  end
end
```

- [ ] **Step 2: Add `tier:` parameter and `project_tier` to local.rb**

In `lib/legion/apollo/local.rb`, update the `query` method. After `results = candidates.first(limit)`, add tier projection:

```ruby
          tier = opts[:tier]
          results = results.map { |r| project_tier(r, tier) } if tier
```

And update the return value to include tier:

```ruby
          { success: true, results: results, count: results.size, mode: :local, tier: tier }
```

Add the `project_tier` private method:

```ruby
        def project_tier(entry, tier)
          case tier
          when :l0
            entry.slice(:id, :content_hash, :confidence, :tags, :source_channel, :is_inference, :is_latest).merge(
              summary: entry[:summary_l0] || entry[:content]&.slice(0, 200)
            )
          when :l1
            entry.slice(:id, :content_hash, :confidence, :tags, :source_channel, :is_inference, :is_latest).merge(
              summary: entry[:summary_l1] || entry[:content]&.slice(0, 1000)
            )
          else
            entry
          end
        end
```

- [ ] **Step 3: Run tiered query specs**

Run: `bundle exec rspec spec/legion/apollo/local/tiered_query_spec.rb -v`
Expected: All pass.

- [ ] **Step 4: Commit**

```bash
git add lib/legion/apollo/local.rb spec/legion/apollo/local/tiered_query_spec.rb
git commit -m "feat: L0/L1/L2 tiered retrieval with summary projection (#6)"
```

---

### Task 7: Source-to-Fact Linkage (#10)

**Files:**
- Modify: `lib/legion/apollo/local.rb`
- Create: `spec/legion/apollo/local/source_links_spec.rb`

- [ ] **Step 1: Create source links spec**

```ruby
# frozen_string_literal: true

require 'spec_helper'
require 'sequel'
require 'sequel/extensions/migration'

RSpec.describe 'Apollo::Local source linkage' do
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

  it 'stores source link on ingest when source metadata provided' do
    result = Legion::Apollo::Local.ingest(
      content: 'Extracted fact from wiki',
      tags: %w[wiki],
      source_uri: 'https://wiki.example.com/page',
      source_hash: 'abc123',
      relevance_score: 0.95,
      extraction_method: 'ner'
    )
    links = db[:local_source_links].where(entry_id: result[:id]).all
    expect(links.size).to eq(1)
    expect(links.first[:source_uri]).to eq('https://wiki.example.com/page')
    expect(links.first[:relevance_score]).to eq(0.95)
    expect(links.first[:extraction_method]).to eq('ner')
  end

  it 'does not create source link when no source_uri' do
    result = Legion::Apollo::Local.ingest(content: 'No source fact', tags: %w[general])
    links = db[:local_source_links].where(entry_id: result[:id]).all
    expect(links).to be_empty
  end

  it 'source_links_for returns links for an entry' do
    result = Legion::Apollo::Local.ingest(
      content: 'Linked fact',
      tags: %w[linked],
      source_uri: 'https://docs.example.com/api',
      relevance_score: 0.8
    )
    links = Legion::Apollo::Local.source_links_for(entry_id: result[:id])
    expect(links[:success]).to be true
    expect(links[:links].size).to eq(1)
    expect(links[:links].first[:source_uri]).to eq('https://docs.example.com/api')
  end
end
```

- [ ] **Step 2: Add source link creation in `persist_ingest_row` and `source_links_for` method**

In `lib/legion/apollo/local.rb`, modify `persist_ingest_row`:

```ruby
        def persist_ingest_row(row, opts = {})
          db.transaction do
            id = db[:local_knowledge].insert(row)
            sync_fts!(id, row[:content], row[:tags])
            create_source_link(id, opts) if opts[:source_uri]
            id
          end
        end
```

Update the call site in `ingest_without_lock` from:

```ruby
          row = build_ingest_row(content: content, hash: hash, tags: tags, **opts)
          id = persist_ingest_row(row)
```

To:

```ruby
          row = build_ingest_row(content: content, hash: hash, tags: tags, **opts)
          id = persist_ingest_row(row, opts)
```

Add private method:

```ruby
        def create_source_link(entry_id, opts)
          db[:local_source_links].insert(
            entry_id:          entry_id,
            source_uri:        opts[:source_uri],
            source_hash:       opts[:source_hash],
            relevance_score:   opts[:relevance_score] || 1.0,
            extraction_method: opts[:extraction_method],
            created_at:        Time.now.utc.strftime('%Y-%m-%dT%H:%M:%S.%LZ')
          )
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'apollo.local.create_source_link', entry_id: entry_id)
        end
```

Add public method `source_links_for` (before `private`):

```ruby
        def source_links_for(entry_id:)
          return not_started_error unless started?

          links = db[:local_source_links].where(entry_id: entry_id).all
          { success: true, links: links, count: links.size }
        rescue StandardError => e
          handle_exception(e, level: :error, operation: 'apollo.local.source_links_for', entry_id: entry_id)
          { success: false, error: e.message }
        end
```

- [ ] **Step 3: Run source links specs**

Run: `bundle exec rspec spec/legion/apollo/local/source_links_spec.rb -v`
Expected: All pass.

- [ ] **Step 4: Commit**

```bash
git add lib/legion/apollo/local.rb spec/legion/apollo/local/source_links_spec.rb
git commit -m "feat: source-to-fact linkage with relevance scores (#10)"
```

---

### Task 8: Pass Through New Parameters in Public API and Routes (#6-#11)

**Files:**
- Modify: `lib/legion/apollo.rb`
- Modify: `lib/legion/apollo/routes.rb`

- [ ] **Step 1: Update `Legion::Apollo.query` to pass through `tier:`, `include_inferences:`, `include_history:`**

In `lib/legion/apollo.rb`, the `query` method already passes `**opts` through to `query_local` which slices params. Update `query_local` to include new params in the slice. Find:

```ruby
        result = Legion::Apollo::Local.query(**payload.slice(:text, :limit, :min_confidence, :tags))
```

Replace (appears twice — in `query_local` and `query_merged`):

```ruby
        result = Legion::Apollo::Local.query(**payload.slice(:text, :limit, :min_confidence, :tags,
                                                             :tier, :include_inferences, :include_history))
```

- [ ] **Step 2: Update routes to pass through new params**

In `lib/legion/apollo/routes.rb`, in `register_query_route`, add new params to the `Legion::Apollo.query` call. Find:

```ruby
          result = Legion::Apollo.query(
            text:           body[:query],
            limit:          body[:limit] || default_limit,
            min_confidence: body[:min_confidence],
            status:         body[:status] || [:confirmed],
            tags:           body[:tags],
            domain:         body[:domain],
            agent_id:       body[:agent_id] || 'api',
            scope:          normalize_scope(body[:scope])
          )
```

Replace with:

```ruby
          result = Legion::Apollo.query(
            text:               body[:query],
            limit:              body[:limit] || default_limit,
            min_confidence:     body[:min_confidence],
            status:             body[:status] || [:confirmed],
            tags:               body[:tags],
            domain:             body[:domain],
            agent_id:           body[:agent_id] || 'api',
            scope:              normalize_scope(body[:scope]),
            tier:               body[:tier]&.to_sym,
            include_inferences: body.fetch(:include_inferences, true),
            include_history:    body.fetch(:include_history, false)
          )
```

In `register_ingest_route`, add new params. Find the `Legion::Apollo.ingest` call and add after `scope:`:

```ruby
            is_inference:       body[:is_inference] == true,
            forget_reason:      body[:forget_reason],
            expires_at:         body[:expires_at],
            parent_knowledge_id: body[:parent_knowledge_id],
            supersession_type:  body[:supersession_type],
            source_uri:         body[:source_uri],
            source_hash:        body[:source_hash],
            relevance_score:    body[:relevance_score],
            extraction_method:  body[:extraction_method]
```

- [ ] **Step 3: Run routes and scope specs**

Run: `bundle exec rspec spec/legion/apollo/routes_spec.rb spec/legion/apollo/scope_spec.rb -v`
Expected: All pass.

- [ ] **Step 4: Commit**

```bash
git add lib/legion/apollo.rb lib/legion/apollo/routes.rb
git commit -m "feat: pass through versioning, inference, tier, expiry, and source params in API (#6-#11)"
```

---

### Task 9: Knowledge Graph Enhancement (#11) — Entity Extraction Helpers

**Files:**
- Modify: `lib/legion/apollo/local/graph.rb`
- No separate spec — existing graph specs cover CRUD; the new relation type SUPERSEDES was added in Task 5

This is a light touch for #11. The issue asks for NER entity extraction + clustering + traversal. We already have entity CRUD and BFS traversal. The main gap from the issue is the `SUPERSEDES` relation type (added in Task 5). Full NER extraction requires LLM integration which is out of scope for this gem (belongs in lex-apollo). We mark this as partially addressed.

- [ ] **Step 1: Run existing graph specs to verify SUPERSEDES works**

Run: `bundle exec rspec spec/legion/apollo/local/graph_spec.rb -v`
Expected: All pass.

- [ ] **Step 2: No code changes needed — commit is not required**

The SUPERSEDES addition was already committed in Task 5.

---

### Task 10: Full Suite Regression + Rubocop + CHANGELOG + Push

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Run full test suite**

Run: `bundle exec rspec spec/ -v`
Expected: All pass, 0 failures.

- [ ] **Step 2: Run rubocop on all changed files**

Run: `bundle exec rubocop lib/ spec/`
Expected: 0 offenses. If there are offenses, fix them.

- [ ] **Step 3: Update CHANGELOG**

Add entries under the `## [0.5.0]` section for all new features:

```markdown
### Added
- Migration 004: versioning, tiers, inference, expiry metadata, and source linkage columns on local_knowledge; local_source_links table (#6-#11)
- Inference tagging: `is_inference` flag on ingest, `include_inferences:` filter on query, INITIAL_INFERENCE_CONFIDENCE (0.35) for LLM-derived entries (#9)
- Temporal expiry metadata: `forget_reason` and custom `expires_at` on ingest (#8)
- Versioned knowledge: `parent_knowledge_id`/`is_latest`/`supersession_type` on ingest, automatic parent supersession, `version_chain` traversal, `include_history:` query filter (#7)
- L0/L1/L2 tiered retrieval: `tier:` parameter on query with summary projection and truncation fallback (#6)
- Source-to-fact linkage: `source_uri`/`source_hash`/`relevance_score`/`extraction_method` on ingest, `source_links_for` query method, local_source_links table (#10)
- SUPERSEDES relation type in Local::Graph (#11)
- Versioning and expiry settings defaults
```

- [ ] **Step 4: Commit and push**

```bash
git add -A
git commit -m "feat: local store enhancements for versioning, tiers, inference, expiry, source links (#6-#11)"
git push origin dev-v0.5.0
```

- [ ] **Step 5: Update PR description**

Update PR #24 body to include the new issue references with `Fixes #6`, `Fixes #7`, etc.
