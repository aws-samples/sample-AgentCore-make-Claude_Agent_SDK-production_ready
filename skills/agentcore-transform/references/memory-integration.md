# Memory Integration Reference

Patterns for integrating AgentCore Memory (STM + LTM) into a Claude Agent SDK application.

## AgentCore Memory Concepts

**Short-Term Memory (STM):**
- Stores raw conversational events per session.
- Each event has: `memoryId`, `actorId`, `sessionId`, `eventTimestamp`, `payload`.
- Payload types: `ConversationalMember` (user/assistant messages) or `BlobMember` (arbitrary JSON).
- Events are append-only, listed chronologically.
- Events expire based on the memory resource's `eventExpiryDays` setting.

**Long-Term Memory (LTM):**
- Auto-extracted semantic records from conversational events.
- Extraction happens automatically when events are added (if memory has strategies configured).
- Retrieved via semantic search (`RetrieveMemoryRecords`).
- Returns ranked results based on query relevance.
- Stores facts, preferences, entities extracted from conversations.

**Memory Resource:**
- Created via `agentcore memory create` with extraction strategies.
- Identified by a `memoryId` (passed as environment variable).
- Supports multiple actors (users) and sessions (chats) within one resource.

## SDK Operations

### TypeScript (AWS SDK v3)

```typescript
import {
  BedrockAgentCoreClient,
  CreateEventCommand,
  ListEventsCommand,
  RetrieveMemoryRecordsCommand,
} from "@aws-sdk/client-bedrock-agentcore";

const client = new BedrockAgentCoreClient({ region });
const MEMORY_ID = process.env.AGENTCORE_MEMORY_ID;
```

**Create a conversational event (STM write):**
```typescript
await client.send(new CreateEventCommand({
  memoryId: MEMORY_ID,
  actorId,          // user identity (e.g., Cognito sub)
  sessionId,        // chat/conversation ID
  eventTimestamp: new Date(),
  payload: [{
    conversational: {
      content: { text: messageContent },
      role: role === "user" ? "USER" : "ASSISTANT",
    },
  }],
}));
```

**Create a blob event (metadata storage):**

**CRITICAL:** Always pass blob data as a JSON string via `JSON.stringify()`. Do NOT pass
a plain object — the SDK serializes objects using Java Map.toString() format which cannot
be parsed back as JSON.

```typescript
await client.send(new CreateEventCommand({
  memoryId: MEMORY_ID,
  actorId,
  sessionId: "chat-registry",  // dedicated session for metadata
  eventTimestamp: new Date(),
  payload: [{
    blob: JSON.stringify(data),  // MUST be a JSON string, NOT a plain object
  }],
}));
```

**List events (STM read):**
```typescript
const events = [];
let nextToken;
do {
  const response = await client.send(new ListEventsCommand({
    memoryId: MEMORY_ID,
    actorId,
    sessionId,
    includePayloads: true,  // REQUIRED to get payload data
    ...(nextToken ? { nextToken } : {}),
  }));
  events.push(...(response.events || []));
  nextToken = response.nextToken;
} while (nextToken);
```

**Semantic search (LTM read):**
```typescript
const response = await client.send(new RetrieveMemoryRecordsCommand({
  memoryId: MEMORY_ID,
  namespace: "/",
  searchCriteria: {
    searchQuery: query,
    topK: 5,
  },
}));
const records = (response.memoryRecordSummaries || [])
  .map(r => (r.content as any)?.text || "")
  .filter(Boolean);
```

### Python (boto3)

```python
import boto3
import os

client = boto3.client("bedrock-agentcore", region_name=os.environ.get("AWS_REGION", "us-east-1"))
MEMORY_ID = os.environ["AGENTCORE_MEMORY_ID"]
```

**Create a conversational event:**
```python
from datetime import datetime

client.create_event(
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
```

**Create a blob event:**

