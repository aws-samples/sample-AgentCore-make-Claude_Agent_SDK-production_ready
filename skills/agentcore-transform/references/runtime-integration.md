# Runtime Integration Reference

Patterns for adapting a server to run inside AWS Bedrock AgentCore Runtime.

## AgentCore Runtime Concepts

- Runs your application in an isolated MicroVM container.
- Each session gets its own container instance (or reuses one with 15-min idle timeout).
- Container must listen on **port 8080** (hardcoded requirement).
- **Agent name validation:** Names must match `^[a-zA-Z][a-zA-Z0-9_]*$` — letters,
  numbers, underscores only. No hyphens, dots, or spaces. Convert project names like
  `my-app` to `my_app`.
- Exposes two protocols:
  - **HTTP:** `POST /invocations` for REST API calls.
  - **WebSocket:** `/ws` for streaming agent communication.
- Auth is handled at the platform level (JWT authorizer) before requests reach the container.
- The `Authorization` header is forwarded to the container if listed in `requestHeaderAllowlist`.

## /invocations Router Pattern

AgentCore Runtime funnels all REST traffic through a single `POST /invocations`
endpoint. The container must implement a router that dispatches based on the
payload content.

**Request format:**
```json
{
  "input": {
    "method": "GET",
    "path": "/api/chats",
    "body": {},
    "sessionId": "optional-session-id"
  }
}
```

**Response format:**
```json
{
  "output": {
    "statusCode": 200,
    "body": { "...": "response data" }
  }
}
```

### TypeScript Implementation Pattern

```typescript
app.post("/invocations", async (req, res) => {
  const { input } = req.body;
  if (!input) {
    return res.status(400).json({
      output: { statusCode: 400, body: { error: "Missing 'input' in request body" } }
    });
  }

  const { method, path, body, sessionId } = input;
  const actorId = getActorIdFromToken(extractBearerToken(req));

  let result: any;
  let statusCode = 200;

  try {
    // Route to handlers based on method + path
    if (method === "GET" && path === "/api/chats") {
      result = useMemory
        ? await store.getAllChats(actorId)
        : store.getAllChats();
    } else if (method === "POST" && path === "/api/chats") {
      // ... create chat
    }
    // ... more routes
  } catch (error) {
    statusCode = 500;
    result = { error: error.message };
  }

  res.json({ output: { statusCode, body: result } });
});
```

### Python Implementation Pattern (FastAPI)

```python
@app.post("/invocations")
async def invocations(request: Request):
    data = await request.json()
    inp = data.get("input", {})
    method = inp.get("method", "GET")
    path = inp.get("path", "")
    body = inp.get("body", {})
    session_id = inp.get("sessionId")
    actor_id = get_actor_id_from_token(extract_bearer_token(request))

    status_code = 200
    result = {}

    try:
        if method == "GET" and path == "/api/chats":
            result = await store.get_all_chats(actor_id) if use_memory else store.get_all_chats()
        elif method == "POST" and path == "/api/chats":
            # ... create chat
            pass
        # ... more routes
    except Exception as e:
        status_code = 500
        result = {"error": str(e)}

    return {"output": {"statusCode": status_code, "body": result}}
```

### Python Implementation Pattern (Flask)

```python
@app.route("/invocations", methods=["POST"])
def invocations():
    data = request.get_json()
    inp = data.get("input", {})
    method = inp.get("method", "GET")
    path = inp.get("path", "")
    body = inp.get("body", {})
    actor_id = get_actor_id_from_token(extract_bearer_token(request))

    status_code = 200
    result = {}

    # Route to handlers...

    return jsonify({"output": {"statusCode": status_code, "body": result}})
```

## WebSocket Server Pattern

The WebSocket server handles real-time agent communication.

### TypeScript (ws library)

