# Lessons Learned & Best Practices

Hard-won insights from real AgentCore deployments. Read this before starting any
transformation to avoid common pitfalls.

## 1. Agent Name Validation

AgentCore agent names must match `^[a-zA-Z][a-zA-Z0-9_]*$`:
- Letters, numbers, and underscores only
- Must start with a letter
- **No hyphens, dots, or spaces**

If the project name contains hyphens (e.g., `simple-chatapp`), convert to
underscores: `simple_chatapp`. Derive the name from `package.json` name or
directory, then sanitize.

```bash
# Sanitize project name for AgentCore
AGENT_NAME=$(echo "$RAW_NAME" | tr '-' '_' | sed 's/[^a-zA-Z0-9_]//g')
```

## 2. macOS Shell Compatibility

### grep -P not available
macOS ships with BSD grep which does NOT support `-P` (Perl regex). This is a
common failure in deploy scripts.

```bash
# BAD - fails on macOS
MEMORY_ID=$(echo "$OUTPUT" | grep -oP 'Memory ID: \K[^\s]+')

# GOOD - works everywhere
MEMORY_ID=$(echo "$OUTPUT" | sed -n 's/.*Memory ID: \([^ ]*\).*/\1/p')
```

### Cognito password special characters
Cognito auto-generated passwords contain special chars (`%`, `*`, `=`, `!`).
These get mangled by shell expansion if not quoted correctly.

```bash
# BAD - password with special chars gets mangled
--auth-parameters USERNAME="$USERNAME",PASSWORD="$PASSWORD"

# GOOD - double quotes around entire argument
--auth-parameters "USERNAME=$USERNAME,PASSWORD=$PASSWORD"
```

## 3. Dockerfile Pitfalls

### OpenTelemetry auto-instrumentation crash
The `agentcore configure` auto-generates a Dockerfile that may include:
```dockerfile
CMD ["node", "--require", "@opentelemetry/auto-instrumentations-node/register", "dist/server/runtime-server.js"]
```

This crashes if:
- The OTel package isn't installed
- The project uses `tsx` (not compiled JS), so `dist/` doesn't exist

### The auto-generated Dockerfile is wrong for tsx projects (CRITICAL)
The generated Dockerfile has THREE problems for tsx-based TypeScript projects:
1. `npm run build` — runs `vite build` which builds the **frontend** only, not the server
2. `npm prune --production` — removes devDependencies including `tsx`, breaking the server
3. `CMD ["node", "dist/server/runtime-server.js"]` — the compiled file doesn't exist

**Fix:** Do NOT manually edit the Dockerfile (it gets regenerated on each deploy).
Instead, add a **Dockerfile patch step** in `deploy.sh` after `agentcore configure`:

```bash
# Patch the auto-generated Dockerfile for tsx projects
DOCKERFILE_PATH=".bedrock_agentcore/${AGENT_NAME}/Dockerfile"
if [ -f "$DOCKERFILE_PATH" ]; then
    $PYTHON_CMD << 'DFPATCH'
import re
with open("DOCKERFILE_PATH_HERE", "r") as f:
    content = f.read()
# Remove npm run build (vite build is frontend-only)
content = re.sub(r'\n# Build TypeScript\nRUN npm run build\n', '\n', content)
# Remove npm prune --production (tsx is needed at runtime)
content = re.sub(r'\n# Prune dev dependencies.*\nRUN npm prune --production\nENV NODE_ENV=production\n', '\n', content)
# Replace CMD to use tsx directly
content = re.sub(r'CMD \[.*\]', 'CMD ["npx", "tsx", "server/runtime-server.ts"]', content)
with open("DOCKERFILE_PATH_HERE", "w") as f:
    f.write(content)
DFPATCH
fi
```

Also add `@opentelemetry/auto-instrumentations-node` to `package.json` **dependencies**
(not devDependencies) so it survives in the container even if prune happens.

### COPY context
The Dockerfile uses `COPY . .` which copies the entire project. Ensure
`.dockerignore` or the agentcore dockerignore template excludes:
- `node_modules/` (rebuilt in container)
- `.env` files
- `.git/`
- `dist/` (if building from source)

## 4. Frontend Production Routing (CRITICAL)

### The /api vs /invocations gap
CloudFront only routes `/invocations*` and `/ws*` to AgentCore. The default S3
behavior serves `index.html` for all other paths (SPA fallback via 403/404
custom error responses).

