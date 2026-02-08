# Simple Chat App - Architecture Documentation

## Architecture Overview

This is a full-stack chat application with React frontend, Node.js/Express backend, and Claude Agent SDK integration.

### Technology Stack
- **Frontend**: React 18 + TypeScript + Vite + Tailwind CSS
- **Backend**: Node.js + Express + WebSocket (ws library)
- **AI Engine**: Claude Agent SDK (Anthropic)
- **Data**: In-memory storage (no database)

---

## Layer Architecture Explained

This application is built on three distinct layers, each with specific responsibilities:

### **Layer 1: Claude Model API (Anthropic API)**
- **What**: The underlying REST API provided by Anthropic that powers Claude models
- **Responsibility**: Processes messages and returns AI-generated responses with tool use capabilities
- **Communication**: HTTPS requests/responses with streaming support
- **Location**: Remote service at `api.anthropic.com`
- **Used by**: Claude Agent SDK

### **Layer 2: Claude Agent SDK**
- **What**: Official SDK from Anthropic (`@anthropic-ai/claude-agent-sdk`) that wraps the Claude API
- **Responsibility**:
  - Abstracts API calls into high-level `query()` function
  - Manages multi-turn conversations and tool execution loops
  - Provides async iterator interface for streaming responses
  - Handles tool execution (Bash, Read, Write, Edit, Glob, Grep, WebSearch, WebFetch)
- **Key Features**:
  - Automatic tool calling and result handling
  - Conversation context management
  - Streaming response support via async generators
- **Used by**: Application's `AgentSession` class in [server/ai-client.ts](server/ai-client.ts)

### **Layer 3: Application Level Modules (Chat App)**
- **What**: Custom application code that implements the chat interface
- **Responsibility**: Business logic, data persistence, and user interface
- **Key Modules**:
  - **Frontend** ([client/](client/)): React UI for chat interface
    - `App.tsx` - Main state management and API orchestration
    - `ChatList.tsx` - Chat list sidebar component
    - `ChatWindow.tsx` - Message display and input component
  - **Backend** ([server/](server/)): Express server with WebSocket support
    - `server.ts` - HTTP/WebSocket server, routing, and connection management
    - `session.ts` - Chat session orchestration, bridges WebSocket ↔ SDK
    - `ai-client.ts` - Wraps Claude Agent SDK with message queue pattern
    - `chat-store.ts` - In-memory data persistence (chats & messages)
    - `types.ts` - TypeScript type definitions

### **Data Flow Across Layers**

```
┌─────────────────────────────────────────────────────────────┐
│  Layer 3: Application Level (Chat App)                      │
│                                                              │
│  Frontend (React)                                            │
│    ↕ HTTP REST API (chat CRUD)                              │
│    ↕ WebSocket (real-time messaging)                        │
│  Backend (Express + WebSocket)                              │
│    ├─ Server (routing & connections)                        │
│    ├─ Session (conversation management)                     │
│    ├─ ChatStore (data persistence)                          │
│    └─ ai-client.ts (SDK wrapper)                            │
│         ↓                                                    │
└─────────┼────────────────────────────────────────────────────┘
          │ query() function call with MessageQueue
          ↓
┌─────────────────────────────────────────────────────────────┐
│  Layer 2: Claude Agent SDK                                   │
│                                                              │
│  @anthropic-ai/claude-agent-sdk                              │
│    ├─ query() API - high-level agent interface              │
│    ├─ Conversation management (multi-turn)                  │
│    ├─ Tool execution loop                                   │
│    └─ Async iterator for streaming                          │
│         ↓                                                    │
└─────────┼────────────────────────────────────────────────────┘
          │ HTTPS API calls (Messages API + streaming)
          ↓
┌─────────────────────────────────────────────────────────────┐
│  Layer 1: Claude Model API (Anthropic)                       │
│                                                              │
│  api.anthropic.com                                           │
│    ├─ Claude Opus 4 model                                   │
│    ├─ Messages API endpoint                                 │
│    ├─ Tool use / function calling                           │
│    └─ Server-sent events (SSE) streaming                    │
└─────────────────────────────────────────────────────────────┘
```

