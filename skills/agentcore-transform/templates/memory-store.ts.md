# Template: memory-store.ts

Async store backed by AgentCore Memory, replacing the original in-memory store.

Adapt by matching the original store's method signatures and adding `actorId`
as the first parameter to each method.

```typescript
/**
 * MemoryStore — async drop-in replacement for the original store,
 * backed by AgentCore Memory.
 *
 * All methods are async and require an actorId parameter (user identity).
 * STM sessions store conversation events; a dedicated registry session
 * tracks chat metadata.
 */

import { v4 as uuidv4 } from "uuid";
// ADAPT: import your Chat and ChatMessage types
import type { Chat, ChatMessage } from "./types.js";
import {
  addMessageEvent,
  getSessionEvents,
  eventsToMessages,
  createRegistryEvent,
  getChatList,
} from "./memory-client.js";

class MemoryStore {
  async createChat(actorId: string, title?: string): Promise<Chat> {
    const id = uuidv4();
    const now = new Date().toISOString();
    const chatTitle = title || "New Chat";

    await createRegistryEvent(actorId, id, chatTitle, "chat_created", now);

    return { id, title: chatTitle, createdAt: now, updatedAt: now };
  }

  async getChat(actorId: string, id: string): Promise<Chat | undefined> {
    const chats = await getChatList(actorId);
    return chats.find((c) => c.id === id);
  }

  async getAllChats(actorId: string): Promise<Chat[]> {
    return getChatList(actorId);
  }

  async updateChatTitle(actorId: string, id: string, title: string): Promise<Chat | undefined> {
    const chat = await this.getChat(actorId, id);
    if (!chat) return undefined;

    await createRegistryEvent(actorId, id, title, "chat_updated", chat.createdAt);

    return { ...chat, title, updatedAt: new Date().toISOString() };
  }

  async deleteChat(actorId: string, id: string): Promise<boolean> {
    const chat = await this.getChat(actorId, id);
    if (!chat) return false;

    await createRegistryEvent(actorId, id, "", "chat_deleted");
    return true;
  }

  async ensureChat(actorId: string, chatId: string, title?: string): Promise<Chat> {
    const existing = await this.getChat(actorId, chatId);
    if (existing) return existing;

    const now = new Date().toISOString();
    const chatTitle = title || "New Chat";
    await createRegistryEvent(actorId, chatId, chatTitle, "chat_created", now);
    return { id: chatId, title: chatTitle, createdAt: now, updatedAt: now };
  }

  async addMessage(
    actorId: string,
    chatId: string,
    message: { role: "user" | "assistant"; content: string },
  ): Promise<ChatMessage> {
    // Ensure chat exists in registry
    await this.ensureChat(actorId, chatId);

    // Write event to STM
    await addMessageEvent(actorId, chatId, message.role, message.content);

    const now = new Date().toISOString();

    // Auto-generate title from first user message
    if (message.role === "user") {
      const chat = await this.getChat(actorId, chatId);
      if (chat && chat.title === "New Chat") {
        const autoTitle = message.content.slice(0, 50) + (message.content.length > 50 ? "..." : "");
        await createRegistryEvent(actorId, chatId, autoTitle, "chat_updated", chat.createdAt);
      }
    }

    // Update chat's updatedAt
    const chat = await this.getChat(actorId, chatId);
    if (chat) {
      await createRegistryEvent(actorId, chatId, chat.title, "chat_updated", chat.createdAt);
    }

    return {
      id: uuidv4(),
      chatId,
      timestamp: now,
      ...message,
    };
  }

  async getMessages(actorId: string, chatId: string): Promise<ChatMessage[]> {
    const events = await getSessionEvents(actorId, chatId);
    return eventsToMessages(events, chatId);
  }
}

export const memoryStore = new MemoryStore();
```
