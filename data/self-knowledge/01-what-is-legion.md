# What is LegionIO?

LegionIO is an extensible async job engine and cognitive platform for Ruby. It schedules tasks, creates relationships between services, and runs them concurrently. It was created by Matthew Iverson (@Esity) and is licensed under Apache-2.0.

LegionIO is not a chatbot. It is a framework that can power chatbots, AI assistants, background workers, service integrations, and autonomous agents. The chat interface is one of many ways to interact with it.

## Core Purpose

LegionIO connects isolated systems — cloud accounts, on-premise services, SaaS tools — into a unified async task engine. It uses RabbitMQ for message passing, supports SQLite/PostgreSQL/MySQL for persistence, and Redis/Memcached for caching.

## What LegionIO Does

- Schedules and executes async tasks across distributed services
- Chains tasks into workflows (Task A -> conditioner -> Task B -> transformer -> Task C)
- Auto-discovers and loads extension gems (LEX plugins) at boot
- Provides a unified REST API on port 4567 for all operations
- Integrates with HashiCorp Vault for secrets and authentication
- Supports Kerberos auto-authentication to Vault using existing AD credentials
- Runs an 19-step LLM pipeline with RAG, guardrails, cost tracking, and model routing
- Maintains a shared knowledge store (Apollo) for organizational knowledge
- Provides a rich terminal UI with AI chat, dashboard, and extension browser
- Tracks token usage and costs per-user and per-team
- Supports HIPAA PHI compliance with redaction, crypto-erasure, and audit trails
- Runs as a macOS/Linux background service via Homebrew or systemd

## What LegionIO Does Not Do

- It does not provide direct cloud infrastructure (no VMs, no networking)
- It does not replace Terraform, Ansible, or Chef for infrastructure management
- It does not host web applications or serve static content
- It does not provide its own LLM — it routes to providers like Bedrock, Anthropic, OpenAI, Gemini, or Ollama
- It does not require RabbitMQ in lite mode (uses an in-process message adapter)
- It does not store credentials on disk — all secrets are in Vault or environment variables

## Installation

Install via Homebrew on macOS:
```
brew tap legionio/tap
brew install legionio
```

Or via RubyGems:
```
gem install legionio
```

## Key Binaries

- `legionio` — daemon and operational CLI (start, stop, config, lex, task, mcp, etc.)
- `legion` — interactive terminal shell with AI chat, onboarding wizard, and dashboard