**Key Interactions**:
1. User sends message via **Frontend** WebSocket → **Backend** Session
2. Session calls `AgentSession.sendMessage()` → pushes to **MessageQueue**
3. MessageQueue feeds messages to **Claude Agent SDK's** `query()` function
4. SDK makes API calls to **Claude Model API** (Layer 1)
5. Claude API returns streaming responses with tool uses
6. SDK executes tools (e.g., Bash, Read files) and sends results back to API
7. SDK yields final response via async iterator
8. Backend Session receives response and broadcasts via **WebSocket**
9. **Frontend** displays messages in real-time

---

## Dependencies Tree & API Communication Flow

### **Frontend Architecture** ([client/](client/))

```
index.tsx (Entry Point)
  └── App.tsx (Main Component)
       ├── State Management
       │    ├── chats: Chat[]
       │    ├── selectedChatId: string
       │    ├── messages: Message[]
       │    └── isLoading: boolean
       │
       ├── WebSocket Hook (react-use-websocket)
       │    └── ws://localhost:3001/ws
       │         ├── SEND: { type: "subscribe", chatId }
       │         ├── SEND: { type: "chat", content, chatId }
       │         └── RECEIVE:
       │              ├── { type: "connected" }
       │              ├── { type: "history", messages }
       │              ├── { type: "user_message", content }
       │              ├── { type: "assistant_message", content }
       │              ├── { type: "tool_use", toolName, toolInput }
       │              ├── { type: "result", success, cost, duration }
       │              └── { type: "error", error }
       │
       ├── REST API Calls
       │    ├── GET /api/chats → fetchChats()
       │    ├── POST /api/chats → createChat()
       │    ├── DELETE /api/chats/:id → deleteChat()
       │    └── (implicitly) GET /api/chats/:id/messages
       │
       ├── ChatList.tsx (Sidebar)
       │    ├── Props: chats, selectedChatId
       │    ├── Events: onSelectChat, onNewChat, onDeleteChat
       │    └── UI: Chat list + New chat button
       │
       └── ChatWindow.tsx (Main Chat)
            ├── Props: chatId, messages, isConnected, isLoading
            ├── Events: onSendMessage
            └── Components:
                 ├── MessageBubble (User/Assistant messages)
                 └── ToolUseBlock (Tool execution display)
```

---

### **Backend Architecture** ([server/](server/))

