/**
 * Feature-flag router for storage backend.
 *
 * When AGENTCORE_MEMORY_ID is set, delegates to MemoryStore (persistent, multi-container).
 * Otherwise falls back to the in-memory ChatStore (local dev).
 */

import { chatStore } from "./chat-store.js";
import { memoryStore } from "./memory-store.js";

export const useMemory = !!process.env.AGENTCORE_MEMORY_ID;

export const store = useMemory ? memoryStore : chatStore;
