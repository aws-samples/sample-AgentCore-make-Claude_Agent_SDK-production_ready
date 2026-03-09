# Template: store.py

Feature-flag router for storage backend (Python).

```python
"""
Feature-flag router for storage backend.

When AGENTCORE_MEMORY_ID is set, delegates to MemoryStore (persistent).
Otherwise falls back to the original in-memory store (local dev).
"""

import os

# ADAPT: update import paths to match your project structure
from chat_store import chat_store       # original store
from memory_store import memory_store   # new Memory-backed store

use_memory = bool(os.environ.get("AGENTCORE_MEMORY_ID"))

store = memory_store if use_memory else chat_store
```

## Usage Pattern

All callers import `store` and `use_memory`, then branch:

```python
from store import store, use_memory

# In a route handler:
if use_memory:
    chats = store.get_all_chats(actor_id)
else:
    chats = store.get_all_chats()
```
