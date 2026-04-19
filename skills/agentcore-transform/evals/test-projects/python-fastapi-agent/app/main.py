"""Minimal FastAPI chat agent using Claude Agent SDK — test project for agentcore-transform skill."""

import uuid
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.responses import JSONResponse

from app.ai_client import send_message
from app.chat_store import store

app = FastAPI(title="Python FastAPI Chat Agent")


@app.get("/api/chats")
async def list_chats():
    return store.list_chats()


@app.post("/api/chats")
async def create_chat():
    chat = store.create_chat()
    return chat


@app.get("/api/chats/{chat_id}")
async def get_chat(chat_id: str):
    chat = store.get_chat(chat_id)
    if not chat:
        return JSONResponse(status_code=404, content={"error": "Chat not found"})
    return chat


@app.delete("/api/chats/{chat_id}")
async def delete_chat(chat_id: str):
    store.delete_chat(chat_id)
    return {"success": True}


@app.get("/api/chats/{chat_id}/messages")
async def get_messages(chat_id: str):
    return store.get_messages(chat_id)


@app.websocket("/ws")
async def websocket_endpoint(ws: WebSocket):
    await ws.accept()
    subscribed_chat_id = None

    try:
        while True:
            data = await ws.receive_json()

            if data.get("type") == "subscribe":
                subscribed_chat_id = data["chatId"]
                messages = store.get_messages(subscribed_chat_id)
                await ws.send_json({"type": "history", "messages": messages})

            elif data.get("type") == "chat":
                chat_id = data["chatId"]
                content = data["content"]

                # Store user message
                store.add_message(chat_id, {"role": "user", "content": content})

                # Get AI response
                history = store.get_messages(chat_id)
                response = await send_message(chat_id, content, history)

                # Store assistant message
                store.add_message(chat_id, {"role": "assistant", "content": response})

                await ws.send_json({
                    "type": "assistant_message",
                    "content": response,
                })
                await ws.send_json({"type": "result", "success": True})

    except WebSocketDisconnect:
        pass


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=3001)
