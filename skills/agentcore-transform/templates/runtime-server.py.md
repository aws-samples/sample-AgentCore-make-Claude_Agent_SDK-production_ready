# Template: runtime_server.py

AgentCore Runtime server for Python applications.

Provides both FastAPI and Flask variants. Choose based on the user's framework.

## FastAPI Variant

```python
"""
AgentCore Runtime Server (FastAPI)

Runs inside AWS Bedrock AgentCore Runtime. Exposes:
- POST /invocations — REST API router
- WebSocket /ws — Streaming agent communication
- GET /health — Health check

Port: 8080 (required by AgentCore Runtime)
"""

import os
import json
import signal
import sys
import logging
from datetime import datetime

import uvicorn
from fastapi import FastAPI, WebSocket, WebSocketDisconnect, Request
from fastapi.middleware.cors import CORSMiddleware

# ADAPT: import your store, session, and auth modules
from store import store, use_memory
from auth import get_actor_id_from_token, extract_bearer_token, decode_jwt_payload
# ADAPT: import your session/agent class
# from session import Session

logger = logging.getLogger(__name__)

app = FastAPI()
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

PORT = int(os.environ.get("PORT", 8080))

# Session management
sessions: dict = {}


async def get_or_create_session(chat_id: str, actor_id: str, session_id: str | None = None):
    if chat_id not in sessions:
        # ADAPT: match your Session creation pattern
        # sessions[chat_id] = await Session.create(chat_id, actor_id, session_id)
        pass
    return sessions.get(chat_id)


@app.get("/health")
async def health():
    return {"status": "healthy", "timestamp": datetime.utcnow().isoformat()}


@app.post("/invocations")
async def invocations(request: Request):
    """
    /invocations — REST API router.
    ADAPT: copy your existing REST routes into the if-elif chain below.
    """
    try:
        data = await request.json()
        inp = data.get("input")
        if not inp:
            return {"output": {"statusCode": 400, "body": {"error": "Missing 'input'"}}}

        method = inp.get("method", "GET")
        path = inp.get("path", "")
        body = inp.get("body", {})
        session_id = inp.get("sessionId")
        actor_id = get_actor_id_from_token(extract_bearer_token(request))

        logger.info(f"[Invocation] {method} {path} (session: {session_id}, actor: {actor_id})")

        status_code = 200
        result = {}

        try:
            # ADAPT: Replace these routes with your application's actual endpoints
            if method == "GET" and path == "/api/chats":
                if use_memory:
                    result = store.get_all_chats(actor_id)
                else:
                    result = store.get_all_chats()

            elif method == "POST" and path == "/api/chats":
                title = body.get("title") if body else None
                if session_id:
                    if use_memory:
                        result = store.ensure_chat(actor_id, session_id, title)
                    else:
                        result = store.ensure_chat(session_id, title)
                else:
                    if use_memory:
                        result = store.create_chat(actor_id, title)
                    else:
                        result = store.create_chat(title)

            # ADAPT: Add more route handlers...

            else:
                status_code = 404
                result = {"error": f"Route not found: {method} {path}"}

        except Exception as e:
            logger.error(f"[Invocation] Handler error: {e}")
            status_code = 500
            result = {"error": str(e)}

        return {"output": {"statusCode": status_code, "body": result}}

    except Exception as e:
        logger.error(f"[Invocation] Request error: {e}")
        return {"output": {"statusCode": 500, "body": {"error": str(e)}}}


@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket):
    """WebSocket endpoint for real-time agent communication."""
    token = websocket.query_params.get("token")
    actor_id = get_actor_id_from_token(token)

    await websocket.accept()
    await websocket.send_json({"type": "connected", "message": "Connected to AgentCore chat server"})

    try:
        while True:
            data = await websocket.receive_json()
            msg_type = data.get("type")

            if msg_type == "subscribe":
                chat_id = data.get("chatId")
                # ADAPT: get or create session, send history
                if use_memory:
                    messages = store.get_messages(actor_id, chat_id)
                else:
                    messages = store.get_messages(chat_id)
                await websocket.send_json({"type": "history", "messages": messages, "chatId": chat_id})

            elif msg_type == "chat":
                chat_id = data.get("chatId")
                content = data.get("content", "")
                # ADAPT: send message to agent session, stream responses back
                pass

    except WebSocketDisconnect:
        logger.info("[WebSocket] Client disconnected")
    except Exception as e:
        logger.error(f"[WebSocket] Error: {e}")


def handle_sigterm(signum, frame):
    logger.info("[Runtime] SIGTERM received, shutting down")
    sys.exit(0)


signal.signal(signal.SIGTERM, handle_sigterm)

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=PORT)
```

## Flask Variant

```python
"""
AgentCore Runtime Server (Flask + flask-sock)
"""

import os
import json
import signal
import sys
from datetime import datetime

from flask import Flask, request, jsonify
from flask_sock import Sock
from flask_cors import CORS

from store import store, use_memory
from auth import get_actor_id_from_token, extract_bearer_token

app = Flask(__name__)
CORS(app)
sock = Sock(app)

PORT = int(os.environ.get("PORT", 8080))


@app.route("/health")
def health():
    return jsonify({"status": "healthy", "timestamp": datetime.utcnow().isoformat()})


@app.route("/invocations", methods=["POST"])
def invocations():
    # Same routing pattern as FastAPI variant
    data = request.get_json()
    inp = data.get("input", {})
    method = inp.get("method", "GET")
    path = inp.get("path", "")
    body = inp.get("body", {})
    actor_id = get_actor_id_from_token(extract_bearer_token(request))

    status_code = 200
    result = {}

    # ADAPT: route handlers here...

    return jsonify({"output": {"statusCode": status_code, "body": result}})


@sock.route("/ws")
def websocket(ws):
    # ADAPT: WebSocket handler
    ws.send(json.dumps({"type": "connected", "message": "Connected"}))
    while True:
        data = json.loads(ws.receive())
        # Handle messages...


signal.signal(signal.SIGTERM, lambda s, f: sys.exit(0))

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=PORT)
```
