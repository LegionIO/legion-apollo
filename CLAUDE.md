# legion-apollo

**Parent**: `/Users/miverso2/rubymine/legion/CLAUDE.md`

## What is legion-apollo?

Core library gem (loaded on every LegionIO node) that provides the Apollo knowledge store client API. Extracts client-side Apollo code from `lex-apollo` (extension) so all nodes can read/write knowledge without running the full Apollo extension.

**Version**: 0.2.1
**GitHub**: https://github.com/LegionIO/legion-apollo

## Architecture

- `Legion::Apollo` — public API: `start`, `shutdown`, `query`, `ingest`, `retrieve`
- `Legion::Apollo::Settings` — default configuration values
- `Legion::Apollo::Messages::*` — transport envelope classes (Ingest, Query, Writeback, AccessBoost)
- `Legion::Apollo::Helpers::Confidence` — confidence constants and predicates
- `Legion::Apollo::Helpers::Similarity` — cosine similarity math and match classification
- `Legion::Apollo::Helpers::TagNormalizer` — tag normalization (lowercase, dedup, truncate)

## Routing Logic

1. Co-located reader/writer: `lex-apollo` loaded and `Legion::Data` connected -> direct call
2. Transport available: `Legion::Transport` connected -> publish via RabbitMQ
3. Neither: returns `{ success: false, error: :no_path_available }`

## Key Rules

- All Legion:: namespace prefixes required (::Process, ::JSON, ::Data)
- Optional dependencies (legion-data, legion-transport, legion-llm) guarded with `defined?()`
- No DB calls in this gem — server-side code stays in lex-apollo
