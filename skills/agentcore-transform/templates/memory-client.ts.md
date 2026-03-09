# Template: memory-client.ts

AgentCore Memory SDK wrapper for TypeScript applications.

Adapt this template to the user's project by:
- Adjusting import paths for types (ChatMessage, etc.)
- Matching the existing store's method naming conventions
- Using the project's module system (ESM vs CJS)

```typescript
/**
 * AgentCore Memory SDK wrapper
 *
 * STM (Short-Term Memory): stores verbatim conversation events per session.
 * LTM (Long-Term Memory): stores auto-extracted semantic records.
 *
 * SDK types:
 *   PayloadType.ConversationalMember: { conversational: { content: { text }, role } }
 *   PayloadType.BlobMember: { blob: any }
 *   ListEventsInput: requires includePayloads: true
 *   RetrieveMemoryRecordsInput: { namespace, searchCriteria: { searchQuery, topK } }
 */

import {
  BedrockAgentCoreClient,
  CreateEventCommand,
  ListEventsCommand,
  RetrieveMemoryRecordsCommand,
} from "@aws-sdk/client-bedrock-agentcore";
import { v4 as uuidv4 } from "uuid";
// ADAPT: import your ChatMessage type from wherever it's defined
import type { ChatMessage } from "./types.js";

// Singleton client — uses IAM execution role inside AgentCore container
const region = process.env.AWS_REGION || "us-east-1";
export const memoryClient = new BedrockAgentCoreClient({ region });
export const MEMORY_ID = process.env.AGENTCORE_MEMORY_ID!;

// Dedicated session ID for chat metadata registry
const CHAT_REGISTRY_SESSION = "chat-registry";

// ─── STM helpers ───────────────────────────────────────────────

/**
 * Add a conversational message event to STM.
 */
export async function addMessageEvent(
  actorId: string,
  sessionId: string,
  role: "user" | "assistant",
  content: string,
): Promise<void> {
  await memoryClient.send(
    new CreateEventCommand({
      memoryId: MEMORY_ID,
      actorId,
      sessionId,
      eventTimestamp: new Date(),
      payload: [
        {
          conversational: {
            content: { text: content },
            role: role === "user" ? "USER" : "ASSISTANT",
          },
        },
      ],
    }),
  );
}

/**
 * List all events for a session (paginated). Includes payloads.
 */
export async function getSessionEvents(
  actorId: string,
  sessionId: string,
): Promise<any[]> {
  const events: any[] = [];
  let nextToken: string | undefined;

  do {
    const response = await memoryClient.send(
      new ListEventsCommand({
        memoryId: MEMORY_ID,
        actorId,
        sessionId,
        includePayloads: true,
        ...(nextToken ? { nextToken } : {}),
      }),
    );
    if (response.events) {
      events.push(...response.events);
    }
    nextToken = response.nextToken;
  } while (nextToken);

  return events;
}

/**
 * Get the last `k` events from a session (most recent turns).
 */
export async function getRecentTurns(
  actorId: string,
  sessionId: string,
  k: number,
): Promise<any[]> {
  const allEvents = await getSessionEvents(actorId, sessionId);
  return allEvents.slice(-k);
}

/**
 * Extract text from a conversational payload event.
 */
function getConversationalText(event: any): { role: string; text: string } | null {
  if (!event.payload || !Array.isArray(event.payload)) return null;
  for (const p of event.payload) {
    if (p.conversational) {
      return {
        role: p.conversational.role || "OTHER",
        text: p.conversational.content?.text || "",
      };
    }
  }
  return null;
}

/**
 * Convert STM events to ChatMessage[] format.
 * ADAPT: match your ChatMessage interface fields.
 */
export function eventsToMessages(
  events: any[],
  chatId: string,
): ChatMessage[] {
  const messages: ChatMessage[] = [];
  for (const event of events) {
    const conv = getConversationalText(event);
    if (!conv) continue;
    messages.push({
      id: event.eventId || `evt-${messages.length}`,
      chatId,
      role: conv.role === "USER" ? "user" : "assistant",
      content: conv.text,
      timestamp: event.eventTimestamp?.toISOString?.()
        || (typeof event.eventTimestamp === "string" ? event.eventTimestamp : new Date().toISOString()),
    } as ChatMessage);
  }
  return messages;
}

// ─── LTM helpers ───────────────────────────────────────────────

/**
 * Semantic search over LTM records.
 */
export async function searchLTM(
  actorId: string,
  query: string,
  topK: number = 5,
): Promise<string[]> {
  try {
    const response = await memoryClient.send(
      new RetrieveMemoryRecordsCommand({
        memoryId: MEMORY_ID,
        namespace: "/",
        searchCriteria: {
          searchQuery: query,
          topK,
        },
      }),
    );
    const records = (response.memoryRecordSummaries || [])
      .map((r) => {
        const content = r.content as any;
        return content?.text || "";
      })
      .filter(Boolean);
    console.log(`[Memory] LTM search for actor=${actorId} query="${query.slice(0, 50)}..." returned ${records.length} records`);
    return records;
  } catch (error: any) {
    console.warn("[Memory] LTM search failed:", error?.message || error);
    return [];
  }
}

/**
 * LTM extraction is automatic when conversational events are added
 * to a memory with configured strategies. No manual trigger needed.
 */
export async function triggerExtraction(
  actorId: string,
  sessionId: string,
): Promise<void> {
  console.log(`[Memory] Auto-extraction will process events for actor=${actorId} session=${sessionId}`);
}

// ─── Java Map string parser ───────────────────────────────────
// The AgentCore Memory API returns blob payloads as Java Map.toString() format
// (e.g., "{key=value, key2=value2}") instead of JSON. This parser handles that.

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

// ─── Chat registry helpers ─────────────────────────────────────

interface RegistryEventData {
  chatId: string;
  chatTitle?: string;
  eventType: "chat_created" | "chat_updated" | "chat_deleted";
  createdAt?: string;
  updatedAt: string;
}

/**
 * Create a registry event for chat metadata tracking.
 */
export async function createRegistryEvent(
  actorId: string,
  chatId: string,
  title: string,
  eventType: RegistryEventData["eventType"],
  createdAt?: string,
): Promise<void> {
  const now = new Date().toISOString();
  const data: RegistryEventData = {
    chatId,
    chatTitle: eventType === "chat_deleted" ? undefined : title,
    eventType,
    createdAt: createdAt || now,
    updatedAt: now,
  };

  await memoryClient.send(
    new CreateEventCommand({
      memoryId: MEMORY_ID,
      actorId,
      sessionId: CHAT_REGISTRY_SESSION,
      eventTimestamp: new Date(),
      payload: [
        {
          blob: JSON.stringify(data),  // MUST be a JSON string, NOT a plain object
        },
      ],
    }),
  );
}

/**
 * Get the list of active chats from the registry session.
 * Deduplicates by chatId (latest event wins), filters out deleted.
 */
export async function getChatList(
  actorId: string,
): Promise<Array<{ id: string; title: string; createdAt: string; updatedAt: string }>> {
  const events = await getSessionEvents(actorId, CHAT_REGISTRY_SESSION);

  const chatMap = new Map<string, RegistryEventData>();
  for (const event of events) {
    try {
      let data: RegistryEventData | null = null;
      if (!event.payload || !Array.isArray(event.payload)) continue;

      for (const p of event.payload) {
        if (p.blob != null) {
          const blob = p.blob;
          if (typeof blob === "string") {
            // Try JSON first, fall back to Java Map.toString() format
            try {
              data = JSON.parse(blob);
            } catch {
              const parsed = parseJavaMapString(blob);
              if (parsed.chatId) {
                data = {
                  chatId: parsed.chatId,
                  chatTitle: parsed.chatTitle,
                  eventType: parsed.eventType as RegistryEventData["eventType"],
                  createdAt: parsed.createdAt,
                  updatedAt: parsed.updatedAt,
                };
              }
            }
          } else if (blob instanceof Uint8Array || Buffer.isBuffer(blob)) {
            const decoded = new TextDecoder().decode(blob);
            try {
              data = JSON.parse(decoded);
            } catch {
              const parsed = parseJavaMapString(decoded);
              if (parsed.chatId) {
                data = {
                  chatId: parsed.chatId,
                  chatTitle: parsed.chatTitle,
                  eventType: parsed.eventType as RegistryEventData["eventType"],
                  createdAt: parsed.createdAt,
                  updatedAt: parsed.updatedAt,
                };
              }
            }
          } else if (typeof blob === "object" && blob.chatId) {
            data = blob as RegistryEventData;
          }
          break;
        }
      }

      if (data && data.chatId) {
        chatMap.set(data.chatId, data);
      }
    } catch {
      // Skip malformed events
    }
  }

  const chats: Array<{ id: string; title: string; createdAt: string; updatedAt: string }> = [];
  for (const data of chatMap.values()) {
    if (data.eventType !== "chat_deleted") {
      chats.push({
        id: data.chatId,
        title: data.chatTitle || "New Chat",
        createdAt: data.createdAt || data.updatedAt,
        updatedAt: data.updatedAt,
      });
    }
  }

  chats.sort((a, b) => new Date(b.updatedAt).getTime() - new Date(a.updatedAt).getTime());
  return chats;
}
```