```
server.ts (Entry Point)
  │
  ├── Express App (Port 3001)
  │    ├── Middleware: cors, express.json()
  │    └── REST API Endpoints:
  │         ├── GET /api/chats
  │         │    └── chatStore.getAllChats()
  │         │
  │         ├── POST /api/chats
  │         │    └── chatStore.createChat(title)
  │         │
  │         ├── GET /api/chats/:id
  │         │    └── chatStore.getChat(id)
  │         │
  │         ├── DELETE /api/chats/:id
  │         │    ├── chatStore.deleteChat(id)
  │         │    ├── session.close()
  │         │    └── sessions.delete(id)
  │         │
  │         └── GET /api/chats/:id/messages
  │              └── chatStore.getMessages(id)
  │
  ├── WebSocket Server (/ws path)
  │    ├── Connection Handler
  │    │    └── SEND: { type: "connected" }
  │    │
  │    ├── Message Handlers:
  │    │    ├── "subscribe" →
  │    │    │    ├── getOrCreateSession(chatId)
  │    │    │    ├── session.subscribe(ws)
  │    │    │    └── SEND: { type: "history", messages }
  │    │    │
  │    │    └── "chat" →
  │    │         ├── getOrCreateSession(chatId)
  │    │         ├── session.subscribe(ws)
  │    │         └── session.sendMessage(content)
  │    │
  │    └── Heartbeat Mechanism (30s ping/pong)
  │
  └── Session Management
       └── sessions: Map<chatId, Session>
            └── getOrCreateSession(chatId)

session.ts (Session Manager)
  │
  ├── Constructor
  │    └── new AgentSession()
  │
  ├── sendMessage(content)
  │    ├── chatStore.addMessage(chatId, userMessage)
  │    ├── broadcast({ type: "user_message" })
  │    ├── agentSession.sendMessage(content)
  │    └── startListening() [one-time]
  │
  ├── startListening() [async loop]
  │    └── for await (message of agentSession.getOutputStream())
  │         └── handleSDKMessage(message)
  │              ├── "assistant" message →
  │              │    ├── chatStore.addMessage(chatId, assistantMessage)
  │              │    ├── broadcast({ type: "assistant_message" })
  │              │    └── broadcast({ type: "tool_use" }) [if tool_use blocks]
  │              │
  │              └── "result" message →
  │                   └── broadcast({ type: "result" })
  │
  ├── subscribe(ws) / unsubscribe(ws)
  │    └── subscribers: Set<WSClient>
  │
  └── broadcast(message)
       └── Send to all subscribed WebSocket clients

ai-client.ts (Claude Agent SDK Wrapper)
  │
  ├── MessageQueue
  │    ├── messages: UserMessage[]
  │    ├── push(content) → Queue message
  │    └── [Symbol.asyncIterator] → Async iteration
  │
  └── AgentSession
       ├── Constructor
       │    └── query({
       │         prompt: MessageQueue,
       │         options: {
       │           maxTurns: 100,
       │           model: "opus",
       │           allowedTools: ["Bash", "Read", "Write", "Edit",
       │                          "Glob", "Grep", "WebSearch", "WebFetch"],
       │           systemPrompt: SYSTEM_PROMPT
       │         }
       │       })
       │
       ├── sendMessage(content)
       │    └── queue.push(content)
       │
       ├── getOutputStream() [async generator]
       │    └── Yields messages from Claude API:
       │         ├── { type: "assistant", message: { content } }
       │         └── { type: "result", subtype, total_cost_usd, duration_ms }
       │
       └── close()
            └── queue.close()

chat-store.ts (In-Memory Data Store)
  │
  ├── chats: Map<id, Chat>
  ├── messages: Map<chatId, ChatMessage[]>
  │
  ├── createChat(title) → Chat
  ├── getChat(id) → Chat | undefined
  ├── getAllChats() → Chat[] (sorted by updatedAt)
  ├── updateChatTitle(id, title) → Chat
  ├── deleteChat(id) → boolean
  ├── addMessage(chatId, message) → ChatMessage
  └── getMessages(chatId) → ChatMessage[]

types.ts (Type Definitions)
  ├── WSClient extends WebSocket
  ├── Chat { id, title, createdAt, updatedAt }
  ├── ChatMessage { id, chatId, role, content, timestamp }
  └── IncomingWSMessage: WSChatMessage | WSSubscribeMessage
```

---

## Communication Flow Diagram

### **1. Creating a New Chat**
```
Frontend                    Backend
  │                           │
  │── POST /api/chats ────────>│
  │                           │── chatStore.createChat()
  │<───── { chat } ────────────│
  │                           │
  │── WS: subscribe ──────────>│
  │                           │── getOrCreateSession()
  │                           │── session.subscribe(ws)
  │<─── WS: history ───────────│
```

### **2. Sending a Message**
```
Frontend                    Backend                 Claude SDK
  │                           │                         │
  │── WS: chat ───────────────>│                         │
  │                           │                         │
  │<─── WS: user_message ──────│                         │
  │                           │                         │
  │                           │── chatStore.addMessage()│
  │                           │                         │
  │                           │── session.sendMessage() │
  │                           │                         │
  │                           │── agentSession          │
  │                           │   .sendMessage() ──────>│
  │                           │                         │
  │                           │                         │── query() API call
  │                           │<────── stream ──────────│    to Claude
  │                           │   (async iterator)      │
  │                           │                         │
  │<─── WS: tool_use ──────────│                         │
  │   (if agent uses tools)   │                         │
  │                           │                         │
  │<─── WS: assistant_message ─│                         │
  │                           │                         │
  │<─── WS: result ────────────│                         │
```

### **3. Data Flow Layers**

```
┌─────────────────────────────────────────────────────────┐
│                    FRONTEND LAYER                        │
│  React Components ← WebSocket ← REST API                │
└────────────────────┬────────────────────────────────────┘
                     │ HTTP/WS
                     ↓
┌─────────────────────────────────────────────────────────┐
│                  BACKEND SERVER LAYER                    │
│  Express REST ← WebSocket Server ← Session Manager      │
└────────────────────┬────────────────────────────────────┘
                     │
        ┌────────────┴────────────┐
        ↓                         ↓
┌──────────────────┐    ┌──────────────────────┐
│   DATA LAYER     │    │    AI ENGINE LAYER   │
│                  │    │                      │
│   ChatStore      │    │   AgentSession       │
│   (In-Memory)    │    │   MessageQueue       │
│                  │    │   ↓                  │
│   - chats        │    │   Claude Agent SDK   │
│   - messages     │    │   ↓                  │
│                  │    │   Anthropic API      │
└──────────────────┘    └──────────────────────┘
```

