# LegionIO Architecture

## Boot Sequence

LegionIO starts subsystems in a fixed order. Each phase is individually toggleable.

1. Logging (legion-logging)
2. Settings (legion-settings — loads from /etc/legionio, ~/.legionio, ./settings)
3. Crypt (legion-crypt — Vault connection, Kerberos auto-auth)
4. Transport (legion-transport — RabbitMQ or InProcess lite adapter)
5. Cache (legion-cache — Redis, Memcached, or Memory adapter)
6. Data (legion-data — SQLite, PostgreSQL, or MySQL via Sequel)
7. RBAC (legion-rbac — role-based access control)
8. LLM (legion-llm — AI provider setup and routing)
9. Apollo (legion-apollo — shared and local knowledge store)
10. GAIA (legion-gaia — cognitive coordination layer, 24 phases)
11. Telemetry (OpenTelemetry tracing, optional)
12. Extensions (two-phase parallel: require+autobuild, then hook actors)
13. API (Sinatra/Puma REST API on port 4567)

Shutdown runs in reverse order. Reload shuts down then re-runs from settings onward.

## Core Gems

| Gem | Purpose |
|-----|---------|
| legion-transport | RabbitMQ AMQP messaging + InProcess lite adapter |
| legion-cache | Caching (Redis/Memcached/Memory) |
| legion-crypt | Encryption, Vault integration, JWT, Kerberos auth, mTLS |
| legion-data | Database persistence via Sequel (SQLite/PostgreSQL/MySQL) |
| legion-json | JSON serialization (multi_json wrapper) |
| legion-logging | Console + structured JSON logging with redaction |
| legion-settings | Configuration management with schema validation |
| legion-llm | LLM integration with 19-step pipeline |
| legion-mcp | MCP server with 58+ tools |
| legion-gaia | Cognitive coordination (24 phases: 16 active + 8 dream) |
| legion-apollo | Shared knowledge store client (local SQLite + global pgvector) |
| legion-rbac | Role-based access control with Vault-style policies |
| legion-tty | Rich terminal UI with AI chat and operational dashboard |

## Extension Loading

Extensions are gems named `lex-*`, auto-discovered via Bundler or Gem::Specification. Loading is two-phase and parallel: all extensions are required and `autobuild` runs concurrently on a thread pool, then `hook_all_actors` starts subscriptions sequentially. This prevents race conditions.

## Lite Mode

Setting `LEGION_MODE=lite` replaces RabbitMQ with an InProcess adapter and Redis with a Memory adapter. No external infrastructure required. Useful for development, demos, and single-machine deployments.

## REST API

Full REST API served by Sinatra/Puma on port 4567. Endpoints include tasks, extensions, runners, nodes, schedules, relationships, settings, events (SSE), transport status, hooks, workers, teams, capacity, tenants, audit, RBAC, and webhooks. JWT Bearer auth middleware with rate limiting.
