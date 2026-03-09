---
name: agentcore-transform
description: >
  Transform and deploy Claude Agent SDK applications to AWS Bedrock AgentCore.
  Use when the user asks to "deploy to AgentCore", "migrate to AgentCore",
  "add AgentCore Memory", "add persistent memory to my agent", "deploy my
  agent to AWS", or mentions "AgentCore Runtime", "AgentCore Memory",
  "AgentCore Identity", or "AgentCore transform". Also use when the user has
  a Claude Agent SDK app (imports from @anthropic-ai/claude-agent-sdk or
  claude_agent_sdk) and wants production deployment on AWS. Do NOT use for
  general AWS deployment questions unrelated to AgentCore.
tools: Read, Write, Edit, Bash, Glob, Grep, Agent, AskUserQuestion
---

# AgentCore Transform Skill

Transform any Claude Agent SDK application (TypeScript or Python) to deploy
on AWS Bedrock AgentCore with Memory (STM + LTM), Runtime, Identity (Cognito),
and full AWS infrastructure (S3, CloudFront, CloudFormation).

## Workflow Overview

This skill runs in 5 interactive phases. Pause after Phase 1 (Analysis) and
Phase 2 (Plan) to get user approval before proceeding.

```
Phase 1: ANALYZE  ->  Phase 2: PLAN  ->  Phase 3: TRANSFORM  ->  Phase 4: DEPLOY  ->  Phase 5: TEST
     (pause)            (pause)
```

---

## Pre-Read: Lessons Learned

**BEFORE starting any transformation**, read `references/lessons-learned.md`.
It contains critical pitfalls from real deployments that MUST be avoided:
- Agent name must use underscores (no hyphens)
- macOS `grep -P` incompatibility (use `sed` instead)
- Cognito password shell quoting
- Dockerfile OpenTelemetry crash with tsx projects — deploy.sh MUST patch the auto-generated Dockerfile
- Frontend MUST use `/invocations` mode in production (not `/api`)
- Frontend API paths in /invocations wrapper MUST include `/api` prefix (e.g., `/api/chats` not `/chats`)
- Frontend MUST include Cognito login form
- Frontend needs `client/vite-env.d.ts` with `/// <reference types="vite/client" />`
- LTM `searchLTM()` MUST be actively called (not just defined)
- JWT authorizer mode = Bearer token ONLY (no SigV4) — combining them causes 403
- Test script MUST use Python (not shell) for Cognito auth and API calls
- CloudFormation `wait stack-update-complete` hangs if no update needed — must check first
- Long-running steps MUST print timing hints (memory: 1-2 min, deploy: 3-5 min, CloudFront: 5-15 min)
- `@opentelemetry/auto-instrumentations-node` must be in package.json dependencies

---

## Phase 1: ANALYZE

**Goal:** Scan the user's project and produce a structured analysis report.

Read `references/analysis-guide.md` for the full analysis procedure.

### Steps

1. **Detect language and framework:**
   - Search for `package.json` (TypeScript/Node.js) or `pyproject.toml` / `requirements.txt` / `setup.py` (Python).
   - Check for Claude Agent SDK imports:
     - TS: `@anthropic-ai/claude-agent-sdk` in package.json or `import { query }` from it.
     - Python: `claude_agent_sdk` in requirements or `from claude_agent_sdk import` in source.
   - Identify the web framework: Express, Fastify, raw http (TS) or FastAPI, Flask, Django (Python).

2. **Map conversation storage:**
   - Search for in-memory stores (Map, dict, list-based message storage).
   - Search for database integrations (SQLite, PostgreSQL, DynamoDB, Redis).
   - Identify the store interface: what methods exist (addMessage, getMessages, createChat, etc.).
   - Note whether storage is sync or async.

