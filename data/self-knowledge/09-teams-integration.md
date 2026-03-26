# Microsoft Teams Integration

## Overview

The `lex-microsoft_teams` extension connects LegionIO to Microsoft Teams via the Microsoft Graph API. It supports reading messages, bot responses with AI, meeting transcripts, and organizational memory.

## Authentication

Two auth paths run in parallel:
- **Application (client credentials)**: Bot-to-bot communication via client_id/client_secret
- **Delegated (user OAuth)**: User-context access via browser PKCE flow or device code fallback

Tokens are persisted to Vault (with local file fallback) and auto-refreshed with a 60-second pre-expiry buffer.

## Capabilities

### Message Reading
- 1:1 and group chat messages
- Channel messages across teams
- Real-time message processing via AMQP transport

### AI Bot
- Direct chat mode: users DM the bot, get AI responses via LLM pipeline
- Conversation observer mode: passive extraction from watched chats (disabled by default)
- Multi-turn sessions with context persistence
- Memory trace injection for organizational context

### Meetings and Transcripts
- Online meeting CRUD and join URL lookup
- Meeting transcript retrieval (VTT/DOCX format)
- Attendance reports

### Organizational Intelligence
- Profile ingestion: identity, contacts, conversation summaries
- Incremental sync every 15 minutes for new messages
- Memory traces stored across sender, teams, and chat domains

## RAG Integration

The bot injects organizational memory context into every response:
- Retrieves traces from lex-agentic-memory across 3 domain scopes
- Deduplicates by trace_id, ranks by strength and recency
- Appends formatted context to the system prompt (2000 token budget)
- Per-user preference profiles from lex-mesh customize response style
