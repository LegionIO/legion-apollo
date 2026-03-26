# LegionIO Extension System (LEX)

## What is a LEX?

A LEX (Legion Extension) is a Ruby gem named `lex-*` that plugs into LegionIO. Each LEX defines runners (functions) and actors (execution modes). Extensions are auto-discovered at boot — install a gem and it loads automatically.

## Actor Types

| Type | Behavior |
|------|----------|
| Subscription | Consumes messages from an AMQP queue |
| Polling | Polls on a schedule |
| Interval (Every) | Runs at a fixed interval |
| Once | Runs once at startup |
| Loop | Runs continuously |
| Nothing | Passive — only invoked via API or other extensions |

## Creating an Extension

```bash
legion lex create myextension    # scaffold a new lex-myextension gem
legion generate runner myrunner   # add a runner with functions
legion generate actor myactor     # add an actor with type selection
legion generate tool mytool       # add an MCP tool
```

## Extension Categories

### Core Operational (21 extensions)
node, tasker, scheduler, synapse, LLM gateway, detect, telemetry, acp, react, webhook, health, metering, exec, conditioner, transformer, tick, audit, codegen, privatecore, lex (meta), knowledge

### Agentic/Cognitive (13 consolidated gems + supporting)
self (identity, metacognition, reflection, personality, agency), affect (emotion, mood, sentiment), imagination (creative generation, dream ideation), language (NLU, discourse), memory (episodic, semantic, working memory), social (theory of mind, social cognition), swarm-github (code review), mesh (inter-agent communication), mind-growth (autonomous expansion), autofix, dataset, eval, factory

### AI Provider Integrations (7)
azure-ai, bedrock, claude, foundry, gemini, openai, xai

### Service Integrations (10 common + 40 additional)
Common: consul, github, http, kerberos, vault, tfe, microsoft-teams, slack, webhook, acp
Additional: chef, jfrog, ssh, smtp, kafka, jira, docker, kubernetes, and more

## Role-Based Filtering

Extensions load based on role profile:
- `nil` (default): all extensions
- `:core`: 14 core operational only
- `:cognitive`: core + all agentic
- `:service`: core + service integrations
- `:dev`: core + AI + essential agentic
- `:custom`: explicit list from settings

## Extension Discovery

At boot, LegionIO calls `Bundler.load.specs` (or `Gem::Specification` fallback) to find all `lex-*` gems. Each extension's `autobuild` creates runners and actors. After all extensions load, `hook_all_actors` activates AMQP subscriptions and timers.
