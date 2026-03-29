# Changelog

## [0.3.5] - 2026-03-28

### Fixed
- use `Legion::LLM.embed` instead of `Legion::LLM::Embeddings.generate` in Local store — the Embeddings module is autoloaded and not available until `embed` or `embed_direct` is called through the public API

## [0.3.4] - 2026-03-28

### Added
- `Legion::Apollo::Local::Graph` — entity-relationship graph layer backed by local SQLite tables
  - `create_entity`, `find_entity`, `find_entities_by_type`, `find_entities_by_name`, `update_entity`, `delete_entity` — full entity CRUD
  - `create_relationship`, `find_relationships`, `delete_relationship` — directional typed edge CRUD
  - `traverse(entity_id:, relation_type:, depth:, direction:)` — iterative BFS graph traversal with depth limiting (max 10), relation-type and direction (:outbound/:inbound) filtering, cycle-safe visited set, no duplicate nodes or edges in result
  - `delete_entity` cascades and removes associated relationships
  - `find_relationships` supports `direction: :both` via SQLite UNION
- Migration `002_create_graph_tables` — `local_entities` and `local_relationships` tables with indexes and foreign keys
- `Legion::Apollo::Local.graph` accessor returning `Legion::Apollo::Local::Graph`
- `Legion::Apollo.graph_query(entity_id:, relation_type:, depth:, direction:)` — public API delegating to `Local::Graph.traverse`; returns `:local_not_started` when Local store is unavailable

## [0.3.3] - 2026-03-28

### Added
- `Legion::Apollo::Routes` Sinatra extension module (`lib/legion/apollo/routes.rb`): all `/api/apollo/*` route definitions extracted from `LegionIO/lib/legion/api/apollo.rb`. Self-registers with `Legion::API.register_library_routes('apollo', Legion::Apollo::Routes)` during `Legion::Apollo.start`, immediately after `@started` is set (before `Local.start` / `seed_self_knowledge`).
- `register_routes` private method on `Legion::Apollo` module.

### Changed
- `Legion::Apollo.start` now calls `register_routes` after setting `@started = true`.

## [0.3.2] - 2026-03-26

### Added
- Self-knowledge seed system: 10 markdown documents covering LegionIO identity, architecture, extensions, security, LLM pipeline, Apollo, CLI, cognitive layer, Teams integration, and deployment
- `Apollo::Local.seed_self_knowledge` auto-ingests self-knowledge docs on boot (local + global)
- `Apollo::Local.seeded?` query method
- `data/**/*` included in gemspec so self-knowledge ships with the gem

### Changed
- Refactored `seed_self_knowledge` into smaller helpers (`self_knowledge_files`, `seed_files`, `seed_single_file`) to satisfy rubocop complexity

## [0.3.1] - 2026-03-26

### Added
- `scope:` param on `query`/`retrieve`/`ingest` — `:global` (default), `:local` (SQLite only), `:all` (merged global + local)
- `Legion::Apollo::Runners::Request` shim — GAIA `knowledge_retrieval` phase now resolves to merged retrieval without any changes to `legion-gaia`
- Merge helpers: `query_merged`, `normalize_local_entries`, `normalize_global_entries`, `dedup_and_rank`
- Ingest routing: `ingest_local` and `ingest_all` private helpers

## [0.3.0] - 2026-03-25

### Added
- `Legion::Apollo::Local` — node-local knowledge store backed by SQLite + FTS5
- Local settings defaults (retention_years, default_query_scope, fts_candidate_multiplier)
- SQLite migration with FTS5 virtual table for full-text search
- Ingest with content hash dedup, optional LLM embedding, configurable TTL (5-year default)
- Query with FTS5 keyword search, tag filtering, confidence gating, cosine rerank
- `embedded_at` column for future embedding backfill identification
- `.local` accessor on `Legion::Apollo` module

## [0.2.1] - 2026-03-25

### Added
- Initial gem scaffold: `Legion::Apollo` public API (`start`, `shutdown`, `query`, `ingest`, `retrieve`)
- `Legion::Apollo::Settings` with default configuration values
- Transport message envelope classes: `Ingest`, `Query`, `Writeback`, `AccessBoost`
- Helper modules: `Confidence` constants, `Similarity` math, `TagNormalizer`
- Smart routing: co-located lex-apollo service, RabbitMQ transport, graceful failure
