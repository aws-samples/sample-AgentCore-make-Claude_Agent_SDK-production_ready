import { query } from "@anthropic-ai/claude-agent-sdk";

const SYSTEM_PROMPT = `You are a helpful AI assistant. You can help users with a wide variety of tasks including:
- Answering questions
- Writing and editing text
- Coding and debugging
- Analysis and research
- Creative tasks

Be concise but thorough in your responses.`;

type UserMessage = {
  type: "user";
  message: { role: "user"; content: string };
};

// Simple async queue - messages go in via push(), come out via async iteration
class MessageQueue {
  private messages: UserMessage[] = [];
  private waiting: ((msg: UserMessage) => void) | null = null;
  private closed = false;

  push(content: string) {
    const msg: UserMessage = {
      type: "user",
      message: {
        role: "user",
        content,
      },
    };

    if (this.waiting) {
      // Someone is waiting for a message - give it to them
      this.waiting(msg);
      this.waiting = null;
    } else {
      // No one waiting - queue it
      this.messages.push(msg);
    }
  }

  async *[Symbol.asyncIterator](): AsyncIterableIterator<UserMessage> {
    while (!this.closed) {
      if (this.messages.length > 0) {
        yield this.messages.shift()!;
      } else {
        // Wait for next message
        yield await new Promise<UserMessage>((resolve) => {
          this.waiting = resolve;
        });
      }
    }
  }

  close() {
    this.closed = true;
  }
}

export class AgentSession {
  private queue = new MessageQueue();
  private outputIterator: AsyncIterator<any> | null = null;
  public readonly sessionId: string | undefined;

  constructor(sessionId?: string, conversationHistory?: Array<{role: string, content: string}>, ltmContext?: string[]) {
    this.sessionId = sessionId;

    // Build system prompt with bounded context sections
    let systemPrompt = SYSTEM_PROMPT;

    // LTM: cross-session semantic context (top-k records)
    if (ltmContext && ltmContext.length > 0) {
      systemPrompt += `\n\nRelevant context from previous conversations:\n${ltmContext.map(r => `- ${r}`).join('\n')}`;
    }

    // STM: recent conversation turns (bounded, not full history)
    if (conversationHistory && conversationHistory.length > 0) {
      const historyText = conversationHistory
        .map(m => `${m.role === 'user' ? 'User' : 'Assistant'}: ${m.content}`)
        .join('\n');
      systemPrompt += `\n\nRecent conversation:\n\n${historyText}`;
    }

    // Start the query immediately with the queue as input
    // Cast to any - SDK accepts simpler message format at runtime
    const options: any = {
      maxTurns: 100,
      model: process.env.ANTHROPIC_MODEL || "opus",
      allowedTools: [
        "Bash",
        "Read",
        "Write",
        "Edit",
        "Glob",
        "Grep",
        "WebSearch",
        "WebFetch",
      ],
      systemPrompt,
      allowDangerouslySkipPermissions: true,
      env: process.env,
    };

    console.log(`[AgentSession] Creating new session (chat: ${sessionId || "none"}, history: ${conversationHistory?.length || 0} messages)`);

    this.outputIterator = query({
      prompt: this.queue as any,
      options,
    })[Symbol.asyncIterator]();
  }

  // Send a message to the agent
  sendMessage(content: string) {
    this.queue.push(content);
  }

  // Get the output stream
  async *getOutputStream() {
    if (!this.outputIterator) {
      throw new Error("Session not initialized");
    }
    while (true) {
      const { value, done } = await this.outputIterator.next();
      if (done) break;
      yield value;
    }
  }

  close() {
    this.queue.close();
  }
}