```typescript
const wss = new WebSocketServer({ noServer: true });

// Manual upgrade handling (for auth)
server.on("upgrade", async (request, socket, head) => {
  try {
    const url = new URL(request.url || "", `http://${request.headers.host}`);
    const token = url.searchParams.get("token");

    if (token) {
      const user = await verifyWebSocketToken(token);
      (request as any).user = user;
    }

    wss.handleUpgrade(request, socket, head, (ws) => {
      wss.emit("connection", ws, request);
    });
  } catch (error) {
    socket.write("HTTP/1.1 401 Unauthorized\r\n\r\n");
    socket.destroy();
  }
});
```

### Python (FastAPI + websockets)

```python
@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket):
    token = websocket.query_params.get("token")
    actor_id = get_actor_id_from_token(token)

    await websocket.accept()
    await websocket.send_json({"type": "connected", "message": "Connected"})

    try:
        while True:
            data = await websocket.receive_json()
            # Handle subscribe, chat messages, etc.
    except WebSocketDisconnect:
        pass
```

## WebSocket Message Protocol

**Client -> Server:**

```json
// Subscribe to a chat
{ "type": "subscribe", "chatId": "uuid-here" }

// Send a chat message
{ "type": "chat", "chatId": "uuid-here", "content": "Hello!" }
```

**Server -> Client:**

```json
// Connection established
{ "type": "connected", "message": "Connected to AgentCore chat server" }

// Chat history
{ "type": "history", "messages": [...], "chatId": "uuid" }

// User message echo
{ "type": "user_message", "content": "Hello!", "chatId": "uuid" }

// Assistant response
{ "type": "assistant_message", "content": "Hi there!", "chatId": "uuid" }

// Tool use
{ "type": "tool_use", "toolName": "Bash", "toolId": "id", "toolInput": {...}, "chatId": "uuid" }

// Query complete
{ "type": "result", "success": true, "chatId": "uuid", "cost": 0.01, "duration": 1234 }

// Error
{ "type": "error", "error": "message", "chatId": "uuid" }
```

## Session Management

Each chat gets one agent session. Sessions are cached in a Map/dict:

```typescript
const sessions: Map<string, Session> = new Map();

async function getOrCreateSession(chatId: string, actorId: string): Promise<Session> {
  let session = sessions.get(chatId);
  if (!session) {
    session = await Session.create(chatId, actorId);
    sessions.set(chatId, session);
  }
  return session;
}
```

The Session class wraps the AgentSession (SDK query) and handles:
- Subscriber management (multiple WS clients can watch one chat).
- Message broadcasting to subscribers.
- Storing messages to Memory (STM).
- Triggering LTM extraction after each turn.

## Health Check

Required endpoint:
```typescript
app.get("/health", (req, res) => {
  res.json({ status: "healthy", timestamp: new Date().toISOString() });
});
```

## Graceful Shutdown

Handle SIGTERM for clean container shutdown:
```typescript
process.on("SIGTERM", () => {
  console.log("[Runtime] SIGTERM received, shutting down gracefully");
  server.close(() => process.exit(0));
});
```

```python
import signal
import sys

def handle_sigterm(signum, frame):
    print("[Runtime] SIGTERM received")
    sys.exit(0)

signal.signal(signal.SIGTERM, handle_sigterm)
```

## JWT Decoding (Not Verification)

AgentCore validates JWTs at the platform level. The container only needs to
decode the payload to extract `actorId`:

```typescript
function decodeJwtPayload(token: string): any {
  try {
    const parts = token.split(".");
    if (parts.length !== 3) return null;
    return JSON.parse(Buffer.from(parts[1], "base64url").toString());
  } catch {
    return null;
  }
}

function getActorIdFromToken(token?: string | null): string {
  if (!token) return "anonymous";
  const payload = decodeJwtPayload(token);
  return payload?.sub || payload?.["cognito:username"] || "anonymous";
}
```

```python
import base64, json

def decode_jwt_payload(token: str) -> dict | None:
    try:
        parts = token.split(".")
        if len(parts) != 3:
            return None
        padded = parts[1] + "=" * (-len(parts[1]) % 4)
        return json.loads(base64.urlsafe_b64decode(padded))
    except Exception:
        return None

def get_actor_id_from_token(token: str | None) -> str:
    if not token:
        return "anonymous"
    payload = decode_jwt_payload(token)
    if not payload:
        return "anonymous"
    return payload.get("sub") or payload.get("cognito:username") or "anonymous"
```

## Port Configuration

**Critical:** AgentCore Runtime requires port 8080.

```typescript
const PORT = process.env.PORT || 8080;
```

```python
PORT = int(os.environ.get("PORT", 8080))
```

The original server's port (e.g., 3001) is only used for local dev mode.
