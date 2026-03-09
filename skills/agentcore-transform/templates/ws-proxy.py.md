# Template: ws_proxy.py

WebSocket and HTTP proxy for local development (Python variant).

```python
"""
WebSocket & HTTP Proxy Server

Bridges browser connections to AgentCore Runtime endpoints.
Used for local development against the deployed AgentCore backend.
"""

import os
import asyncio
import json
import logging
from urllib.parse import quote

import aiohttp
from aiohttp import web, WSMsgType

logger = logging.getLogger(__name__)

PROXY_PORT = int(os.environ.get("PROXY_PORT", 3001))
AGENTCORE_REGION = os.environ.get("AWS_REGION", "us-east-1")
AGENT_ARN = os.environ.get("AGENT_ARN", "")

encoded_arn = quote(AGENT_ARN, safe="")
AGENTCORE_WS_URL = f"wss://bedrock-agentcore.{AGENTCORE_REGION}.amazonaws.com/runtimes/{encoded_arn}/ws?qualifier=DEFAULT"
AGENTCORE_REST_BASE = f"https://bedrock-agentcore.{AGENTCORE_REGION}.amazonaws.com/runtimes/{encoded_arn}"


async def handle_invocations(request: web.Request) -> web.Response:
    """HTTP Proxy: /invocations -> AgentCore."""
    try:
        body = await request.text()
        auth_header = request.headers.get("Authorization")
        session_id = request.headers.get("X-Amzn-Bedrock-AgentCore-Runtime-Session-Id")

        headers = {"Content-Type": "application/json"}
        if auth_header:
            headers["Authorization"] = auth_header
        if session_id:
            headers["X-Amzn-Bedrock-AgentCore-Runtime-Session-Id"] = session_id

        url = f"{AGENTCORE_REST_BASE}{request.path_qs}"
        logger.info(f"[HTTP-Proxy] POST {request.path} -> AgentCore")

        async with aiohttp.ClientSession() as session:
            async with session.post(url, headers=headers, data=body) as resp:
                response_body = await resp.text()
                return web.Response(
                    status=resp.status,
                    text=response_body,
                    content_type="application/json",
                )
    except Exception as e:
        logger.error(f"[HTTP-Proxy] Error: {e}")
        return web.json_response(
            {"error": "Proxy error", "details": str(e)}, status=502
        )


async def handle_websocket(request: web.Request) -> web.WebSocketResponse:
    """WebSocket Proxy: browser <-> AgentCore."""
    token = request.query.get("token")
    session_id = request.query.get("sessionId")

    if not token:
        return web.Response(status=401, text="Missing token")

    browser_ws = web.WebSocketResponse()
    await browser_ws.prepare(request)

    # Connect to AgentCore
    agentcore_url = AGENTCORE_WS_URL
    if session_id:
        agentcore_url += f"&X-Amzn-Bedrock-AgentCore-Runtime-Session-Id={quote(session_id, safe='')}"

    headers = {"Authorization": f"Bearer {token}"}
    if session_id:
        headers["X-Amzn-Bedrock-AgentCore-Runtime-Session-Id"] = session_id

    logger.info(f"[WS-Proxy] Browser connected (session: {session_id or 'none'})")

    async with aiohttp.ClientSession() as session:
        async with session.ws_connect(agentcore_url, headers=headers) as agentcore_ws:

            async def forward_to_browser():
                async for msg in agentcore_ws:
                    if msg.type == WSMsgType.TEXT:
                        await browser_ws.send_str(msg.data)
                    elif msg.type in (WSMsgType.CLOSED, WSMsgType.ERROR):
                        break

            async def forward_to_agentcore():
                async for msg in browser_ws:
                    if msg.type == WSMsgType.TEXT:
                        await agentcore_ws.send_str(msg.data)
                    elif msg.type in (WSMsgType.CLOSED, WSMsgType.ERROR):
                        break

            await asyncio.gather(
                forward_to_browser(),
                forward_to_agentcore(),
                return_exceptions=True,
            )

    return browser_ws


async def handle_health(request: web.Request) -> web.Response:
    return web.json_response({"status": "ok"})


app = web.Application()
app.router.add_post("/invocations", handle_invocations)
app.router.add_get("/ws", handle_websocket)
app.router.add_get("/health", handle_health)

if __name__ == "__main__":
    logger.info(f"[Proxy] Running on http://localhost:{PROXY_PORT}")
    web.run_app(app, port=PROXY_PORT)
```

**Python dependencies for proxy:**
```
aiohttp
```