3. **Identify server architecture:**
   - Find the main server entry point.
   - List all REST endpoints (routes).
   - Identify WebSocket setup (ws, socket.io, websockets, etc.).
   - Check for SSE (Server-Sent Events) as an alternative to WebSocket.
   - Note the server port and any existing health check endpoints.

4. **Detect session/agent management:**
   - Find how agent sessions are created and managed.
   - Identify the `query()` call and its options (model, tools, systemPrompt).
   - **Record the exact model value** (e.g., `"opus"`, `"sonnet"`, a Bedrock model ID, or an env var reference).
   - Check if conversation history is injected into the agent.

5. **Check existing auth:**
   - Look for any authentication middleware or decorators.
   - Check for JWT, API key, or session-based auth.
   - Note if there is a login/signup flow in the frontend.

6. **Identify frontend (if present):**
   - Detect framework: React, Vue, Svelte, vanilla HTML, or none.
   - Find the build tool: Vite, webpack, Create React App, etc.
   - Identify how the frontend connects to the backend (fetch, WebSocket URL config).
   - Check for environment variable patterns (VITE_*, REACT_APP_*, etc.).

### Output

Present the analysis to the user in this format:

```
## Analysis Report

| Aspect | Finding |
|---|---|
| Language | TypeScript / Python |
| SDK | @anthropic-ai/claude-agent-sdk v0.1.x / claude_agent_sdk v0.x |
| Web Framework | Express / FastAPI / ... |
| Server Entry | server/server.ts / app/main.py |
| REST Endpoints | GET /api/chats, POST /api/chats, ... |
| WebSocket | ws on /ws / websockets on /ws / SSE |
| Conversation Store | In-memory Map / SQLite / ... |
| Store Interface | createChat(), addMessage(), getMessages(), ... |
| Agent Session | query() with model=opus, tools=[Bash,Read,...] |
| Model Config | model="opus" (hardcoded) / env var / Bedrock ID |
| Auth | None / JWT / API Key |
| Frontend | React + Vite / Vue + webpack / None |
| Frontend Build | npm run build → dist/ |

### AgentCore Features to Integrate
- [x] AgentCore Runtime (container deployment)
- [x] AgentCore Memory STM (replace conversation store)
- [x] AgentCore Memory LTM (cross-session semantic context)
- [x] AgentCore Identity (Cognito auth)
- [x] S3 + CloudFront frontend deployment
- [ ] AgentCore Gateway (future)
- [ ] AgentCore Policy (future)
```

**Ask the user:** "Does this analysis look correct? Should I proceed with generating the transformation plan?"

---

## Phase 2: PLAN

**Goal:** Generate a concrete transformation plan with specific files to create and modify.

### Steps

1. Based on the analysis, determine which files need to be:
   - **Created** (new AgentCore integration files)
   - **Modified** (existing files that need changes)
   - **Unchanged** (files that work as-is)

2. For each AgentCore feature, list the specific changes:

   **Memory Integration:**
   - New: `server/memory-client.{ts,py}` — AgentCore Memory SDK wrapper
   - New: `server/memory-store.{ts,py}` — Async store backed by Memory API
   - New: `server/store.{ts,py}` — Feature-flag router (Memory vs. local fallback)
   - Modify: session/agent module — inject STM history + LTM context into agent

   **Runtime Integration:**
   - New: `server/runtime-server.{ts,py}` — AgentCore Runtime server (port 8080)
   - Modify: REST routes → /invocations proxy pattern
   - Add: health check, graceful shutdown

   **Identity Integration:**
   - New: `server/auth.{ts,py}` — Cognito JWT verification
   - Modify: server — add actorId extraction from JWT
   - Modify: WebSocket — add token-based auth on upgrade

   **Frontend Deployment:**
   - New: `server/ws-proxy.{ts,py}` — Local dev proxy
   - New: `infra/template.yaml` — CloudFormation (S3 + CloudFront)
   - New: `infra/cloudfront-function.js` — Token-to-header injection
   - Modify: frontend WebSocket hook — add token parameter
   - Add: login UI component (if none exists)

   **Deployment:**
   - New: `deploy.sh` — One-click deployment script
   - Modify: `package.json` / `pyproject.toml` — add dependencies + scripts
   - New/Modify: `README.md` — deployment instructions

   **Tests:**
   - New: `tests/agentcore-test.sh` — Post-deployment verification tests