**CRITICAL:** Pass blob as a JSON string, not a dict. The API serializes dicts using
Java Map format which cannot be deserialized back to JSON.

```python
import json

client.create_event(
    memoryId=MEMORY_ID,
    actorId=actor_id,
    sessionId="chat-registry",
    eventTimestamp=datetime.utcnow(),
    payload=[{"blob": json.dumps(data)}],  # MUST be a JSON string
```

**List events:**
```python
events = []
next_token = None
while True:
    kwargs = {
        "memoryId": MEMORY_ID,
        "actorId": actor_id,
        "sessionId": session_id,
        "includePayloads": True,
    }
    if next_token:
        kwargs["nextToken"] = next_token
    response = client.list_events(**kwargs)
    events.extend(response.get("events", []))
    next_token = response.get("nextToken")
    if not next_token:
        break
```

**Semantic search (LTM):**
```python
response = client.retrieve_memory_records(
    memoryId=MEMORY_ID,
    namespace="/",
    searchCriteria={
        "searchQuery": query,
        "topK": top_k,
    },
)
records = [
    r["content"]["text"]
    for r in response.get("memoryRecordSummaries", [])
    if r.get("content", {}).get("text")
]
```

## Blob Payload Read Format (CRITICAL)

The AgentCore Memory API returns blob payloads as **strings in Java Map.toString()
format**, NOT as JSON or parsed objects. Example:

```
{chatTitle=Test Chat, createdAt=2026-03-08T02:06:46.578Z, eventType=chat_created, chatId=98ed9830-...}
```

This is NOT valid JSON (`=` instead of `:`, no quotes). When reading blob payloads,
you MUST include a fallback parser for this format alongside `JSON.parse()`.

**TypeScript parser:**
```typescript
function parseJavaMapString(str: string): Record<string, string> {
  const trimmed = str.trim();
  if (!trimmed.startsWith("{") || !trimmed.endsWith("}")) return {};
  const inner = trimmed.slice(1, -1);
  const result: Record<string, string> = {};
  let key = "", value = "", inKey = true, i = 0;
  while (i < inner.length) {
    const ch = inner[i];
    if (inKey && ch === "=") { inKey = false; i++; continue; }
    if (!inKey && inner.slice(i, i + 2) === ", " && /^[a-zA-Z]/.test(inner[i + 2] || "")) {
      const rest = inner.slice(i + 2);
      if (rest.includes("=")) {
        result[key.trim()] = value.trim();
        key = ""; value = ""; inKey = true; i += 2; continue;
      }
    }
    if (inKey) key += ch; else value += ch;
    i++;
  }
  if (key) result[key.trim()] = value.trim();
  return result;
}
```

**Blob read pattern (always try JSON first, fall back to Java Map parser):**
```typescript
if (typeof blob === "string") {
  try {
    data = JSON.parse(blob);
  } catch {
    const parsed = parseJavaMapString(blob);
    if (parsed.chatId) {
      data = { chatId: parsed.chatId, chatTitle: parsed.chatTitle, ... };
    }
  }
}
```

## Chat Registry Pattern

The chat registry stores chat metadata (title, created/updated timestamps)
as blob events in a dedicated STM session (`chat-registry`). This avoids
needing a separate database for chat CRUD.

**Registry event structure:**
```typescript
interface RegistryEventData {
  chatId: string;
  chatTitle?: string;
  eventType: "chat_created" | "chat_updated" | "chat_deleted";
  createdAt?: string;
  updatedAt: string;
}
```

**Reconstructing chat list:**
1. List all events in the `chat-registry` session.
2. Build a map: `chatId -> latest event data`.
3. Filter out entries where `eventType === "chat_deleted"`.
4. Sort by `updatedAt` descending.

This is an append-only log — updates overwrite previous entries for the same chatId
when the map is built. Deleted chats are soft-deleted via a `chat_deleted` event.

## Bounded Context Pattern

To avoid unbounded context growth in the agent's system prompt:

