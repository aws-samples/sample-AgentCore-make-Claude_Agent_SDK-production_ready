/**
 * WebSocket & HTTP Proxy Server
 *
 * Bridges browser connections to AgentCore Runtime endpoints.
 *
 * HTTP Proxy (REST):
 * - Browser sends REST calls to localhost proxy (avoids CORS issues with custom headers)
 * - Proxy forwards to AgentCore /invocations with Authorization and Session-Id headers
 *
 * WebSocket Proxy:
 * - Browser connects with token in query parameter (browser limitation: can't set headers)
 * - Proxy connects to AgentCore with Authorization header (required by AgentCore OAuth)
 * - Messages are forwarded bidirectionally
 */

import "dotenv/config";
import { createServer } from "http";
import { WebSocketServer, WebSocket } from "ws";
import type { IncomingMessage } from "http";

const PROXY_PORT = process.env.PROXY_PORT || 3001;
const AGENTCORE_REGION = process.env.AWS_REGION || "us-east-1";
const AGENT_ARN =
  process.env.AGENT_ARN ||
  "arn:aws:bedrock-agentcore:us-east-1:585306731051:runtime/claude_simple_chatapp-F35U1eDEZ3";

// Construct AgentCore URLs
const encodedArn = encodeURIComponent(AGENT_ARN);
const AGENTCORE_WS_URL = `wss://bedrock-agentcore.${AGENTCORE_REGION}.amazonaws.com/runtimes/${encodedArn}/ws?qualifier=DEFAULT`;
const AGENTCORE_REST_BASE = `https://bedrock-agentcore.${AGENTCORE_REGION}.amazonaws.com/runtimes/${encodedArn}`;

console.log(`[Proxy] AgentCore WebSocket URL: ${AGENTCORE_WS_URL}`);
console.log(`[Proxy] AgentCore REST Base: ${AGENTCORE_REST_BASE}`);

const server = createServer(async (req, res) => {
  // CORS headers for all responses
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  res.setHeader(
    "Access-Control-Allow-Headers",
    "Content-Type, Authorization, X-Amzn-Bedrock-AgentCore-Runtime-Session-Id"
  );

  // Handle CORS preflight
  if (req.method === "OPTIONS") {
    res.writeHead(200);
    res.end();
    return;
  }

  // Health check endpoint
  if (req.url === "/health") {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ status: "ok" }));
    return;
  }

  // HTTP Proxy: Forward /invocations to AgentCore REST endpoint
  if (req.url?.startsWith("/invocations") && req.method === "POST") {
    try {
      // Read request body
      let body = "";
      for await (const chunk of req) body += chunk;

      // Extract headers from browser request
      const authHeader = req.headers["authorization"] as string | undefined;
      const sessionId = req.headers[
        "x-amzn-bedrock-agentcore-runtime-session-id"
      ] as string | undefined;

      // Build AgentCore URL (preserve query string)
      const agentcoreUrl = `${AGENTCORE_REST_BASE}${req.url}`;

      // Build headers for AgentCore
      const headers: Record<string, string> = {
        "Content-Type": "application/json",
      };
      if (authHeader) headers["Authorization"] = authHeader;
      if (sessionId) {
        headers["X-Amzn-Bedrock-AgentCore-Runtime-Session-Id"] = sessionId;
      }

      console.log(
        `[HTTP-Proxy] POST ${req.url} → AgentCore (session: ${sessionId || "none"})`
      );

      // Forward to AgentCore
      const agentcoreRes = await fetch(agentcoreUrl, {
        method: "POST",
        headers,
        body,
      });

      const responseBody = await agentcoreRes.text();

      console.log(
        `[HTTP-Proxy] Response: ${agentcoreRes.status} (session: ${sessionId || "none"})`
      );

      res.writeHead(agentcoreRes.status, {
        "Content-Type": "application/json",
      });
      res.end(responseBody);
    } catch (error) {
      console.error("[HTTP-Proxy] Error:", (error as Error).message);
      res.writeHead(502, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "Proxy error", details: (error as Error).message }));
    }
    return;
  }

  res.writeHead(404);
  res.end();
});

const wss = new WebSocketServer({ server, path: "/ws" });

