# LegionIO LLM Pipeline

## Overview

LegionIO routes AI requests through a 19-step pipeline that adds governance, RAG context, tool use, cost tracking, and knowledge capture. The pipeline is provider-agnostic — it works with Bedrock, Anthropic, OpenAI, Gemini, and local Ollama.

## Pipeline Steps

1. **Normalize** — standardize request format
2. **Profile** — derive caller profile (user, system, service)
3. **RBAC** — check access permissions
4. **Classification** — classify request sensitivity
5. **Billing** — check budget and rate limits
6. **Guardrails** — input validation and safety checks
7. **GAIA Advisory** — cognitive layer enrichment (optional system prompt)
8. **RAG Context** — retrieve relevant knowledge from Apollo (global + local)
9. **MCP Discovery** — discover available tools
10. **Enrichment Injection** — prepend GAIA/RAG context to system prompt
11. **Fleet Selection** — choose optimal model/provider
12. **Dispatch** — send request to LLM provider
13. **Parse Response** — extract text and tool calls
14. **Tool Calls** — execute MCP tools if requested
15. **Post-Response** — post-processing
16. **Audit** — publish audit trail
17. **Metering** — record token usage and cost
18. **Timeline** — record timing data
19. **Knowledge Capture** — write significant responses back to Apollo

## Supported Providers

| Provider | Models | Auth |
|----------|--------|------|
| AWS Bedrock | Claude, Llama, Mistral | Bearer token (from Vault) |
| Anthropic | Claude family | API key |
| OpenAI | GPT-4, GPT-3.5 | API key |
| Google Gemini | Gemini Pro, Flash | API key |
| Ollama | Any local model | None (localhost) |

## Cost Tracking

Every LLM call is metered. Token counts (input/output) and estimated costs are tracked per-request, per-session, per-user, and per-team. The status bar in the terminal UI shows real-time token count and cost. Budget limits can be set per-user or per-team.

## Model Routing

The fleet selection step chooses the optimal model based on request classification, cost constraints, and provider availability. Model escalation automatically retries with a more capable model if the initial response fails quality checks.

## RAG Integration

Step 8 retrieves relevant context from Apollo using scope routing:
- `:local` — node-local SQLite+FTS5 store only
- `:global` — shared PostgreSQL+pgvector store
- `:all` — both merged, deduplicated by content hash, ranked by confidence

Retrieved context is injected into the system prompt by the Enrichment Injector (step 10).
