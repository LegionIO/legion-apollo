# Changelog

## [0.2.1] - 2026-03-25

### Added
- Initial gem scaffold: `Legion::Apollo` public API (`start`, `shutdown`, `query`, `ingest`, `retrieve`)
- `Legion::Apollo::Settings` with default configuration values
- Transport message envelope classes: `Ingest`, `Query`, `Writeback`, `AccessBoost`
- Helper modules: `Confidence` constants, `Similarity` math, `TagNormalizer`
- Smart routing: co-located lex-apollo service, RabbitMQ transport, graceful failure