If the frontend defaults to `/api/chats` in production, it gets `index.html`
back (HTML, not JSON), causing `SyntaxError: Unexpected token '<'`.

**Fix:** The frontend must detect production mode and use `/invocations`:

```typescript
// Detect production via Cognito config presence
const HAS_COGNITO = !!import.meta.env.VITE_COGNITO_POOL_ID;
const API_BASE = import.meta.env.VITE_API_BASE
  ? `${import.meta.env.VITE_API_BASE}/invocations`
  : HAS_COGNITO ? "/invocations" : "/api";
const USE_INVOCATIONS = !!import.meta.env.VITE_API_BASE || HAS_COGNITO;
```

### API paths in /invocations wrapper MUST include /api prefix (CRITICAL)
When the frontend sends requests through the `/invocations` wrapper, the `path`
field in the JSON body must include the full `/api/...` prefix, because the
runtime server's invocation handler matches against the complete path:

```typescript
// BAD - runtime server won't match "/chats"
const chat = await apiCall("POST", "/chats", token);

// GOOD - matches the route pattern "/api/chats"
const chat = await apiCall("POST", "/api/chats", token);
```

This applies to ALL API paths: `/api/chats`, `/api/chats/:id`,
`/api/chats/:id/messages`, etc.

### Frontend Cognito auth is required
Without authentication, all API calls to AgentCore return 401/403. The frontend
MUST include a login form when deploying to production.

**Minimal Cognito auth via fetch** (no extra SDK needed):
```typescript
async function cognitoAuth(username: string, password: string): Promise<string> {
  const endpoint = `https://cognito-idp.${region}.amazonaws.com/`;
  const res = await fetch(endpoint, {
    method: "POST",
    headers: {
      "Content-Type": "application/x-amz-json-1.1",
      "X-Amz-Target": "AWSCognitoIdentityProviderService.InitiateAuth",
    },
    body: JSON.stringify({
      AuthFlow: "USER_PASSWORD_AUTH",
      ClientId: clientId,
      AuthParameters: { USERNAME: username, PASSWORD: password },
    }),
  });
  const data = await res.json();
  if (data.AuthenticationResult?.IdToken) return data.AuthenticationResult.IdToken;
  throw new Error(data.message || "Authentication failed");
}
```

The token must be:
- Included in `Authorization: Bearer <token>` header for REST calls
- Passed as `?token=<jwt>` query param for WebSocket connections
- Stored in React state (not localStorage for security)

### VITE_AWS_REGION required
The frontend needs the AWS region to construct the Cognito IDP endpoint for
authentication. Add to both `.env` and `.env.production`:
```
VITE_AWS_REGION=ap-northeast-1
```

### WebSocket URL must be null before auth
Don't connect WebSocket until the user has authenticated. Pass `null` as the
URL to `useWebSocket()` to prevent connection attempts:
```typescript
function getWsUrl(): string | null {
  if (needsAuth && !token) return null;  // Don't connect yet
  const base = `${WS_BASE}/ws`;
  return token ? `${base}?token=${token}` : base;
}
```

## 5. LTM Must Be Actively Injected (CRITICAL)

Creating the `searchLTM()` function is NOT enough. It must be **called** before
each agent turn to retrieve and inject context. Without this, LTM is dead code.

### The Bounded Context Pattern implementation

```typescript
// In session.ts sendMessage():
async sendMessage(content: string, actorId?: string) {
  // ... store user message ...

  // Search LTM for relevant context
  let enrichedContent = content;
  if (useMemory) {
    try {
      const ltmRecords = await searchLTM(actor, content, 5);
      if (ltmRecords.length > 0) {
        const ltmContext = ltmRecords.map((r) => `- ${r}`).join("\n");
        enrichedContent = `[Relevant context from previous conversations:\n${ltmContext}]\n\n${content}`;
      }
    } catch (err) {
      console.error("[Memory] LTM search failed, sending without context:", err);
    }
  }

  // Send enriched message to agent
  this.agentSession.sendMessage(enrichedContent);
}
```

### System prompt must acknowledge LTM context

```typescript
const SYSTEM_PROMPT = `You are a helpful AI assistant. ...

When a user message includes a section marked [Relevant context from previous
conversations:], use that information naturally to provide more personalized
and informed responses. Do not explicitly mention that you retrieved memories
unless the user asks about it.`;
```

### Why enrich the message, not the system prompt?
The Agent SDK's `query()` creates a long-lived session with a fixed system
prompt set at construction time. Modifying the system prompt per-turn would
require recreating the query, which is expensive. Prepending LTM context to
the user message is simpler and works with the existing architecture.

## 6. Bedrock Model ID Resolution

### Dynamic prefix based on region
Direct model IDs don't work for on-demand invocation. Must use inference
profile IDs with region-appropriate prefix:

```bash
case "$AWS_REGION" in
    us-*)  MODEL_PREFIX="us" ;;
    eu-*)  MODEL_PREFIX="eu" ;;
    ap-*)  MODEL_PREFIX="apac" ;;
    *)     MODEL_PREFIX="us" ;;
