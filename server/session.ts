import type { WSClient } from "./types.js";
import { AgentSession } from "./ai-client.js";
import { store, useMemory } from "./store.js";
import { getRecentTurns, eventsToMessages, searchLTM, triggerExtraction } from "./memory-client.js";

const STM_TURN_LIMIT = 20;
const LTM_TOP_K = 5;

// Session manages a single chat conversation with a long-lived agent
export class Session {
  public readonly chatId: string;
  public readonly actorId: string;
  private subscribers: Set<WSClient> = new Set();
  private agentSession: AgentSession;
  private isListening = false;
  private hasSearchedLTMForFirstMessage = false;

  private constructor(chatId: string, actorId: string, agentSession: AgentSession) {
    this.chatId = chatId;
    this.actorId = actorId;
    this.agentSession = agentSession;
  }

  /**
   * Async factory — loads bounded history from STM and LTM context.
   */
  static async create(chatId: string, actorId: string, sessionId?: string): Promise<Session> {
    let history: Array<{ role: string; content: string }> = [];
    let ltmContext: string[] = [];

    if (useMemory) {
      // Bounded STM: last N turns only
      const recentEvents = await getRecentTurns(actorId, chatId, STM_TURN_LIMIT);
      const messages = eventsToMessages(recentEvents, chatId);
      history = messages
        .filter((m) => m.role === "user" || m.role === "assistant")
        .map((m) => ({ role: m.role, content: m.content }));

      // Always search LTM for cross-session context
      // Use last user message if available, otherwise use a broad query
      const lastUserMsg = [...history].reverse().find((m) => m.role === "user");
      const ltmQuery = lastUserMsg
        ? lastUserMsg.content
        : "user preferences, context, and previous conversations";
      ltmContext = await searchLTM(actorId, ltmQuery, LTM_TOP_K);
    } else {
      // Local dev: chatStore.getMessages is sync and takes only chatId
      const existingMessages = (store as any).getMessages(chatId);
      history = existingMessages
        .filter((m: any) => m.role === "user" || m.role === "assistant")
        .map((m: any) => ({ role: m.role, content: m.content }));
    }

    const agentSession = new AgentSession(sessionId || chatId, history, ltmContext);
    const session = new Session(chatId, actorId, agentSession);
    // If we already had STM history, the initial LTM search was targeted enough
    session.hasSearchedLTMForFirstMessage = history.length > 0;
    return session;
  }

  // Start listening to agent output (call once)
  private async startListening() {
    if (this.isListening) return;
    this.isListening = true;

    try {
      for await (const message of this.agentSession.getOutputStream()) {
        await this.handleSDKMessage(message);
      }
    } catch (error) {
      console.error(`Error in session ${this.chatId}:`, error);
      this.broadcastError((error as Error).message);
    }
  }

  // Send a user message to the agent
  async sendMessage(content: string) {
    // Store user message
    try {
      if (useMemory) {
        await (store as any).addMessage(this.actorId, this.chatId, { role: "user", content });
      } else {
        (store as any).addMessage(this.chatId, { role: "user", content });
      }
    } catch (error) {
      console.error("[Session] Failed to store user message:", error);
    }

    // For the first message in a new chat, do a targeted LTM search and
    // prepend the context so the agent can leverage cross-session memory.
    let messageToSend = content;
    if (useMemory && !this.hasSearchedLTMForFirstMessage) {
      this.hasSearchedLTMForFirstMessage = true;
      try {
        const ltmRecords = await searchLTM(this.actorId, content, LTM_TOP_K);
        if (ltmRecords.length > 0) {
          const ltmBlock = ltmRecords.map((r) => `- ${r}`).join("\n");
          messageToSend = `[System context from previous conversations:\n${ltmBlock}\n]\n\n${content}`;
          console.log(`[Session] Injected ${ltmRecords.length} LTM records into first message for chat ${this.chatId}`);
        }
      } catch (error) {
        console.warn("[Session] LTM search for first message failed:", error);
      }
    }

    // Broadcast user message to subscribers (original content, not augmented)
    this.broadcast({
      type: "user_message",
      content,
      chatId: this.chatId,
    });

    // Send to agent (with LTM-augmented content if applicable)
    this.agentSession.sendMessage(messageToSend);

    // Start listening if not already
    if (!this.isListening) {
      this.startListening();
    }
  }

  private async handleSDKMessage(message: any) {
    if (message.type === "assistant") {
      const content = message.message.content;

      if (typeof content === "string") {
        await this.storeAssistantMessage(content);
        this.broadcast({
          type: "assistant_message",
          content,
          chatId: this.chatId,
        });
      } else if (Array.isArray(content)) {
        for (const block of content) {
          if (block.type === "text") {
            await this.storeAssistantMessage(block.text);
            this.broadcast({
              type: "assistant_message",
              content: block.text,
              chatId: this.chatId,
            });
          } else if (block.type === "tool_use") {
            this.broadcast({
              type: "tool_use",
              toolName: block.name,
              toolId: block.id,
              toolInput: block.input,
              chatId: this.chatId,
            });
          }
        }
      }
    } else if (message.type === "result") {
      this.broadcast({
        type: "result",
        success: message.subtype === "success",
        chatId: this.chatId,
        cost: message.total_cost_usd,
        duration: message.duration_ms,
      });

      // Trigger LTM extraction after conversation turn completes
      if (useMemory) {
        triggerExtraction(this.actorId, this.chatId).catch((err) =>
          console.warn("[Session] LTM extraction trigger failed:", err),
        );
      }
    }
  }

  private async storeAssistantMessage(content: string) {
    try {
      if (useMemory) {
        await (store as any).addMessage(this.actorId, this.chatId, { role: "assistant", content });
      } else {
        (store as any).addMessage(this.chatId, { role: "assistant", content });
      }
    } catch (error) {
      console.error("[Session] Failed to store assistant message:", error);
    }
  }

  subscribe(client: WSClient) {
    this.subscribers.add(client);
    client.sessionId = this.chatId;
  }

  unsubscribe(client: WSClient) {
    this.subscribers.delete(client);
  }

  hasSubscribers(): boolean {
    return this.subscribers.size > 0;
  }

  private broadcast(message: any) {
    const messageStr = JSON.stringify(message);
    for (const client of this.subscribers) {
      try {
        if (client.readyState === client.OPEN) {
          client.send(messageStr);
        }
      } catch (error) {
        console.error("Error broadcasting to client:", error);
        this.subscribers.delete(client);
      }
    }
  }

  private broadcastError(error: string) {
    this.broadcast({
      type: "error",
      error,
      chatId: this.chatId,
    });
  }

  // Close the session
  close() {
    this.agentSession.close();
  }
}
