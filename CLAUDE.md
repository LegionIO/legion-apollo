# legion-apollo

**Parent**: `/Users/miverso2/rubymine/legion/CLAUDE.md`

## What is legion-apollo?

Core library gem (loaded on every LegionIO node) that provides the Apollo knowledge store client API. Extracts client-side Apollo code from `lex-apollo` (extension) so all nodes can read/write knowledge without running the full Apollo extension.

**Version**: 0.3.2
**GitHub**: https://github.com/LegionIO/legion-apollo

## Architecture

- `Legion::Apollo` — public API: `start`, `shutdown`, `query`, `ingest`, `retrieve`; scope: `:global` (default), `:local` (SQLite only), `:all` (merged with dedup+rank)
- `Legion::Apollo::Local` — node-local SQLite+FTS5 knowledge store mirroring the public API; requires `Legion::Data::Local`
- `Legion::Apollo::Settings` — default configuration values
- `Legion::Apollo::Runners::Request` — self-contained actor for handling Apollo request messages
- `Legion::Apollo::Messages::*` — transport envelope classes (Ingest, Query, Writeback, AccessBoost)
- `Legion::Apollo::Helpers::Confidence` — confidence constants and predicates
- `Legion::Apollo::Helpers::Similarity` — cosine similarity math and match classification
- `Legion::Apollo::Helpers::TagNormalizer` — tag normalization (lowercase, dedup, truncate)

## Routing Logic

Query and ingest accept a `scope:` keyword:

| Scope | Route |
|-------|-------|
| `:global` (default) | co-located lex-apollo direct call, or RabbitMQ transport, or `{ success: false, error: :no_path_available }` |
| `:local` | `Apollo::Local` SQLite FTS5 store only |
| `:all` | global + local merged, deduped by `content_hash`, ranked by confidence |

Ingest scope `:all` writes to both global and local paths; returns combined results.

## Local Store (`Apollo::Local`)

- Backed by `Legion::Data::Local` (SQLite + FTS5 virtual table)
- Migration: `lib/legion/apollo/local/migrations/001_create_local_knowledge.rb`
- Content-hash dedup (MD5 of normalized content)
- Optional LLM embeddings (1024-dim, guarded by `Legion::LLM.can_embed?`)
- Cosine rerank when embeddings available
- TTL expiry via `expires_at` column (default: `Settings[:apollo][:local][:retention_years]`, 5 years)
- FTS5 search with fallback to `ILIKE` if FTS fails
- `Apollo::Local.start` — no-op if `data.local.enabled: false` or Data::Local unavailable

## Key Rules

- All Legion:: namespace prefixes required (::Process, ::JSON, ::Data)
- Optional dependencies (legion-data, legion-transport, legion-llm) guarded with `defined?()`
- No DB calls in this gem for global store — server-side code stays in lex-apollo
- `Apollo::Local` is the only DB-touching code in this gem (uses Data::Local SQLite)