esac
BEDROCK_MODEL_ID="${MODEL_PREFIX}.anthropic.claude-sonnet-4-20250514-v1:0"
```

### Ask the user which model
If the original app uses a generic name like `"opus"` or `"sonnet"`, ask the
user which Bedrock model they want. Default to Sonnet for cost efficiency.

## 7. Deploy Script Best Practices

### Always use `--auto-update-on-conflict`
Redeployments may conflict with existing agent config. The flag auto-resolves:
```bash
$AGENTCORE_CMD deploy --auto-update-on-conflict "${DEPLOY_ENV_FLAGS[@]}"
```

### Frontend env files must be generated BEFORE build
The `npm run build` step bakes env vars into the JS bundle. Generate
`client/.env.production` before running `npm run build`.

### S3 cache headers matter
- `index.html`: `no-cache, no-store, must-revalidate` (always fetch fresh)
- Hashed assets: `public, max-age=31536000, immutable` (cache forever)
- Always invalidate CloudFront after deploy: `--paths "/*"`

### CloudFormation update-stack hang (CRITICAL)
`aws cloudformation wait stack-update-complete` hangs **indefinitely** if
no update was actually needed (e.g., template unchanged). The `update-stack`
command returns "No updates are to be performed" but `|| true` swallows the
error, then `wait` blocks forever since there's no update in progress.

**Fix:** Check if the update actually started before waiting:
```bash
UPDATE_OUTPUT=$(aws cloudformation update-stack ... 2>&1) || true
if echo "$UPDATE_OUTPUT" | grep -q "StackId"; then
    aws cloudformation wait stack-update-complete ...
else
    echo "  (Stack already up to date)"
fi
```

### `agentcore memory delete --wait` hang (CRITICAL)
`agentcore memory delete --wait` hangs **indefinitely** if the memory resource
is already deleted, in a DELETING state, or doesn't exist. The `--wait` flag
polls forever with no timeout.

**Fix:** Don't use `--wait`. Check if the resource exists first, then delete async:
```bash
if $AGENTCORE_CMD memory get "$MEMORY_ID" --region "$AWS_REGION" 2>&1 | grep -q "ACTIVE\|CREATING\|DELETING"; then
    $AGENTCORE_CMD memory delete "$MEMORY_ID" --region "$AWS_REGION" 2>/dev/null || true
    echo "Memory delete initiated (async)"
else
    echo "(Memory already deleted or not found)"
