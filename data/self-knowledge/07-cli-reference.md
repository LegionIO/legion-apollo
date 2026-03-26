# LegionIO CLI Reference

## Interactive Shell

Running `legion` with no arguments launches the rich terminal UI:
- Digital rain intro animation on first run
- Onboarding wizard with Kerberos identity detection
- AI chat shell with streaming responses
- Dashboard (Ctrl+D) with service status panels
- Extension browser, config editor, command palette (Ctrl+K)
- 115+ slash commands, tab completion, session persistence

## Key Commands

### Daemon Operations (legionio)
```
legionio start                    # start daemon
legionio stop                     # stop daemon
legionio status                   # check daemon status
legionio doctor                   # 11-check environment diagnosis
legionio config scaffold          # generate starter config files
legionio config import <url>      # import config from URL
legionio bootstrap <url>          # one-command setup (config + scaffold + install packs)
legionio setup agentic            # install 47 cognitive gems
legionio setup claude-code        # configure MCP server for Claude Code
legionio setup cursor             # configure MCP server for Cursor
legionio mcp stdio                # start MCP server (stdio transport)
legionio lex list                 # list loaded extensions
legionio update                   # self-update via Homebrew or gem
```

### Interactive / Dev (legion)
```
legion                            # launch rich terminal UI
legion chat                       # AI chat REPL
legion do "natural language"      # natural language command routing
legion knowledge query "question" # query knowledge base
legion commit                     # AI-generated commit message
legion pr                         # AI-generated PR description
legion review                     # AI code review
legion plan                       # read-only exploration mode
legion memory list                # persistent memory management
legion mind-growth status         # cognitive architecture status
```

### MCP Server

LegionIO exposes 58+ MCP tools when configured as an MCP server in Claude Code, Cursor, or VS Code. Tools cover knowledge queries, extension management, task operations, system status, and more.

## Natural Language Commands

`legion do` routes free-text to the right extension capability:
```
legion do "list all running extensions"
legion do "check system health"
legion do "show vault status"
```

It tries three resolution paths: daemon API, in-process capability registry, LLM classification.