wss.on("connection", (browserWs: WebSocket, req: IncomingMessage) => {
  const url = new URL(req.url || "/", `http://localhost:${PROXY_PORT}`);
  const token = url.searchParams.get("token");
  const sessionId = url.searchParams.get("sessionId");

  if (!token) {
    console.error("[WS-Proxy] No token provided, closing connection");
    browserWs.close(4001, "Missing authentication token");
    return;
  }

  // Include sessionId in AgentCore WS URL for session management
  // See: https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime-get-started-websocket.html#websocket-session-management
  let agentcoreUrl = AGENTCORE_WS_URL;
  if (sessionId) {
    agentcoreUrl += `&X-Amzn-Bedrock-AgentCore-Runtime-Session-Id=${encodeURIComponent(sessionId)}`;
  }

  console.log(`[WS-Proxy] Browser connected (session: ${sessionId || "none"}), opening AgentCore connection...`);
  console.log(`[WS-Proxy] AgentCore WS URL: ${agentcoreUrl}`);

  // Connect to AgentCore with Authorization header and session ID header
  const headers: Record<string, string> = {
    Authorization: `Bearer ${token}`,
  };
  if (sessionId) {
    headers["X-Amzn-Bedrock-AgentCore-Runtime-Session-Id"] = sessionId;
  }
  const agentcoreWs = new WebSocket(agentcoreUrl, { headers });

  let agentcoreReady = false;
  const pendingMessages: string[] = [];

  agentcoreWs.on("open", () => {
    console.log("[WS-Proxy] Connected to AgentCore WebSocket");
    agentcoreReady = true;

    // Send any messages that arrived while connecting
    for (const msg of pendingMessages) {
      agentcoreWs.send(msg);
    }
    pendingMessages.length = 0;
  });

  agentcoreWs.on("error", (error) => {
    console.error("[WS-Proxy] AgentCore WebSocket error:", error.message);
    if (browserWs.readyState === WebSocket.OPEN) {
      browserWs.send(JSON.stringify({ type: "error", error: "Backend connection failed" }));
      browserWs.close(1011, "Backend connection failed");
    }
  });

  agentcoreWs.on("close", (code, reason) => {
    console.log(`[WS-Proxy] AgentCore closed: ${code} ${reason.toString()}`);
    if (browserWs.readyState === WebSocket.OPEN) {
      // Close codes 1005/1006 are reserved and can't be sent explicitly
      const safeCode = code === 1005 || code === 1006 ? 1000 : code;
      browserWs.close(safeCode, reason.toString() || "AgentCore connection closed");
    }
  });

  // Forward AgentCore → Browser
  agentcoreWs.on("message", (data) => {
    const msg = data.toString();
    try {
      const parsed = JSON.parse(msg);
      const msgType = parsed.type || "unknown";
      const msgCount = parsed.messages?.length ?? "";
      console.log(`[WS-Proxy] AgentCore→Browser: type=${msgType}${msgCount !== "" ? ` messages=${msgCount}` : ""}`);
    } catch {
      console.log(`[WS-Proxy] AgentCore→Browser: (non-JSON, ${msg.length} bytes)`);
    }
    if (browserWs.readyState === WebSocket.OPEN) {
      browserWs.send(msg);
    } else {
      console.warn(`[WS-Proxy] AgentCore→Browser: DROPPED (browser not open, readyState=${browserWs.readyState})`);
    }
  });

  // Forward Browser → AgentCore
  browserWs.on("message", (data) => {
    const msg = data.toString();
    try {
      const parsed = JSON.parse(msg);
      console.log(`[WS-Proxy] Browser→AgentCore: type=${parsed.type} chatId=${parsed.chatId || "none"}`);
    } catch {
      console.log(`[WS-Proxy] Browser→AgentCore: (non-JSON, ${msg.length} bytes)`);
    }
    if (agentcoreReady && agentcoreWs.readyState === WebSocket.OPEN) {
      agentcoreWs.send(msg);
    } else {
      // Queue message until AgentCore connection is ready
      console.log(`[WS-Proxy] Browser→AgentCore: QUEUED (agentcore not ready)`);
      pendingMessages.push(msg);
    }
  });

  browserWs.on("close", () => {
    console.log("[WS-Proxy] Browser disconnected");
    if (agentcoreWs.readyState === WebSocket.OPEN) {
      agentcoreWs.close();
    }
  });

  browserWs.on("error", (error) => {
    console.error("[WS-Proxy] Browser WebSocket error:", error.message);
    if (agentcoreWs.readyState === WebSocket.OPEN) {
      agentcoreWs.close();
    }
  });
});

server.listen(PROXY_PORT, () => {
  console.log(`[Proxy] HTTP + WebSocket proxy running on http://localhost:${PROXY_PORT}`);
  console.log(`[Proxy] REST: POST /invocations → ${AGENTCORE_REST_BASE}/invocations`);
  console.log(`[Proxy] WS:   /ws → ${AGENTCORE_WS_URL}`);
});
