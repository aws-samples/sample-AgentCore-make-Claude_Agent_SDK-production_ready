"""In-memory chat storage."""

import uuid
from datetime import datetime


class ChatStore:
    def __init__(self):
        self._chats: dict[str, dict] = {}
        self._messages: dict[str, list[dict]] = {}

    def create_chat(self) -> dict:
        chat_id = str(uuid.uuid4())
        chat = {
            "id": chat_id,
            "title": "New Chat",
            "created_at": datetime.now().isoformat(),
        }
        self._chats[chat_id] = chat
        self._messages[chat_id] = []
        return chat

    def list_chats(self) -> list[dict]:
        return sorted(
            self._chats.values(),
            key=lambda c: c["created_at"],
            reverse=True,
        )

    def get_chat(self, chat_id: str) -> dict | None:
        return self._chats.get(chat_id)

    def delete_chat(self, chat_id: str) -> None:
        self._chats.pop(chat_id, None)
        self._messages.pop(chat_id, None)

    def add_message(self, chat_id: str, message: dict) -> None:
        if chat_id not in self._messages:
            self._messages[chat_id] = []
        self._messages[chat_id].append({
            **message,
            "id": str(uuid.uuid4()),
            "timestamp": datetime.now().isoformat(),
        })

    def get_messages(self, chat_id: str) -> list[dict]:
        return self._messages.get(chat_id, [])


store = ChatStore()