3. Present the plan to the user with estimated files and changes.

**Ask the user:** "Here is the transformation plan. Would you like to proceed? You can also ask me to skip specific features (e.g., 'skip frontend deployment')."

---

## Phase 3: TRANSFORM

**Goal:** Generate and modify all files according to the plan.

Execute each sub-phase in order. Read the corresponding reference doc
before generating each component.

### 3.1 Memory Integration

Read `references/memory-integration.md` for patterns.
Use `templates/memory-client.{ts,py}.md` and `templates/memory-store.{ts,py}.md`
as starting points, adapting to the user's actual store interface.

Key principles:
- The memory-client wraps the AWS SDK (BedrockAgentCoreClient for TS, boto3 for Python).
- STM stores conversational events per session (actorId + sessionId).
- LTM uses `RetrieveMemoryRecords` for semantic search across sessions.
- A chat registry session tracks chat metadata via blob events.
- The store-router uses an environment variable (`AGENTCORE_MEMORY_ID`) as feature flag.
- All Memory-backed methods must be async.
- Preserve the original store's method signatures where possible (just add actorId parameter).
- **CRITICAL — LTM must be actively injected:** Creating `searchLTM()` is NOT enough.
  The session's `sendMessage()` MUST call `searchLTM(actorId, userMessage)` before each
  agent turn and prepend the results to the user's message. Without this call, LTM is
  dead code. Also update the system prompt to instruct the agent to use LTM context
  naturally. See `references/lessons-learned.md` section 5 for the implementation pattern.
- **CRITICAL — Blob storage format:** Always store blob payloads as `JSON.stringify(data)`
  (a JSON string), NOT as `JSON.parse(JSON.stringify(data))` (a plain object). The Memory API
  serializes plain objects using Java Map.toString() format (`{key=value, ...}`) which is NOT
  valid JSON and cannot be parsed back with `JSON.parse()`.
- **CRITICAL — Blob read format:** The Memory API returns blob payloads as strings in Java
  Map.toString() format. The memory-client MUST include a parser for this format as a fallback
  alongside JSON.parse(). See `templates/memory-client.ts.md` for the `parseJavaMapString()`
  helper function.

### 3.2 Runtime Integration

Read `references/runtime-integration.md` for patterns.
Use `templates/runtime-server.{ts,py}.md` as starting point.

Key principles:
- Port MUST be 8080 (AgentCore Runtime requirement).
- `/invocations` POST endpoint acts as a REST router, wrapping existing route logic.
- WebSocket on `/ws` with `noServer` mode for manual upgrade handling.
- JWT decoding (not verification — AgentCore validates upstream).
- Session management: one agent session per chatId.
- Graceful shutdown on SIGTERM.

### 3.3 Identity Integration

Read `references/identity-integration.md` for patterns.
Use `templates/auth.{ts,py}.md` as starting point.

Key principles:
- Cognito JWT verifier for container-level auth (optional since AgentCore validates).
- `getActorIdFromToken()` extracts `sub` or `cognito:username` from JWT payload.
- WebSocket auth: token from query parameter or Authorization header.
- Dev mode: skip auth if Cognito env vars not set.

### 3.4 Frontend Adaptation

Read `references/frontend-deployment.md` for patterns.
Read `references/lessons-learned.md` section 4 for critical routing/auth fixes.
Use `templates/ws-proxy.{ts,py}.md` for local dev proxy.