1. **STM bound:** Only load the last N turns (e.g., 20) from STM.
2. **LTM bound:** Only retrieve top-K records (e.g., 5) from LTM search.
3. **Injection:** Prepend LTM context to the user's message before sending to agent.

**CRITICAL:** The `searchLTM()` function MUST be actively called before each agent
turn. Simply defining the function is not enough — without the call, LTM is dead code.

### Implementation pattern (message enrichment)

For long-lived agent sessions (where the Agent SDK's `query()` maintains conversation
state), the simplest approach is to enrich the user's message with LTM context:

```typescript
// In session.ts sendMessage() — MUST be async
async sendMessage(content: string, actorId?: string) {
  // ... store user message ...

  // Search LTM for relevant context BEFORE sending to agent
  let enrichedContent = content;
  if (useMemory) {
    try {
      const ltmRecords = await searchLTM(actor, content, 5);
      if (ltmRecords.length > 0) {
        const ltmContext = ltmRecords.map((r) => `- ${r}`).join("\n");
        enrichedContent = `[Relevant context from previous conversations:\n${ltmContext}]\n\n${content}`;
        console.log(`[Memory] Injected ${ltmRecords.length} LTM records`);
      }
    } catch (err) {
      console.error("[Memory] LTM search failed:", err);
    }
  }

  this.agentSession.sendMessage(enrichedContent);
}
```

### System prompt update

The agent's system prompt must instruct it to use LTM context naturally:

```typescript
const SYSTEM_PROMPT = `You are a helpful AI assistant. ...

When a user message includes a section marked [Relevant context from previous
conversations:], use that information naturally to provide more personalized
and informed responses. Do not explicitly mention that you retrieved memories
unless the user asks about it.`;
```

### Why enrich the message, not the system prompt?

The Agent SDK's `query()` creates a long-lived session with a fixed system prompt
set at construction time. Modifying the system prompt per-turn would require
recreating the query (expensive). Prepending LTM context to the user message is
simpler and works with the existing architecture.

### Alternative: System prompt injection

If the agent architecture supports dynamic system prompts (e.g., new query per turn),
append both STM and LTM to the system prompt:

```
[original system prompt]

Relevant context from previous conversations:
- [LTM record 1]
- [LTM record 2]
...

Recent conversation:
User: [message]
Assistant: [response]
...
```

## Feature Flag Pattern

The store router module gates all Memory operations behind an environment variable:

```typescript
// store.ts
export const useMemory = !!process.env.AGENTCORE_MEMORY_ID;
export const store = useMemory ? memoryStore : chatStore;
```

```python
# store.py
import os
use_memory = bool(os.environ.get("AGENTCORE_MEMORY_ID"))
store = memory_store if use_memory else chat_store
```

All callers import from `store` module and branch on `useMemory`:
- Memory path: `await store.addMessage(actorId, chatId, msg)` (async, has actorId)
- Local path: `store.addMessage(chatId, msg)` (sync or async, no actorId)

## LTM Extraction Trigger

Extraction is automatic when conversational events are added to a memory
with configured strategies. No manual `StartMemoryExtractionJob` call needed.
The semantic strategy processes new events asynchronously.

After a conversation turn completes (agent returns a `result` event),
log that extraction will happen automatically:

```typescript
console.log(`[Memory] Auto-extraction will process events for actor=${actorId} session=${sessionId}`);
```

## Error Handling

All Memory API calls should be wrapped in try/catch with graceful degradation:

```typescript
try {
  await addMessageEvent(actorId, chatId, "user", content);
} catch (error) {
  console.error("[Memory] Failed to store message:", error);
  // Don't crash — the message was still sent to the agent
}
```

LTM search failures should return empty results, not throw:

```typescript
export async function searchLTM(...): Promise<string[]> {
  try {
    // ... search logic
  } catch (error) {
    console.warn("[Memory] LTM search failed:", error?.message);
    return [];
  }
}
```
