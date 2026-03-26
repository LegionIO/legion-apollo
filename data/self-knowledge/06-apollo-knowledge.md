# Apollo Knowledge Store

## What is Apollo?

Apollo is LegionIO's shared knowledge store. It provides organizational memory that persists across sessions and is shared across all LegionIO nodes. Every AI response can reference knowledge from Apollo, and significant responses are captured back into it.

## Architecture

### Local Store (every node)
- SQLite database with FTS5 full-text search
- Content-hash deduplication (MD5)
- Optional LLM embeddings (1024-dim) with cosine rerank
- TTL-based expiry (default 5 years)
- Works offline — no network required

### Global Store (shared)
- PostgreSQL with pgvector extension
- HNSW cosine similarity index
- Agents interact via RabbitMQ (no direct DB access)
- Hosted on Azure PostgreSQL Flexible Server

## Scope Routing

All queries and ingests accept a `scope:` parameter:
- `:local` — SQLite only
- `:global` — PostgreSQL only (via transport or co-located extension)
- `:all` — both merged, deduplicated by content hash, ranked by confidence

## Knowledge Capture

The LLM pipeline's step 19 (Knowledge Capture) automatically writes significant responses back to Apollo. This creates a feedback loop where the system learns from its own interactions. Content-hash deduplication prevents echo chambers.

## Knowledge CLI

```
legion knowledge query "question"     # query and synthesize answer
legion knowledge retrieve "question"  # raw source chunks
legion knowledge ingest <path>        # ingest file or directory
legion knowledge status               # corpus stats
legion knowledge health               # full health report
legion knowledge maintain             # orphan detection and cleanup
legion knowledge quality              # quality report
legion knowledge monitor add <path>   # watch a directory for changes
legion knowledge capture commit       # capture git commit as knowledge
```

## Content Pipeline

Files ingested via `legion knowledge ingest` go through:
1. Format detection (Markdown, PDF, DOCX, plain text)
2. Chunking by heading hierarchy (H1-H6 with ancestry path)
3. Delta detection (only new/changed files via manifest)
4. Batch embedding (one LLM call per file, not per chunk)
5. Upsert to Apollo (local and/or global based on scope)