Key principles:
- ws-proxy bridges browser WS → AgentCore WS (adds Authorization header).
- ws-proxy bridges browser REST → AgentCore /invocations (adds session header).
- Frontend must send JWT token in WS query param (`?token=...`).
- Environment variables: empty = same-origin (production), URL = proxy (dev).
- CloudFront Function: reads `token` from query string, injects as Authorization header.
- **CRITICAL — Production routing:** Frontend MUST detect production mode (via
  `HAS_COGNITO = !!VITE_COGNITO_POOL_ID`) and use `/invocations` path, NOT `/api`.
  CloudFront only routes `/invocations*` and `/ws*` to AgentCore; `/api/*` falls through
  to S3 and returns `index.html` (causing JSON parse errors).
- **CRITICAL — Cognito login form:** Frontend MUST include a login form that
  authenticates with Cognito via the IDP API (no extra SDK needed — use `fetch` with
  `AWSCognitoIdentityProviderService.InitiateAuth`). Include `Authorization: Bearer <token>`
  header on all REST calls. Don't connect WebSocket until authenticated (pass `null` URL).
- **CRITICAL — VITE_AWS_REGION:** Include `VITE_AWS_REGION` in `.env.production` and
  `.env` — the frontend needs it to construct the Cognito IDP endpoint URL.
- **CRITICAL — API paths MUST include `/api` prefix:** When the frontend wraps requests
  in the `/invocations` JSON body, the `path` field must be the FULL path including `/api`
  prefix (e.g., `/api/chats`, NOT `/chats`). The runtime server matches against the
  complete path. Getting this wrong means the route won't match and returns 404.
- **CRITICAL — Vite TypeScript types:** Create `client/vite-env.d.ts` containing
  `/// <reference types="vite/client" />` — without this, `import.meta.env` causes
  TypeScript errors (`Property 'env' does not exist on type 'ImportMeta'`).

### 3.5 Modify Existing Files

Apply targeted edits to existing files:
- Session/agent module: make `sendMessage()` async. Before each agent turn, call
  `searchLTM(actorId, content)` and prepend results to the user message. This is the
  Bounded Context Pattern — see `references/lessons-learned.md` section 5.
- AI client: update system prompt to instruct the agent to use LTM context naturally
  when it appears as `[Relevant context from previous conversations:]` in messages.
- **AI client model config:** Make the model configurable via environment variable.
  The original app may hardcode a model name (e.g., `model: "opus"`). Change it to
  read from `process.env.ANTHROPIC_MODEL` (TS) or `os.environ.get("ANTHROPIC_MODEL")` (Python)
  with the original value as fallback. Example: `model: process.env.ANTHROPIC_MODEL || "sonnet"`.
  This is REQUIRED because AgentCore containers use Bedrock (not the Anthropic API) and
  need a Bedrock inference profile ID as the model.
- package.json / pyproject.toml: add dependencies.
- Add npm scripts: `dev:runtime`, `dev:proxy`, `dev:deployed`, `start:runtime`.

### 3.6 Package Dependencies

**TypeScript additions:**
```json
{
  "@aws-sdk/client-bedrock-agentcore": "latest",
  "@opentelemetry/auto-instrumentations-node": "^0.56.1",
  "aws-jwt-verify": "^5.1.1",
  "dotenv": "^16.4.5",
  "uuid": "^10.0.0"
}
```

**Python additions:**
```
boto3
pyjwt[crypto]
python-dotenv
uuid
```

---

## Phase 4: DEPLOY

**Goal:** Generate a complete, working deployment script and infrastructure.

Read `references/deploy-script.md` for the full deploy.sh pattern.
Read `references/frontend-deployment.md` for CloudFormation template.

### 4.1 deploy.sh

