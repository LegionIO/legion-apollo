# legion-apollo

Apollo client library for the LegionIO framework.

**Version**: 0.3.2

Provides `query`, `ingest`, and `retrieve` with smart routing: co-located lex-apollo service, RabbitMQ transport, or graceful failure. Supports a node-local SQLite knowledge store (`Apollo::Local`) that mirrors the same API without requiring any remote infrastructure.

## Usage

```ruby
Legion::Apollo.start

# Global knowledge store (requires lex-apollo or RabbitMQ)
Legion::Apollo.ingest(content: 'Some knowledge', tags: %w[fact ruby])
results = Legion::Apollo.query(text: 'tell me about ruby', limit: 5)

# Node-local store (SQLite + FTS5, no network required)
Legion::Apollo.ingest(content: 'Local note', scope: :local)
results = Legion::Apollo.query(text: 'local note', scope: :local)

# Query both and merge (deduped by content hash, ranked by confidence)
results = Legion::Apollo.query(text: 'ruby', scope: :all)
```

## Scopes

| Scope | Route |
|-------|-------|
| `:global` (default) | Co-located lex-apollo or RabbitMQ transport |
| `:local` | `Apollo::Local` SQLite+FTS5 store (node-local) |
| `:all` | Both merged, deduped by `content_hash`, ranked by confidence |

## Local Store

`Apollo::Local` provides a node-local knowledge store backed by SQLite + FTS5. When started (e.g., via `Legion::Apollo.start`, which calls `Legion::Apollo::Local.start` automatically), it uses `Legion::Data::Local` when available and respects `Settings[:apollo][:local][:enabled]`.

Features:
- Content-hash dedup (MD5 of normalized content)
- Optional LLM embeddings (1024-dim) with cosine rerank when `Legion::LLM.can_embed?`
- TTL expiry (default 5-year retention)
- FTS5 full-text search with `ILIKE` fallback

## Configuration

```json
{
  "apollo": {
    "default_limit": 5,
    "min_confidence": 0.3,
    "max_tags": 20,
    "local": {
      "enabled": true,
      "retention_years": 5,
      "default_limit": 5,
      "min_confidence": 0.3,
      "fts_candidate_multiplier": 3
    }
  }
}
```

## License

Apache-2.0
