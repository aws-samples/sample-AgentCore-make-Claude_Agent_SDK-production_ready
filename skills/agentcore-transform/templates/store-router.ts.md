# Template: store.ts

Feature-flag router for storage backend.

This module is the single import point for storage. It selects between
the Memory-backed store and the original local store based on an
environment variable.

```typescript
/**
 * Feature-flag router for storage backend.
 *
 * When AGENTCORE_MEMORY_ID is set, delegates to MemoryStore (persistent).
 * Otherwise falls back to the original in-memory store (local dev).
 */

// ADAPT: update import paths to match your project structure
import { chatStore } from "./chat-store.js";       // original store
import { memoryStore } from "./memory-store.js";    // new Memory-backed store

export const useMemory = !!process.env.AGENTCORE_MEMORY_ID;

export const store = useMemory ? memoryStore : chatStore;
```

## Usage Pattern

All callers import `store` and `useMemory`, then branch on the flag
because the Memory store requires an extra `actorId` parameter:

```typescript
import { store, useMemory } from "./store.js";

// In a route handler:
const chats = useMemory
  ? await (store as any).getAllChats(actorId)
  : (store as any).getAllChats();
```

The `as any` cast handles the signature difference cleanly without
needing complex union types. This is a pragmatic tradeoff — the
feature flag guarantees the correct overload is called at runtime.
