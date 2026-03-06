/**
 * AgentCore Memory SDK wrapper
 *
 * All STM (Short-Term Memory) and LTM (Long-Term Memory) operations go through here.
 * STM stores verbatim conversation events; LTM stores auto-extracted semantic records.
 *
 * SDK type reference (from @aws-sdk/client-bedrock-agentcore):
 *   CreateEventInput.payload: PayloadType[]  (array, not object)
 *   PayloadType.ConversationalMember: { conversational: { content: { text }, role } }
 *   PayloadType.BlobMember: { blob: any }
 *   ListEventsInput: requires includePayloads: true to get payload data
 *   Event.payload: PayloadType[]
 *   RetrieveMemoryRecordsInput: { namespace, searchCriteria: { searchQuery, topK } }
 *   RetrieveMemoryRecordsOutput: { memoryRecordSummaries: [{ content: { text } }] }
 *   StartMemoryExtractionJobInput: { memoryId, extractionJob: { jobId } }
 */

import {
  BedrockAgentCoreClient,
  CreateEventCommand,
  ListEventsCommand,
  RetrieveMemoryRecordsCommand,
} from "@aws-sdk/client-bedrock-agentcore";
import { v4 as uuidv4 } from "uuid";
import type { ChatMessage } from "./types.js";

// Singleton client — uses IAM execution role from container
const region = process.env.AWS_REGION || "us-east-1";
export const memoryClient = new BedrockAgentCoreClient({ region });
export const MEMORY_ID = process.env.AGENTCORE_MEMORY_ID!;

// Registry session ID for chat metadata
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
        // MemoryContent is a union type with TextMember
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
 * Trigger asynchronous LTM extraction after a conversation.
 *
 * NOTE: Extraction happens automatically when conversational events are added
 * to a memory with configured strategies. The StartMemoryExtractionJobCommand
 * requires an existing jobId (for retrying failed jobs), not a new one.
 * This function is kept as a no-op placeholder; auto-extraction handles LTM.
 */
export async function triggerExtraction(
  actorId: string,
  sessionId: string,
): Promise<void> {
  // Extraction is automatic — no manual trigger needed.
  // The semantic strategy processes new events asynchronously.
  console.log(`[Memory] Auto-extraction will process events for actor=${actorId} session=${sessionId}`);
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
 * Uses blob payload to store JSON metadata.
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
          blob: JSON.parse(JSON.stringify(data)),
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

  // Build map: chatId → latest registry event data
  const chatMap = new Map<string, RegistryEventData>();
  for (const event of events) {
    try {
      let data: RegistryEventData | null = null;

      if (!event.payload || !Array.isArray(event.payload)) continue;

      for (const p of event.payload) {
        if (p.blob) {
          // blob comes back as a parsed object (DocumentType) or a string
          if (typeof p.blob === "string") {
            data = JSON.parse(p.blob);
          } else if (p.blob instanceof Uint8Array) {
            data = JSON.parse(new TextDecoder().decode(p.blob));
          } else {
            // Already a parsed object (DocumentType)
            data = p.blob as RegistryEventData;
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

  // Filter out deleted chats and convert to Chat format
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

  // Sort by updatedAt descending
  chats.sort((a, b) => new Date(b.updatedAt).getTime() - new Date(a.updatedAt).getTime());
  return chats;
}
