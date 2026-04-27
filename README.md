# legion-apollo

Apollo is the LegionIO knowledge client. It gives extensions one API for writing, retrieving, and merging knowledge across the global Apollo service and the node-local SQLite store.

**Version**: 0.5.2

`legion-apollo` provides `query`, `ingest`, and `retrieve` with smart routing: co-located `lex-apollo`, RabbitMQ transport, node-local SQLite, or graceful failure. `Apollo::Local` mirrors the same public API for offline and low-latency retrieval without requiring remote infrastructure.

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

# Preserve verbatim source text separately from indexed retrieval content
Legion::Apollo.ingest(
  content: 'Summarized policy note for search',
  raw_content: 'Exact source text from the original record',
  tags: %w[policy source],
  scope: :local
)

# Query the local store as it was valid at a point in time
Legion::Apollo.ingest(
  content: 'Policy version active in Q2',
  tags: %w[policy],
  valid_from: '2026-04-01T00:00:00.000Z',
  valid_to: '2026-06-30T23:59:59.999Z',
  scope: :local
)
results = Legion::Apollo.query(text: 'policy', scope: :local, as_of: '2026-05-01T00:00:00.000Z')
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
- `raw_content` preservation for verbatim source text
- `valid_from` / `valid_to` temporal windows with `as_of:` query filtering
- Optional LLM embeddings (1024-dim) with cosine rerank when `Legion::LLM.can_embed?`
- TTL expiry (default 5-year retention)
- FTS5 full-text search with `ILIKE` fallback
- Null-byte removal and invalid UTF-8 scrubbing before persistence or backend routing

## Configuration

```json
{
  "apollo": {
    "enabled": true,
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