fi
```

### Summary should include login instructions
Users need to know HOW to use the deployed app. The summary should print:
- CloudFront URL
- Login credentials (username + password)
- Mention that the app has a built-in login form

## 8. OAuth-Only Auth: JWT Authorizer Mode (CRITICAL)

### No SigV4 when JWT authorizer is configured
When the agent has a `customJWTAuthorizer` configured, the AgentCore API
accepts **Bearer token only** — NO SigV4 signing. Combining SigV4 + Bearer
causes `403 Authorization method mismatch`.

The correct request format (matching the agentcore CLI's `HttpBedrockAgentCoreClient`):
```
POST /runtimes/{encoded_arn}/invocations?qualifier=DEFAULT
Authorization: Bearer <jwt_token>
Content-Type: application/json
Accept: text/event-stream, application/json
X-Amzn-Bedrock-AgentCore-Runtime-Session-Id: <session_uuid>
```

Key details:
- `?qualifier=DEFAULT` query parameter is **required**
- `X-Amzn-Bedrock-AgentCore-Runtime-Session-Id` header is required
- The `Authorization` header contains ONLY the Bearer token
- NO SigV4 signing on the request

This is the correct pattern for OAuth-only deployments where end users
authenticate with Cognito (or any OIDC provider) and do NOT have AWS IAM credentials.

### Test scripts MUST use Python for all API calls
Shell-based `curl` + `aws cognito-idp initiate-auth` fails because:
1. Cognito passwords contain special chars (`=`, `@`, `!`) that break shell expansion
2. `curl` can't easily send Bearer-only requests to the AgentCore API
3. JSON response parsing with shell heredocs is fragile

**Fix:** Write the entire test as an embedded Python script that:
- Uses `subprocess` to call `aws cognito-idp initiate-auth` (avoids shell quoting)
- Uses `urllib.request` for HTTP calls with Bearer token
- Uses `json` for reliable response parsing

See the updated `templates/test-suite.sh.md` for the complete pattern.

## 9. Testing Gotchas (Legacy Shell-Based)

### Cognito auth in test scripts
The `aws cognito-idp initiate-auth` command is sensitive to password quoting.
Always use double quotes around the entire `--auth-parameters` value. But even
this breaks with passwords like `1lr1yHkP=WIRl2@)`. **Use Python subprocess
instead** (see lesson 8 above).

### Test JSON parsing with heredoc safety
Responses may contain special characters. Use Python for JSON parsing instead
of `jq` (which may not be installed). Use triple-quoted strings to handle
embedded quotes:
```bash
CHAT_ID=$($PYTHON_CMD -c "
import sys, json
try:
    d = json.loads('''$RESPONSE''')
    print(d.get('output', {}).get('body', {}).get('id', ''))
except: print('')
" 2>/dev/null)
```

## 10. Progress Messages for Long-Running Steps (CRITICAL UX)

Several deploy steps take minutes to complete. Without progress messages, users
assume the script is stuck and kill it manually — breaking the deployment.

**Always print timing hints before long-running waits:**

| Step | Typical Duration | Message |
|---|---|---|
| Memory creation (`--wait`) | 1-2 min | `"Creating memory resource (this may take 1-2 minutes)..."` |
| Container deploy (`agentcore deploy`) | 3-5 min | `"Building and deploying container (this may take 3-5 minutes)..."` |
| CloudFront create (new stack) | 5-15 min | `"Creating CloudFront distribution — this typically takes 5-15 minutes. Please be patient..."` |
| CloudFront update (existing stack) | 5-15 min | `"Waiting for stack update (CloudFront updates can take 5-15 minutes)..."` |

```bash
# Example pattern
echo -e "${YELLOW}  Creating CloudFront distribution — this typically takes 5-15 minutes. Please be patient...${NC}"
aws cloudformation wait stack-create-complete --stack-name "$STACK_NAME" --region "$AWS_REGION"
```

## 11. Checklist Before Deployment

Before running `deploy.sh`, verify:

- [ ] Agent name uses underscores (no hyphens)
- [ ] `deploy.sh` patches the auto-generated Dockerfile for tsx projects (remove build/prune, use `npx tsx`)
- [ ] `@opentelemetry/auto-instrumentations-node` added to `package.json` dependencies
- [ ] Frontend detects production mode via `HAS_COGNITO` pattern
- [ ] Frontend API paths include `/api` prefix (e.g., `/api/chats`, not `/chats`)
- [ ] Frontend includes Cognito login form
- [ ] Frontend env includes `VITE_AWS_REGION`
- [ ] `searchLTM()` is actually called in session message flow
- [ ] System prompt acknowledges LTM context format
- [ ] Model prefix is dynamically resolved from region
- [ ] `deploy.sh` uses `sed` not `grep -P` for portability
- [ ] `deploy.sh` CloudFormation update-stack checks output before `wait` (no hang)
- [ ] `deploy.sh` prints timing hints before ALL long-running waits (memory, deploy, CloudFront)
- [ ] `deploy.sh --destroy` does NOT use `memory delete --wait` (hangs indefinitely)
- [ ] Test script uses Python for Cognito auth (not shell `aws` with password)
- [ ] Test script uses Bearer-only auth (no SigV4) with `?qualifier=DEFAULT`
- [ ] `.env.production` is generated before `npm run build`
- [ ] `client/vite-env.d.ts` exists with `/// <reference types="vite/client" />`
