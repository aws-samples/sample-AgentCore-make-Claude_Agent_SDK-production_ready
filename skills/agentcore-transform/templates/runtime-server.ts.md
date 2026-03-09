# Template: runtime-server.ts

AgentCore Runtime server for TypeScript applications.

This template provides the container entry point that runs inside AgentCore Runtime.
Adapt by:
- Copying the user's existing REST routes into the /invocations router
- Matching the user's WebSocket message protocol
- Importing the user's session/agent module

```typescript
/**
 * AgentCore Runtime Server
 *
 * Runs inside AWS Bedrock AgentCore Runtime. Exposes:
 * - POST /invocations — REST API router
 * - WebSocket /ws — Streaming agent communication
 * - GET /health — Health check
 *
 * Port: 8080 (required by AgentCore Runtime)
 */

import "dotenv/config";
import express from "express";
import cors from "cors";
import { createServer } from "http";
import { WebSocketServer, WebSocket } from "ws";
// ADAPT: import your types, store, session, and auth modules
import type { WSClient, IncomingWSMessage } from "./types.js";
import { store, useMemory } from "./store.js";
import { Session } from "./session.js";
import { verifyWebSocketToken } from "./auth.js";

const PORT = process.env.PORT || 8080;

const app = express();
app.use(cors());
app.use(express.json());

// Session management
const sessions: Map<string, Session> = new Map();

/**
 * Decode JWT payload without verification.
 * AgentCore validates the token at the platform level.
 */
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

function extractBearerToken(req: any): string | null {
  const auth = req?.headers?.authorization;
  if (!auth) return null;
  const parts = auth.split(" ");
  return parts.length === 2 && parts[0] === "Bearer" ? parts[1] : parts[0] || null;
}

async function getOrCreateSession(chatId: string, actorId: string, sessionId?: string): Promise<Session> {
  let session = sessions.get(chatId);
  if (!session) {
    // ADAPT: match your Session.create() signature
    session = await Session.create(chatId, actorId, sessionId);
    sessions.set(chatId, session);
  }
  return session;
}

// Health check
app.get("/health", (req, res) => {
  res.json({ status: "healthy", timestamp: new Date().toISOString() });
});

/**
 * /invocations — REST API router
 *
 * ADAPT: copy your existing REST routes into the switch/if-else below.
 * Convert each route handler from (req, res) to (method, path, body) -> result.
 */
app.post("/invocations", async (req, res) => {
  try {
    const { input } = req.body;
    if (!input) {
      return res.status(400).json({
        output: { statusCode: 400, body: { error: "Missing 'input' in request body" } }
      });
    }

    const { method, path, body, sessionId } = input;
    const actorId = getActorIdFromToken(extractBearerToken(req));

    console.log(`[Invocation] ${method} ${path} (session: ${sessionId || "none"}, actor: ${actorId})`);

    let result: any;
    let statusCode = 200;

    try {
      // ADAPT: Replace these routes with your application's actual endpoints
      if (method === "GET" && path === "/api/chats") {
        result = useMemory
          ? await (store as any).getAllChats(actorId)
          : (store as any).getAllChats();

      } else if (method === "POST" && path === "/api/chats") {
        if (sessionId) {
          result = useMemory
            ? await (store as any).ensureChat(actorId, sessionId, body?.title)
            : (store as any).ensureChat(sessionId, body?.title);
        } else {
          result = useMemory
            ? await (store as any).createChat(actorId, body?.title)
            : (store as any).createChat(body?.title);
        }

      } else if (method === "GET" && path.match(/^\/api\/chats\/([^/]+)$/)) {
        const chatId = path.split("/")[3];
        result = useMemory
          ? await (store as any).getChat(actorId, chatId)
          : (store as any).getChat(chatId);
        if (!result) { statusCode = 404; result = { error: "Chat not found" }; }

      } else if (method === "DELETE" && path.match(/^\/api\/chats\/([^/]+)$/)) {
        const chatId = path.split("/")[3];
        const deleted = useMemory
          ? await (store as any).deleteChat(actorId, chatId)
          : (store as any).deleteChat(chatId);
        if (!deleted) {
          statusCode = 404; result = { error: "Chat not found" };
        } else {
          const session = sessions.get(chatId);
          if (session) { session.close(); sessions.delete(chatId); }
          result = { success: true };
        }

      } else if (method === "GET" && path.match(/^\/api\/chats\/([^/]+)\/messages$/)) {
        const chatId = path.split("/")[3];
        result = useMemory
          ? await (store as any).getMessages(actorId, chatId)
          : (store as any).getMessages(chatId);

      } else {
        statusCode = 404;
        result = { error: `Route not found: ${method} ${path}` };
      }
    } catch (error) {
      console.error("[Invocation] Handler error:", error);
      statusCode = 500;
      result = { error: (error as Error).message };
    }

    res.json({ output: { statusCode, body: result } });
  } catch (error) {
    console.error("[Invocation] Request error:", error);
    res.status(500).json({
      output: { statusCode: 500, body: { error: (error as Error).message } }
    });
  }
});

// HTTP server
const server = createServer(app);

// WebSocket server (noServer mode for manual upgrade with auth)
const wss = new WebSocketServer({ noServer: true });

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
    console.error("[WebSocket] Upgrade failed:", error);
    socket.write("HTTP/1.1 401 Unauthorized\r\n\r\n");
    socket.destroy();
  }
});

wss.on("connection", (ws: WSClient, request) => {
  const url = new URL(request.url || "", `http://${request.headers.host}`);
  const wsToken = url.searchParams.get("token") || extractBearerToken(request);
  const actorId = getActorIdFromToken(wsToken);
  ws.isAlive = true;

  ws.send(JSON.stringify({ type: "connected", message: "Connected to AgentCore chat server" }));

  ws.on("pong", () => { ws.isAlive = true; });

  ws.on("message", async (data) => {
    try {
      const message: IncomingWSMessage = JSON.parse(data.toString());

      switch (message.type) {
        case "subscribe": {
          const session = await getOrCreateSession(message.chatId, actorId, message.chatId);
          session.subscribe(ws);

          const messages = useMemory
            ? await (store as any).getMessages(actorId, message.chatId)
            : (store as any).getMessages(message.chatId);
          ws.send(JSON.stringify({ type: "history", messages, chatId: message.chatId }));
          break;
        }

        case "chat": {
          const sessionId = (message as any).sessionId || message.chatId;
          const session = await getOrCreateSession(message.chatId, actorId, sessionId);
          session.subscribe(ws);
          await session.sendMessage(message.content);
          break;
        }

        default:
          console.warn("[WebSocket] Unknown message type:", (message as any).type);
      }
    } catch (error) {
      console.error("[WebSocket] Error handling message:", error);
      ws.send(JSON.stringify({ type: "error", error: "Invalid message format" }));
    }
  });

  ws.on("close", () => {
    for (const session of sessions.values()) {
      session.unsubscribe(ws);
    }
  });
});

// Heartbeat
const heartbeat = setInterval(() => {
  wss.clients.forEach((ws) => {
    const client = ws as WSClient;
    if (client.isAlive === false) return client.terminate();
    client.isAlive = false;
    client.ping();
  });
}, 30000);

wss.on("close", () => clearInterval(heartbeat));

// Start
server.listen(PORT, () => {
  console.log(`\n========================================`);
  console.log(`AgentCore Runtime Server`);
  console.log(`========================================`);
  console.log(`Port: ${PORT}`);
  console.log(`Endpoints: POST /invocations, WebSocket /ws, GET /health`);
  console.log(`========================================\n`);
});

// Graceful shutdown
process.on("SIGTERM", () => {
  console.log("[Runtime] SIGTERM received, shutting down gracefully");
  server.close(() => process.exit(0));
});
```
