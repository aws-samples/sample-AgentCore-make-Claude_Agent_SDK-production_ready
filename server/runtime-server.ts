/**
 * AgentCore Runtime Server
 *
 * This server is designed to run inside AWS Bedrock AgentCore Runtime.
 * It exposes:
 * - POST /invocations - HTTP-based API proxy for REST endpoints
 * - WebSocket /ws - Streaming communication for agent responses
 *
 * Port: 8080 (required by AgentCore Runtime)
 */

import "dotenv/config";
import express from "express";
import cors from "cors";
import { createServer } from "http";
import { WebSocketServer, WebSocket } from "ws";
import type { WSClient, IncomingWSMessage } from "./types.js";
import { store, useMemory } from "./store.js";
import { Session } from "./session.js";
import { verifyWebSocketToken } from "./auth.js";

const PORT = process.env.PORT || 8080;

// Express app
const app = express();
app.use(cors());
app.use(express.json());

// Session management
const sessions: Map<string, Session> = new Map();

/**
 * Decode a JWT payload without verification.
 * Safe because AgentCore's customJWTAuthorizer already validated the token.
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

/**
 * Extract actorId from a JWT token or request context.
 * Priority: JWT sub claim > JWT cognito:username > "anonymous"
 */
function getActorIdFromToken(token?: string | null): string {
  if (!token) return "anonymous";
  const payload = decodeJwtPayload(token);
  return payload?.sub || payload?.["cognito:username"] || "anonymous";
}

/**
 * Extract JWT from Authorization header (Bearer scheme).
 */
function extractBearerToken(req: any): string | null {
  const auth = req?.headers?.authorization;
  if (!auth) return null;
  const parts = auth.split(" ");
  return parts.length === 2 && parts[0] === "Bearer" ? parts[1] : parts[0] || null;
}

async function getOrCreateSession(chatId: string, actorId: string, sessionId?: string): Promise<Session> {
  let session = sessions.get(chatId);
  if (!session) {
    session = await Session.create(chatId, actorId, sessionId);
    sessions.set(chatId, session);
  }
  return session;
}

/**
 * Health check endpoint
 */
app.get("/health", (req, res) => {
  res.json({ status: "healthy", timestamp: new Date().toISOString() });
});

/**
 * AgentCore Runtime invocation endpoint
 *
 * This endpoint acts as a router for REST API calls, forwarding them to
 * the appropriate handlers. The payload format follows AgentCore conventions:
 *
 * Request:
 * {
 *   "input": {
 *     "method": "GET|POST|DELETE",
 *     "path": "/api/chats" | "/api/chats/:id" | "/api/chats/:id/messages",
 *     "body": {...},  // Optional, for POST requests
 *     "sessionId": "session-123"  // Optional
 *   }
 * }
 *
 * Response:
 * {
 *   "output": {
 *     "statusCode": 200,
 *     "body": {...}
 *   }
 * }
 */