Generate a complete `deploy.sh` that handles:
1. Prerequisites check (AWS CLI, Python 3.10+, npm/pip, agentcore CLI).
2. AWS credentials validation.
3. Install dependencies (npm install / pip install).
4. Install AgentCore Starter Toolkit (`pip install bedrock-agentcore-starter-toolkit`).
5. `agentcore configure` — set up runtime config.
5b. **Patch auto-generated Dockerfile** — for tsx projects, remove `npm run build`,
   `npm prune --production`, and fix CMD to use `npx tsx` (see `references/lessons-learned.md` section 3).
6. `agentcore identity setup-cognito` — create Cognito User Pools.
7. Configure JWT authorizer in `.bedrock_agentcore.yaml`.
8. `agentcore memory create` — create Memory resource with semantic strategy.
9. **Resolve Bedrock model ID** — determine correct inference profile for the target region.
10. `agentcore deploy` — build & deploy container via CodeBuild **with `--env` flags**.
11. Generate .env files with Agent ARN, Memory ID, Cognito credentials.
12. Deploy frontend to S3 + CloudFront (if frontend exists).
    **CRITICAL:** Check `update-stack` output before calling `wait` — it hangs if no update needed.
    **CRITICAL:** Print timing hints before ALL long-running waits (memory create: 1-2 min,
    container deploy: 3-5 min, CloudFront create/update: 5-15 min). Without these,
    users assume the script is stuck and kill it manually, breaking the deployment.
13. Print summary with test credentials and URLs.
14. Support `--destroy` flag for teardown.

Adapt the script based on:
- Language: npm commands (TS) vs pip commands (Python).
- Frontend: include S3/CloudFront steps only if frontend detected.
- Agent name: derive from package.json name or project directory.

**CRITICAL deploy.sh requirements (learned from production issues):**

1. **Python venv handling:** During Phase 1 analysis, check if the project has an
   existing Python virtual environment (`.venv/`, `venv/`, etc.). If found, ask the
   user to confirm its path. The deploy.sh MUST prefer the venv's Python and agentcore
   CLI. Store the venv path in a `$AGENTCORE_CMD` variable and use it for ALL agentcore
   CLI calls. If no venv exists, create one and install the toolkit there. System Python
   often lacks required packages (boto3, pyyaml).

2. **Container environment variables via `--env` flags:** The Dockerfile should NOT
   hardcode runtime configuration. Instead, deploy.sh passes env vars via
   `agentcore deploy --env "KEY=VALUE"` flags. Required env vars:
   - `CLAUDE_CODE_USE_BEDROCK=1` — routes Claude Agent SDK through Bedrock instead of Anthropic API
   - `ANTHROPIC_MODEL=<inference-profile-id>` — the Bedrock inference profile ID (see below)
   - `AGENTCORE_MEMORY_ID=<memory-id>` — enables Memory-backed storage in containers
   - `AWS_REGION=<region>` — the target AWS region

3. **Bedrock inference profile resolution:** Direct model IDs (e.g.,
   `anthropic.claude-sonnet-4-20250514-v1:0`) do NOT work for on-demand invocation.
   You MUST use an inference profile ID. The prefix depends on the AWS region:
   - `us-east-1`, `us-west-2` → `us.anthropic.claude-*`
   - `ap-northeast-1`, `ap-southeast-1`, etc. → `apac.anthropic.claude-*`
   - `eu-west-1`, `eu-central-1`, etc. → `eu.anthropic.claude-*`
   - For any region → `global.anthropic.claude-*` (works everywhere but may route cross-region)

   The deploy.sh should resolve the correct prefix based on `$AWS_REGION`.
   Alternatively, run `aws bedrock list-inference-profiles` to discover available profiles.

   **Ask the user** which model they want to use (default: sonnet) if the original app
   uses a model name like "opus" or "sonnet" rather than a specific Bedrock ID.

### 4.2 CloudFormation Template

Generate `infra/template.yaml` with:
- S3 bucket (private, OAC access).
- CloudFront distribution with origins:
  - S3 for static frontend.
  - AgentCore Runtime for `/invocations*` and `/ws*`.
