# Template: memory_store.py

Async store backed by AgentCore Memory for Python applications.

Adapt by matching the original store's method signatures and adding
`actor_id` as the first parameter to each method.

```python
"""
MemoryStore — drop-in replacement for the original store,
backed by AgentCore Memory.

All methods require an actor_id parameter (user identity).
STM sessions store conversation events; a dedicated registry session
tracks chat metadata.
"""

from uuid import uuid4
from datetime import datetime

from memory_client import (
    add_message_event,
    get_session_events,
    events_to_messages,
    create_registry_event,
    get_chat_list,
)


class MemoryStore:
    def create_chat(self, actor_id: str, title: str | None = None) -> dict:
        chat_id = str(uuid4())
        now = datetime.utcnow().isoformat()
        chat_title = title or "New Chat"

        create_registry_event(actor_id, chat_id, chat_title, "chat_created", now)

        return {"id": chat_id, "title": chat_title, "createdAt": now, "updatedAt": now}

    def get_chat(self, actor_id: str, chat_id: str) -> dict | None:
        chats = get_chat_list(actor_id)
        return next((c for c in chats if c["id"] == chat_id), None)

    def get_all_chats(self, actor_id: str) -> list[dict]:
        return get_chat_list(actor_id)

    def update_chat_title(self, actor_id: str, chat_id: str, title: str) -> dict | None:
        chat = self.get_chat(actor_id, chat_id)
        if not chat:
            return None

        create_registry_event(actor_id, chat_id, title, "chat_updated", chat["createdAt"])
        return {**chat, "title": title, "updatedAt": datetime.utcnow().isoformat()}

    def delete_chat(self, actor_id: str, chat_id: str) -> bool:
        chat = self.get_chat(actor_id, chat_id)
        if not chat:
            return False

        create_registry_event(actor_id, chat_id, "", "chat_deleted")
        return True

    def ensure_chat(self, actor_id: str, chat_id: str, title: str | None = None) -> dict:
        existing = self.get_chat(actor_id, chat_id)
        if existing:
            return existing

        now = datetime.utcnow().isoformat()
        chat_title = title or "New Chat"
        create_registry_event(actor_id, chat_id, chat_title, "chat_created", now)
        return {"id": chat_id, "title": chat_title, "createdAt": now, "updatedAt": now}

    def add_message(self, actor_id: str, chat_id: str, message: dict) -> dict:
        """
        message: {"role": "user"|"assistant", "content": "..."}
        """
        # Ensure chat exists
        self.ensure_chat(actor_id, chat_id)

        # Write to STM
        add_message_event(actor_id, chat_id, message["role"], message["content"])

        now = datetime.utcnow().isoformat()

        # Auto-generate title from first user message
        if message["role"] == "user":
            chat = self.get_chat(actor_id, chat_id)
            if chat and chat["title"] == "New Chat":
                content = message["content"]
                auto_title = content[:50] + ("..." if len(content) > 50 else "")
                create_registry_event(actor_id, chat_id, auto_title, "chat_updated", chat["createdAt"])

        # Update updatedAt
        chat = self.get_chat(actor_id, chat_id)
        if chat:
            create_registry_event(actor_id, chat_id, chat["title"], "chat_updated", chat["createdAt"])

        return {
            "id": str(uuid4()),
            "chatId": chat_id,
            "timestamp": now,
            **message,
        }

    def get_messages(self, actor_id: str, chat_id: str) -> list[dict]:
        events = get_session_events(actor_id, chat_id)
        return events_to_messages(events, chat_id)


memory_store = MemoryStore()
```