// Auth is handled by AgentCore Runtime's OAuth authorizer (CUSTOM_JWT)
// No need to verify tokens at the container level
app.post("/invocations", async (req, res) => {
  try {
    const { input } = req.body;
    if (!input) {
      return res.status(400).json({
        output: {
          statusCode: 400,
          body: { error: "Missing 'input' in request body" },
        },
      });
    }

    const { method, path, body, sessionId } = input;
    // Extract actorId by decoding the JWT (already verified by AgentCore authorizer)
    const actorId = getActorIdFromToken(extractBearerToken(req));

    console.log(`[Invocation] ${method} ${path} (session: ${sessionId || "none"}, actor: ${actorId})`);

    // Route to appropriate handler
    let result: any;
    let statusCode = 200;

    try {
      if (method === "GET" && path === "/api/chats") {
        // Get all chats
        result = useMemory
          ? await (store as any).getAllChats(actorId)
          : (store as any).getAllChats();
      } else if (method === "POST" && path === "/api/chats") {
        // Create new chat - use sessionId as chat ID if provided for session continuity
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
        // Get single chat
        const chatId = path.split("/")[3];
        result = useMemory
          ? await (store as any).getChat(actorId, chatId)
          : (store as any).getChat(chatId);
        if (!result) {
          statusCode = 404;
          result = { error: "Chat not found" };
        }
      } else if (method === "DELETE" && path.match(/^\/api\/chats\/([^/]+)$/)) {
        // Delete chat
        const chatId = path.split("/")[3];
        const deleted = useMemory
          ? await (store as any).deleteChat(actorId, chatId)
          : (store as any).deleteChat(chatId);
        if (!deleted) {
          statusCode = 404;
          result = { error: "Chat not found" };
        } else {
          const session = sessions.get(chatId);
          if (session) {
            session.close();
            sessions.delete(chatId);
          }
          result = { success: true };
        }
      } else if (method === "GET" && path.match(/^\/api\/chats\/([^/]+)\/messages$/)) {
        // Get chat messages
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

    res.json({
      output: {
        statusCode,
        body: result,
      },
    });
  } catch (error) {
    console.error("[Invocation] Request error:", error);
    res.status(500).json({
      output: {
        statusCode: 500,
        body: { error: (error as Error).message },
      },
    });
  }
});

// Create HTTP server
const server = createServer(app);

/**
 * WebSocket server for real-time agent communication
 *
 * Follows AgentCore Runtime WebSocket protocol:
 * - Standard WebSocket protocol
 * - Token authentication via query parameter: ws://host/ws?token=<jwt>
 * - Supports long-lived streaming connections
 */
const wss = new WebSocketServer({ noServer: true });

// Handle WebSocket upgrade
server.on("upgrade", async (request, socket, head) => {
  try {
    // Extract token from query parameter
    const url = new URL(request.url || "", `http://${request.headers.host}`);
    const token = url.searchParams.get("token");

    if (token) {
      // Verify token
      const user = await verifyWebSocketToken(token);
      (request as any).user = user;
    } else {
      console.warn("[WebSocket] No token provided, allowing unauthenticated connection (dev mode)");
    }

    // Upgrade connection
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
  // Extract actorId by decoding the JWT from query param or Authorization header
  const url = new URL(request.url || "", `http://${request.headers.host}`);
  const wsToken = url.searchParams.get("token") || extractBearerToken(request);
  const actorId = getActorIdFromToken(wsToken);
  console.log(`[WebSocket] Client connected (actor: ${actorId})`);
  ws.isAlive = true;

  ws.send(JSON.stringify({ type: "connected", message: "Connected to AgentCore chat server" }));

  ws.on("pong", () => {
    ws.isAlive = true;
  });

  ws.on("message", async (data) => {
    try {
      const message: IncomingWSMessage = JSON.parse(data.toString());

      switch (message.type) {
        case "subscribe": {
          const session = await getOrCreateSession(message.chatId, actorId, message.chatId);
          session.subscribe(ws);
          console.log(`[WebSocket] Client subscribed to chat ${message.chatId}`);

          // Send existing messages
          const messages = useMemory
            ? await (store as any).getMessages(actorId, message.chatId)
            : (store as any).getMessages(message.chatId);
          ws.send(JSON.stringify({
            type: "history",
            messages,
            chatId: message.chatId,
          }));
          break;
        }

        case "chat": {
          // Use sessionId from message if provided, otherwise use chatId
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
    console.log("[WebSocket] Client disconnected");
    // Unsubscribe from all sessions
    for (const session of sessions.values()) {
      session.unsubscribe(ws);
    }
  });

  ws.on("error", (error) => {
    console.error("[WebSocket] Connection error:", error);
  });
});

// Heartbeat to detect dead connections
const heartbeat = setInterval(() => {
  wss.clients.forEach((ws) => {
    const client = ws as WSClient;
    if (client.isAlive === false) {
      return client.terminate();
    }
    client.isAlive = false;
    client.ping();
  });
}, 30000);

wss.on("close", () => {
  clearInterval(heartbeat);
});

// Start server
server.listen(PORT, () => {
  console.log(`\n========================================`);
  console.log(`AgentCore Runtime Server`);
  console.log(`========================================`);
  console.log(`Server running on port ${PORT}`);
  console.log(`Endpoints:`);
  console.log(`  - POST /invocations (REST API proxy)`);
  console.log(`  - WebSocket /ws (Agent streaming)`);
  console.log(`  - GET /health (Health check)`);
  console.log(`========================================\n`);
});

// Graceful shutdown
process.on("SIGTERM", () => {
  console.log("[Runtime] SIGTERM received, shutting down gracefully");
  server.close(() => {
    console.log("[Runtime] Server closed");
    process.exit(0);
  });
});