- CloudFront Function for WebSocket token→header injection.
- OAC for S3 access.

### 4.3 CloudFront Function

Generate `infra/cloudfront-function.js` that:
- Reads `token` from query string on `/ws*` requests.
- Injects it as `Authorization: Bearer <token>` header.
- Passes all other requests through unchanged.

---

## Phase 5: TEST

**Goal:** Generate a post-deployment test script.

Read `references/test-generation.md` for patterns.

Generate `tests/agentcore-test.sh` — a **bash wrapper that delegates to an embedded
Python script** for all API calls. This is CRITICAL because:
- Cognito passwords contain special chars (`=`, `@`, `)`) that break shell expansion
- JWT authorizer mode requires Bearer-only auth (no SigV4) with `?qualifier=DEFAULT`
- JSON response parsing is fragile in shell

The test script should:

1. **Authenticate:** Get a JWT from Cognito via `subprocess.run(["aws", "cognito-idp", ...])` (avoids shell quoting).
2. **Create chat:** POST to `/invocations?qualifier=DEFAULT` with Bearer token + session header.
3. **List chats:** GET via /invocations wrapper.
4. **Get messages:** Verify message retrieval works.
5. **Auth failure test:** Attempt access without Bearer token, verify 401/403.
6. **Memory check:** Verify Memory resource is ACTIVE via `agentcore memory get`.
7. **Cleanup:** Delete test chat.
8. **Print results:** Summary with pass/fail for each test.

**CRITICAL auth requirements:**
- Use `Authorization: Bearer <token>` header — NO SigV4 signing
- Include `?qualifier=DEFAULT` query parameter on all /invocations calls
- Include `X-Amzn-Bedrock-AgentCore-Runtime-Session-Id: <uuid>` header
- Include `Accept: text/event-stream, application/json` header

The script should:
- Read configuration from `.env` and `.agentcore_identity_cognito_user.json`.
- Use Python's `urllib.request` for REST tests (NOT curl — avoids quoting issues).
- Support `--endpoint <url>` flag to test either local proxy or deployed endpoint.
- Print clear pass/fail output with colors.

---

## Important Guidelines

### Adaptation Rules
- Never blindly copy templates. Always adapt to the user's actual code structure.
- Preserve the user's existing variable names, coding style, and patterns.
- If the user has TypeScript strict mode, ensure generated code passes strict checks.
- If the user uses ESM (`"type": "module"`), use ESM imports. If CJS, use require().
- For Python, match the user's style (async/await vs sync, type hints vs none).

### Feature Flag Pattern
- Every AgentCore integration MUST have a local fallback for dev mode.
- The `store.ts`/`store.py` router pattern is mandatory.
- `AGENTCORE_MEMORY_ID` environment variable gates Memory features.
- Without Memory, the app should work exactly as before with in-memory storage.

### Error Handling
- All Memory API calls must have try/catch with graceful degradation.
- Log warnings but don't crash if Memory is unavailable.
- WebSocket proxy errors should close the browser connection cleanly.

### Security
- Never log full JWT tokens (only first/last few characters).
- Never commit .env files or credentials.
- Add `.env`, `.agentcore_identity_cognito_user.json`, `.bedrock_agentcore.yaml` to .gitignore.
- Generated auth code must handle missing/expired/malformed tokens gracefully.

---

## Extensibility

This skill is designed for modular extension. To add support for a new
AgentCore feature (e.g., Gateway, Policy):

1. Create `references/<feature>-integration.md` with patterns and requirements.
2. Create `templates/<feature>-config.{ts,py}.md` if code generation is needed.
3. Add a new sub-section under Phase 3 (e.g., "3.7 Gateway Integration").
4. Update Phase 1 analysis to detect if the feature is applicable.
5. Update Phase 2 plan to include the feature.
6. Update deploy.sh template to include feature setup.
7. Update test script to verify the feature.
