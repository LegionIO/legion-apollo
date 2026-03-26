# LegionIO Deployment

## Installation Methods

### Homebrew (macOS, recommended)
```
brew tap legionio/tap
brew install legionio
```
This installs a self-contained Ruby 3.4.8 runtime with YJIT, all core gems, and wrapper scripts. No system Ruby or rbenv required. Redis is installed as a recommended dependency.

### RubyGems
```
gem install legionio
```

### Docker
```
docker pull legionio/legion
```

## Configuration

Config files live at `~/.legionio/settings/` as JSON files (one per subsystem). Generate starter configs:
```
legionio config scaffold
```

Bootstrap from a remote URL:
```
legionio bootstrap https://example.com/config.json
```

Settings resolution order: command-line flags > environment variables > config files > defaults.

## Running

### Background Service (recommended)
```
brew services start redis
brew services start legionio
```
The daemon runs as a launchd service with automatic restart. Logs at `$(brew --prefix)/var/log/legion/legion.log`.

### Foreground
```
legionio start --log-level debug
```

### Lite Mode (no infrastructure)
```
LEGION_MODE=lite legionio start
```
Replaces RabbitMQ with in-process messaging and Redis with in-memory cache.

## Infrastructure Requirements

| Service | Required? | Purpose |
|---------|-----------|---------|
| Redis | Recommended | Caching, tracing, dream cycle |
| RabbitMQ | Optional (lite mode skips) | Async job messaging |
| PostgreSQL | Optional | Persistent storage (SQLite default) |
| HashiCorp Vault | Optional | Secrets management, PKI, auth |
| Ollama | Optional | Local LLM inference |

## Scaling

LegionIO supports horizontal scaling with:
- RabbitMQ clustering for distributed job processing
- Singleton lock (dual-backend: Redis + DB) for leader election
- GAIA heartbeat singletons to prevent duplicate cognitive cycles
- Connection pooling for database and cache
- Feature-flagged via `cluster.singleton_enabled` and `cluster.leader_election`

Same architecture runs on a laptop or a 100-node cluster.
