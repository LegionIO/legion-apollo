# Changelog

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
