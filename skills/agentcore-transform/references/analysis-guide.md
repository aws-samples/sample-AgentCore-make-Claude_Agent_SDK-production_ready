# Analysis Guide

How to scan and classify a Claude Agent SDK application for AgentCore transformation.

## Detection Patterns

### Language Detection

**TypeScript/Node.js indicators:**
- `package.json` exists at project root
- `tsconfig.json` exists
- `.ts` or `.tsx` source files
- `node_modules/` directory

**Python indicators:**
- `pyproject.toml`, `requirements.txt`, or `setup.py` at project root
- `.py` source files
- `venv/`, `.venv/`, or `__pycache__/` directories

### Claude Agent SDK Detection

**TypeScript:**
```
# In package.json dependencies
"@anthropic-ai/claude-agent-sdk"

# In source code
import { query } from "@anthropic-ai/claude-agent-sdk"
import { query } from '@anthropic-ai/claude-agent-sdk'
```

**Python:**
```
# In requirements.txt or pyproject.toml
claude_agent_sdk
claude-agent-sdk

# In source code
from claude_agent_sdk import query
import claude_agent_sdk
```

### Web Framework Detection

**TypeScript:**
| Pattern | Framework |
|---|---|
| `import express` or `require("express")` | Express |
| `import Fastify` or `require("fastify")` | Fastify |
| `import { createServer } from "http"` (no framework) | Raw HTTP |
| `import Koa` | Koa |

**Python:**
| Pattern | Framework |
|---|---|
| `from fastapi import` | FastAPI |
| `from flask import` | Flask |
| `from django` | Django |
| `import aiohttp` | aiohttp |
| `from http.server import` | stdlib |

### Conversation Store Detection

Search for these patterns to identify how messages are stored:

**In-memory (most common in demos):**
- `new Map()` storing messages (TS)
- `messages: Map<string, Message[]>` (TS)
- `messages = {}` or `messages = []` (Python)
- Class with `addMessage`, `getMessages` methods

**Database-backed:**
- SQLite: `better-sqlite3`, `sqlite3`, `import sqlite3`
- PostgreSQL: `pg`, `psycopg2`, `asyncpg`
- DynamoDB: `@aws-sdk/client-dynamodb`, `boto3.resource('dynamodb')`
- Redis: `ioredis`, `redis`, `aioredis`

**File-based:**
- `fs.writeFileSync` / `fs.readFileSync` with JSON
- `open()` with json.dump/json.load in Python

### Store Interface Mapping

Identify the methods on the existing store and map them:

| Common Method | Purpose | Memory Equivalent |
|---|---|---|
| `createChat(title?)` | Create new chat session | Registry event (blob) |
| `getChat(id)` | Get chat metadata | Registry event lookup |
| `getAllChats()` | List all chats | Registry session scan |
| `deleteChat(id)` | Remove chat | Registry delete event |
| `addMessage(chatId, msg)` | Store message | STM CreateEvent (conversational) |
| `getMessages(chatId)` | Get chat history | STM ListEvents |
| `updateChatTitle(id, title)` | Rename chat | Registry update event |

Note: The Memory-backed store adds an `actorId` parameter to every method
for multi-user isolation. The feature-flag router handles the signature difference.

### WebSocket Detection

**TypeScript:**
| Pattern | Library |
|---|---|
| `import { WebSocketServer } from "ws"` | ws (most common) |
| `import { Server } from "socket.io"` | socket.io |
| `import { WebSocketServer } from "uWebSockets.js"` | uWebSockets |

**Python:**
| Pattern | Library |
|---|---|
| `from fastapi import WebSocket` | FastAPI built-in |
| `import websockets` | websockets |
| `from channels` | Django Channels |
| `import socketio` | python-socketio |

### Frontend Detection

**React + Vite:**
- `vite.config.ts` or `vite.config.js` with `@vitejs/plugin-react`
- `client/` or `src/` with `.tsx` files
- `import React` or `import { useState }` patterns

**React + CRA:**
- `react-scripts` in package.json
- `public/` directory with `index.html`

**Vue:**
- `@vue/` dependencies
- `.vue` files

**None / API-only:**
- No HTML files or frontend framework dependencies
- Only server-side code

### Agent Session Detection

Look for how the agent is initialized and managed:

**TypeScript pattern:**
```typescript
// The query() call and its options
const output = query({
  prompt: messageSource,
  options: {
    model: "opus",
    maxTurns: 100,
    allowedTools: ["Bash", "Read", ...],
    systemPrompt: "...",
    ...
  }
});
```

**Python pattern:**
```python
# The query() call
output = query(
    prompt=message_source,
    options={
        "model": "opus",
        "max_turns": 100,
        "allowed_tools": ["Bash", "Read", ...],
        "system_prompt": "...",
    }
)
```

Key things to extract:
- Model name/ID
- Allowed tools list
- System prompt content
- Whether conversation history is injected into the system prompt
- How the message queue/source works (async iterator pattern)

## Analysis Checklist

Run through this checklist and record findings:

- [ ] Language: TS or Python
- [ ] SDK version and import style
- [ ] Package manager: npm/yarn/pnpm (TS) or pip/poetry/uv (Python)
- [ ] Module system: ESM or CJS (TS), async or sync (Python)
- [ ] Web framework name and version
- [ ] Server entry point file path
- [ ] Server port (default and configurable)
- [ ] All REST endpoint paths and methods
- [ ] WebSocket library and endpoint path
- [ ] Store class/module file path
- [ ] Store type: in-memory / database / file
- [ ] Store method signatures (sync vs async, parameters)
- [ ] Agent session class/function file path
- [ ] Agent model, tools, system prompt
- [ ] History injection: yes/no, how many messages
- [ ] Auth mechanism: none / JWT / API key / session
- [ ] Frontend: framework, build tool, output directory
- [ ] Frontend env var pattern (VITE_*, REACT_APP_*, etc.)
- [ ] Existing Dockerfile: yes/no
- [ ] Existing deployment scripts: yes/no
