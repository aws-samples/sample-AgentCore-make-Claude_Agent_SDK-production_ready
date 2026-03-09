# Template: memory_client.py

AgentCore Memory SDK wrapper for Python applications.

Adapt this template to the user's project by:
- Adjusting type definitions to match existing models
- Using sync or async patterns to match the project's style
- Matching the project's logging conventions

```python
"""
AgentCore Memory SDK wrapper.

STM (Short-Term Memory): stores verbatim conversation events per session.
LTM (Long-Term Memory): stores auto-extracted semantic records.
"""

import os
import json
import logging
from datetime import datetime
from typing import Any
from uuid import uuid4

import boto3

logger = logging.getLogger(__name__)

# Singleton client — uses IAM execution role inside AgentCore container
_region = os.environ.get("AWS_REGION", "us-east-1")
memory_client = boto3.client("bedrock-agentcore", region_name=_region)
MEMORY_ID = os.environ.get("AGENTCORE_MEMORY_ID", "")

# Dedicated session ID for chat metadata registry
CHAT_REGISTRY_SESSION = "chat-registry"


# ─── STM helpers ───────────────────────────────────────────────

def add_message_event(actor_id: str, session_id: str, role: str, content: str) -> None:
    """Add a conversational message event to STM."""
    memory_client.create_event(
        memoryId=MEMORY_ID,
        actorId=actor_id,
        sessionId=session_id,
        eventTimestamp=datetime.utcnow(),
        payload=[{
            "conversational": {
                "content": {"text": content},
                "role": "USER" if role == "user" else "ASSISTANT",
            }
        }],
    )


def get_session_events(actor_id: str, session_id: str) -> list[dict]:
    """List all events for a session (paginated). Includes payloads."""
    events: list[dict] = []
    next_token = None

    while True:
        kwargs: dict[str, Any] = {
            "memoryId": MEMORY_ID,
            "actorId": actor_id,
            "sessionId": session_id,
            "includePayloads": True,
        }
        if next_token:
            kwargs["nextToken"] = next_token

        response = memory_client.list_events(**kwargs)
        events.extend(response.get("events", []))
        next_token = response.get("nextToken")
        if not next_token:
            break

    return events


def get_recent_turns(actor_id: str, session_id: str, k: int) -> list[dict]:
    """Get the last k events from a session (most recent turns)."""
    all_events = get_session_events(actor_id, session_id)
    return all_events[-k:]


def _get_conversational_text(event: dict) -> dict | None:
    """Extract text from a conversational payload event."""
    payload = event.get("payload")
    if not payload or not isinstance(payload, list):
        return None
    for p in payload:
        if "conversational" in p:
            conv = p["conversational"]
            return {
                "role": conv.get("role", "OTHER"),
                "text": conv.get("content", {}).get("text", ""),
            }
    return None


def events_to_messages(events: list[dict], chat_id: str) -> list[dict]:
    """
    Convert STM events to message dicts.
    ADAPT: match your message model fields.
    """
    messages = []
    for event in events:
        conv = _get_conversational_text(event)
        if not conv:
            continue
        ts = event.get("eventTimestamp")
        if hasattr(ts, "isoformat"):
            ts = ts.isoformat()
        elif not isinstance(ts, str):
            ts = datetime.utcnow().isoformat()

        messages.append({
            "id": event.get("eventId", f"evt-{len(messages)}"),
            "chatId": chat_id,
            "role": "user" if conv["role"] == "USER" else "assistant",
            "content": conv["text"],
            "timestamp": ts,
        })
    return messages


# ─── LTM helpers ───────────────────────────────────────────────

def search_ltm(actor_id: str, query: str, top_k: int = 5) -> list[str]:
    """Semantic search over LTM records."""
    try:
        response = memory_client.retrieve_memory_records(
            memoryId=MEMORY_ID,
            namespace="/",
            searchCriteria={
                "searchQuery": query,
                "topK": top_k,
            },
        )
        records = [
            r.get("content", {}).get("text", "")
            for r in response.get("memoryRecordSummaries", [])
        ]
        records = [r for r in records if r]
        logger.info(
            f"[Memory] LTM search for actor={actor_id} "
            f'query="{query[:50]}..." returned {len(records)} records'
        )
        return records
    except Exception as e:
        logger.warning(f"[Memory] LTM search failed: {e}")
        return []


def trigger_extraction(actor_id: str, session_id: str) -> None:
    """
    LTM extraction is automatic when conversational events are added
    to a memory with configured strategies. No manual trigger needed.
    """
    logger.info(
        f"[Memory] Auto-extraction will process events "
        f"for actor={actor_id} session={session_id}"
    )


# ─── Blob parsing helpers ─────────────────────────────────────

def parse_java_map_string(s: str) -> dict | None:
    """
    Parse Java Map.toString() format: {key=value, key2=value2}
    The Memory API may return blob payloads in this format instead of JSON
    when the blob was stored as a dict (not json.dumps'd string).
    """
    s = s.strip()
    if not (s.startswith("{") and s.endswith("}")):
        return None
    inner = s[1:-1]
    result = {}
    for pair in inner.split(", "):
        if "=" not in pair:
            continue
        k, v = pair.split("=", 1)
        # Convert "null" string to None
        result[k.strip()] = None if v.strip() == "null" else v.strip()
    return result


def parse_blob_payload(blob: Any) -> dict | None:
    """Parse a blob payload that may be JSON string, bytes, dict, or Java Map format."""
    if isinstance(blob, dict):
        return blob
    if isinstance(blob, bytes):
        blob = blob.decode()
    if isinstance(blob, str):
        # Try JSON first
        try:
            parsed = json.loads(blob)
            if isinstance(parsed, dict):
                return parsed
        except (json.JSONDecodeError, ValueError):
            pass
        # Fallback: Java Map.toString() format
        return parse_java_map_string(blob)
    return None


# ─── Chat registry helpers ─────────────────────────────────────

def create_registry_event(
    actor_id: str,
    chat_id: str,
    title: str,
    event_type: str,
    created_at: str | None = None,
) -> None:
    """Create a registry event for chat metadata tracking."""
    now = datetime.utcnow().isoformat()
    data = {
        "chatId": chat_id,
        "chatTitle": None if event_type == "chat_deleted" else title,
        "eventType": event_type,
        "createdAt": created_at or now,
        "updatedAt": now,
    }

    # CRITICAL: blob payload MUST be a JSON string, not a dict.
    # The Memory API serializes dicts via Java Map.toString() → {key=value}
    # which is NOT valid JSON. Always use json.dumps() for round-trip safety.
    memory_client.create_event(
        memoryId=MEMORY_ID,
        actorId=actor_id,
        sessionId=CHAT_REGISTRY_SESSION,
        eventTimestamp=datetime.utcnow(),
        payload=[{"blob": json.dumps(data)}],
    )


def get_chat_list(actor_id: str) -> list[dict]:
    """
    Get the list of active chats from the registry session.
    Deduplicates by chatId (latest event wins), filters out deleted.
    """
    events = get_session_events(actor_id, CHAT_REGISTRY_SESSION)

    chat_map: dict[str, dict] = {}
    for event in events:
        try:
            payload = event.get("payload")
            if not payload or not isinstance(payload, list):
                continue
            data = None
            for p in payload:
                if "blob" in p:
                    data = parse_blob_payload(p["blob"])
                    break
            if data and data.get("chatId"):
                chat_map[data["chatId"]] = data
        except Exception:
            continue

    chats = []
    for data in chat_map.values():
        if data.get("eventType") != "chat_deleted":
            chats.append({
                "id": data["chatId"],
                "title": data.get("chatTitle") or "New Chat",
                "createdAt": data.get("createdAt") or data["updatedAt"],
                "updatedAt": data["updatedAt"],
            })

    chats.sort(key=lambda c: c["updatedAt"], reverse=True)
    return chats
```
