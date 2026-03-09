# Template: ws-proxy.ts

WebSocket and HTTP proxy for local development against a deployed AgentCore backend.

This proxy is needed because:
1. Browsers can't set custom headers on WebSocket connections.
2. Cross-origin REST calls need auth and session headers forwarded.

```typescript
/**
 * WebSocket & HTTP Proxy Server
 *
 * Bridges browser connections to AgentCore Runtime endpoints.
 * Used for local development against the deployed AgentCore backend.
 */

import "dotenv/config";
import { createServer } from "http";
import { WebSocketServer, WebSocket } from "ws";
import type { IncomingMessage } from "http";

const PROXY_PORT = process.env.PROXY_PORT || 3001;
const AGENTCORE_REGION = process.env.AWS_REGION || "us-east-1";
// ADAPT: this will be populated by deploy.sh
const AGENT_ARN = process.env.AGENT_ARN || "";

// Construct AgentCore URLs
const encodedArn = encodeURIComponent(AGENT_ARN);
const AGENTCORE_WS_URL = `wss://bedrock-agentcore.${AGENTCORE_REGION}.amazonaws.com/runtimes/${encodedArn}/ws?qualifier=DEFAULT`;
const AGENTCORE_REST_BASE = `https://bedrock-agentcore.${AGENTCORE_REGION}.amazonaws.com/runtimes/${encodedArn}`;

console.log(`[Proxy] AgentCore REST: ${AGENTCORE_REST_BASE}`);

const server = createServer(async (req, res) => {
  // CORS
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type, Authorization, X-Amzn-Bedrock-AgentCore-Runtime-Session-Id");

  if (req.method === "OPTIONS") { res.writeHead(200); res.end(); return; }

  if (req.url === "/health") {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ status: "ok" }));
    return;
  }

  // HTTP Proxy: /invocations -> AgentCore
  if (req.url?.startsWith("/invocations") && req.method === "POST") {
    try {
      let body = "";
      for await (const chunk of req) body += chunk;

      const authHeader = req.headers["authorization"] as string | undefined;
      const sessionId = req.headers["x-amzn-bedrock-agentcore-runtime-session-id"] as string | undefined;

      const agentcoreUrl = `${AGENTCORE_REST_BASE}${req.url}`;
      const headers: Record<string, string> = { "Content-Type": "application/json" };
      if (authHeader) headers["Authorization"] = authHeader;
      if (sessionId) headers["X-Amzn-Bedrock-AgentCore-Runtime-Session-Id"] = sessionId;

      console.log(`[HTTP-Proxy] POST ${req.url} -> AgentCore (session: ${sessionId || "none"})`);

      const agentcoreRes = await fetch(agentcoreUrl, { method: "POST", headers, body });
      const responseBody = await agentcoreRes.text();

      res.writeHead(agentcoreRes.status, { "Content-Type": "application/json" });
      res.end(responseBody);
    } catch (error) {
      console.error("[HTTP-Proxy] Error:", (error as Error).message);
      res.writeHead(502, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "Proxy error", details: (error as Error).message }));
    }
    return;
  }

  res.writeHead(404); res.end();
});

const wss = new WebSocketServer({ server, path: "/ws" });

wss.on("connection", (browserWs: WebSocket, req: IncomingMessage) => {
  const url = new URL(req.url || "/", `http://localhost:${PROXY_PORT}`);
  const token = url.searchParams.get("token");
  const sessionId = url.searchParams.get("sessionId");

  if (!token) {
    browserWs.close(4001, "Missing authentication token");
    return;
  }

  let agentcoreUrl = AGENTCORE_WS_URL;
  if (sessionId) {
    agentcoreUrl += `&X-Amzn-Bedrock-AgentCore-Runtime-Session-Id=${encodeURIComponent(sessionId)}`;
  }

  console.log(`[WS-Proxy] Browser connected (session: ${sessionId || "none"})`);

  const headers: Record<string, string> = { Authorization: `Bearer ${token}` };
  if (sessionId) {
    headers["X-Amzn-Bedrock-AgentCore-Runtime-Session-Id"] = sessionId;
  }
  const agentcoreWs = new WebSocket(agentcoreUrl, { headers });

  let agentcoreReady = false;
  const pendingMessages: string[] = [];

  agentcoreWs.on("open", () => {
    agentcoreReady = true;
    for (const msg of pendingMessages) agentcoreWs.send(msg);
    pendingMessages.length = 0;
  });

  agentcoreWs.on("error", (error) => {
    console.error("[WS-Proxy] AgentCore error:", error.message);
    if (browserWs.readyState === WebSocket.OPEN) {
      browserWs.send(JSON.stringify({ type: "error", error: "Backend connection failed" }));
      browserWs.close(1011, "Backend connection failed");
    }
  });

  agentcoreWs.on("close", (code, reason) => {
    if (browserWs.readyState === WebSocket.OPEN) {
      const safeCode = code === 1005 || code === 1006 ? 1000 : code;
      browserWs.close(safeCode, reason.toString() || "AgentCore connection closed");
    }
  });

  // AgentCore -> Browser
  agentcoreWs.on("message", (data) => {
    if (browserWs.readyState === WebSocket.OPEN) browserWs.send(data.toString());
  });

  // Browser -> AgentCore
  browserWs.on("message", (data) => {
    const msg = data.toString();
    if (agentcoreReady && agentcoreWs.readyState === WebSocket.OPEN) {
      agentcoreWs.send(msg);
    } else {
      pendingMessages.push(msg);
    }
  });

  browserWs.on("close", () => {
    if (agentcoreWs.readyState === WebSocket.OPEN) agentcoreWs.close();
  });
});

server.listen(PROXY_PORT, () => {
  console.log(`[Proxy] Running on http://localhost:${PROXY_PORT}`);
  console.log(`[Proxy] REST: /invocations -> ${AGENTCORE_REST_BASE}/invocations`);
  console.log(`[Proxy] WS: /ws -> ${AGENTCORE_WS_URL}`);
});
```