---

## Key Design Patterns

1. **Pub/Sub Pattern**: Session broadcasts to multiple WebSocket subscribers
2. **Singleton Pattern**: chatStore is a singleton instance
3. **Async Iterator Pattern**: MessageQueue and SDK streaming use async iteration
4. **Observer Pattern**: WebSocket clients subscribe/unsubscribe from sessions
5. **Optimistic UI**: Frontend shows user messages immediately before server confirmation

---

## API Endpoint Summary

### REST API (HTTP)
- `GET /api/chats` - List all chats
- `POST /api/chats` - Create new chat
- `GET /api/chats/:id` - Get chat details
- `DELETE /api/chats/:id` - Delete chat + session
- `GET /api/chats/:id/messages` - Get messages

### WebSocket API (ws://localhost:3001/ws)
**Client → Server:**
- `subscribe` - Subscribe to chat updates
- `chat` - Send message to AI

**Server → Client:**
- `connected` - Initial connection
- `history` - Historical messages
- `user_message` - Echo user message
- `assistant_message` - AI response text
- `tool_use` - AI using a tool
- `result` - Query completion
- `error` - Error occurred

---

## File Reference Map

### Frontend Files
- [client/index.tsx](client/index.tsx) - React entry point
- [client/App.tsx](client/App.tsx) - Main app component with state management
- [client/components/ChatList.tsx](client/components/ChatList.tsx) - Chat list sidebar
- [client/components/ChatWindow.tsx](client/components/ChatWindow.tsx) - Chat interface
- [client/globals.css](client/globals.css) - Tailwind CSS styles

### Backend Files
- [server/server.ts](server/server.ts) - Express server and WebSocket setup
- [server/session.ts](server/session.ts) - Session management and message handling
- [server/ai-client.ts](server/ai-client.ts) - Claude Agent SDK wrapper
- [server/chat-store.ts](server/chat-store.ts) - In-memory data storage
- [server/types.ts](server/types.ts) - TypeScript type definitions

### Configuration Files
- [package.json](package.json) - Dependencies and scripts
- [tsconfig.json](tsconfig.json) - TypeScript configuration
- [vite.config.ts](vite.config.ts) - Vite build configuration
- [tailwind.config.js](tailwind.config.js) - Tailwind CSS configuration

---

## Key Implementation Details

### 1. Message Queue Pattern
The `MessageQueue` class in [server/ai-client.ts](server/ai-client.ts:18-58) implements an async iterator that:
- Accepts user messages via `push()`
- Yields them asynchronously to the Claude SDK
- Enables continuous conversation without recreating the agent

### 2. Session Lifecycle
Each chat has a `Session` instance ([server/session.ts](server/session.ts)) that:
- Creates an `AgentSession` on first message
- Maintains multiple WebSocket subscribers
- Streams AI responses back to all subscribers
- Stores messages in `chatStore`

### 3. WebSocket Communication
The WebSocket server in [server/server.ts](server/server.ts:86-158):
- Accepts connections at `/ws` path
- Implements ping/pong heartbeat (30s interval)
- Routes messages to appropriate sessions
- Handles client disconnections gracefully

### 4. Optimistic UI Updates
The frontend ([client/App.tsx](client/App.tsx:156-178)):
- Immediately displays user messages locally
- Shows loading state while waiting for AI
- Updates with streaming tool use notifications
- Refreshes chat list when titles are auto-generated

---

## Development Setup

```bash
# Install dependencies
npm install

# Start development servers (concurrent)
npm run dev

# Backend only
npm run dev:server

# Frontend only
npm run dev:client

# Build for production
npm run build
```

The application runs on:
- Frontend: http://localhost:5173 (Vite dev server)
- Backend: http://localhost:3001 (Express + WebSocket)

---

## Environment Variables

Required in `.env`:
```
ANTHROPIC_API_KEY=your_api_key_here
PORT=3001  # Optional, defaults to 3001
```
