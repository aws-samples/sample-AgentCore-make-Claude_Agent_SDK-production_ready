import { useState, useEffect, useCallback } from "react";
import useWebSocket, { ReadyState } from "react-use-websocket";
import { ChatList } from "./components/ChatList";
import { ChatWindow } from "./components/ChatWindow";
import { LoginModal } from "./components/LoginModal";
import { NewChatModal } from "./components/NewChatModal";

interface Chat {
  id: string;
  title: string;
  createdAt: string;
  updatedAt: string;
}

interface Message {
  id: string;
  role: "user" | "assistant" | "tool_use";
  content: string;
  timestamp: string;
  toolName?: string;
  toolInput?: Record<string, any>;
}

// Use environment variables or defaults for development
// VITE_API_BASE: AgentCore Runtime endpoint (e.g., https://bedrock-agentcore.us-east-1.amazonaws.com/runtimes/{arn})
const API_BASE = import.meta.env.VITE_API_BASE || "http://localhost:8080";
const WS_BASE = import.meta.env.VITE_WS_BASE || `ws://localhost:8080`;
const COGNITO_POOL_ID = import.meta.env.VITE_COGNITO_POOL_ID || "";
const COGNITO_CLIENT_ID = import.meta.env.VITE_COGNITO_CLIENT_ID || "";
const AWS_REGION = COGNITO_POOL_ID.split("_")[0] || "us-east-1";

export default function App() {
  const [chats, setChats] = useState<Chat[]>([]);
  const [selectedChatId, setSelectedChatId] = useState<string | null>(null);
  const [messages, setMessages] = useState<Message[]>([]);
  const [isLoading, setIsLoading] = useState(false);

  // Authentication state
  const [isAuthenticated, setIsAuthenticated] = useState(false);
  const [authToken, setAuthToken] = useState<string | null>(null);
  const [loginError, setLoginError] = useState<string>();

  // UI state
  const [showNewChatModal, setShowNewChatModal] = useState(false);

  // Check for stored token on mount
  useEffect(() => {
    const storedToken = localStorage.getItem("authToken");
    if (storedToken) {
      setAuthToken(storedToken);
      setIsAuthenticated(true);
    }
  }, []);

  // Login handler using Cognito InitiateAuth API
  const handleLogin = async (username: string, password: string) => {
    setLoginError(undefined);

    try {
      // Use Cognito InitiateAuth API (USER_PASSWORD_AUTH flow)
      const cognitoEndpoint = `https://cognito-idp.${AWS_REGION}.amazonaws.com/`;
      const response = await fetch(cognitoEndpoint, {
        method: "POST",
        headers: {
          "Content-Type": "application/x-amz-json-1.1",
          "X-Amz-Target": "AWSCognitoIdentityProviderService.InitiateAuth",
        },
        body: JSON.stringify({
          AuthFlow: "USER_PASSWORD_AUTH",
          ClientId: COGNITO_CLIENT_ID,
          AuthParameters: {
            USERNAME: username,
            PASSWORD: password,
          },
        }),
      });

      if (!response.ok) {
        const errorData = await response.json().catch(() => ({}));
        throw new Error(errorData.message || "Authentication failed");
      }

      const data = await response.json();
      const token = data.AuthenticationResult?.IdToken;

      if (!token) {
        throw new Error("No ID token received");
      }

      // Store token
      localStorage.setItem("authToken", token);
      setAuthToken(token);
      setIsAuthenticated(true);
    } catch (error) {
      console.error("Login error:", error);
      setLoginError(error instanceof Error ? error.message : "Invalid username or password");
      throw error;
    }
  };

  // Logout handler
  const handleLogout = () => {
    localStorage.removeItem("authToken");
    setAuthToken(null);
    setIsAuthenticated(false);
    setChats([]);
    setSelectedChatId(null);
    setMessages([]);
  };

  // WebSocket URL via local proxy that bridges to AgentCore
  // Browser → ws-proxy (token in query param) → AgentCore (token in Authorization header)
  // Include sessionId so AgentCore routes to the same container for session affinity
  const wsUrl = authToken && selectedChatId
    ? `${WS_BASE}/ws?token=${authToken}&sessionId=${encodeURIComponent(selectedChatId)}`
    : null;

  // Handle WebSocket messages
  const handleWSMessage = useCallback((message: any) => {
    switch (message.type) {
      case "connected":
        console.log("Connected to server");
        break;

      case "history":
        setMessages(message.messages || []);
        break;

      case "user_message":
        // User message already added locally
        break;

      case "assistant_message":
        setMessages((prev) => [
          ...prev,
          {
            id: crypto.randomUUID(),
            role: "assistant",
            content: message.content,
            timestamp: new Date().toISOString(),
          },
        ]);
        setIsLoading(false);
        break;

      case "tool_use":
        setMessages((prev) => [
          ...prev,
          {
            id: message.toolId,
            role: "tool_use",
            content: "",
            timestamp: new Date().toISOString(),
            toolName: message.toolName,
            toolInput: message.toolInput,
          },
        ]);
        break;

      case "result":
        setIsLoading(false);
        // Refresh chat list to get updated titles
        fetchChats();
        break;

      case "error":
        console.error("Server error:", message.error);
        setIsLoading(false);
        break;
    }
  }, []);

  const { sendJsonMessage, readyState, lastJsonMessage } = useWebSocket(wsUrl, {
    shouldReconnect: () => isAuthenticated,
    reconnectAttempts: 10,
    reconnectInterval: 3000,
  });

  const isConnected = readyState === ReadyState.OPEN;

  // Handle incoming WebSocket messages
  useEffect(() => {
    if (lastJsonMessage) {
      handleWSMessage(lastJsonMessage);
    }
  }, [lastJsonMessage, handleWSMessage]);

  // Auto-subscribe when WebSocket connects (connection is per-session via sessionId in URL)
  useEffect(() => {
    if (isConnected && selectedChatId) {
      sendJsonMessage({ type: "subscribe", chatId: selectedChatId });
    }
  }, [isConnected, selectedChatId]);

  // Helper to get auth headers, optionally with AgentCore session ID
  const getAuthHeaders = (runtimeSessionId?: string) => ({
    "Content-Type": "application/json",
    ...(authToken ? { Authorization: `Bearer ${authToken}` } : {}),
    ...(runtimeSessionId
      ? { "X-Amzn-Bedrock-AgentCore-Runtime-Session-Id": runtimeSessionId }
      : {}),
  });

  // Fetch all chats via /invocations
  const fetchChats = async () => {
    if (!isAuthenticated) return;

    try {
      const res = await fetch(`${API_BASE}/invocations?qualifier=DEFAULT`, {
        method: "POST",
        headers: getAuthHeaders(),
        body: JSON.stringify({
          input: {
            method: "GET",
            path: "/api/chats",
          },
        }),
      });

      const data = await res.json();
      if (data.output?.statusCode === 200) {
        setChats(data.output.body);
      } else {
        console.error("Failed to fetch chats:", data);
      }
    } catch (error) {
      console.error("Failed to fetch chats:", error);
    }
  };

  // Create new chat with custom session ID
  const createChatWithSessionId = async (sessionId: string, title?: string) => {
    try {
      const res = await fetch(`${API_BASE}/invocations?qualifier=DEFAULT`, {
        method: "POST",
        headers: getAuthHeaders(sessionId),
        body: JSON.stringify({
          input: {
            method: "POST",
            path: "/api/chats",
            body: { title },
            sessionId,
          },
        }),
      });

      const data = await res.json();
      if (data.output?.statusCode === 201 || data.output?.statusCode === 200) {
        const chat = data.output.body;
        setChats((prev) => [chat, ...prev]);
        selectChat(chat.id);
      } else {
        console.error("Failed to create chat:", data);
      }
    } catch (error) {
      console.error("Failed to create chat:", error);
    }
  };

  // Delete chat
  const deleteChat = async (chatId: string) => {
    try {
      const res = await fetch(`${API_BASE}/invocations?qualifier=DEFAULT`, {
        method: "POST",
        headers: getAuthHeaders(chatId),
        body: JSON.stringify({
          input: {
            method: "DELETE",
            path: `/api/chats/${chatId}`,
          },
        }),
      });

      const data = await res.json();
      if (data.output?.statusCode === 200) {
        setChats((prev) => prev.filter((c) => c.id !== chatId));
        if (selectedChatId === chatId) {
          setSelectedChatId(null);
          setMessages([]);
        }
      }
    } catch (error) {
      console.error("Failed to delete chat:", error);
    }
  };

  // Select a chat — triggers WS reconnection with sessionId for AgentCore routing
  const selectChat = (chatId: string) => {
    setSelectedChatId(chatId);
    setMessages([]);
    setIsLoading(false);
    // Subscribe is handled by the useEffect that watches isConnected + selectedChatId.
    // Changing selectedChatId changes the WS URL, which triggers a reconnection
    // with the correct sessionId for AgentCore session affinity.
  };

  // Send a message
  const handleSendMessage = (content: string) => {
    if (!selectedChatId || !isConnected) return;

    // Add message optimistically
    setMessages((prev) => [
      ...prev,
      {
        id: crypto.randomUUID(),
        role: "user",
        content,
        timestamp: new Date().toISOString(),
      },
    ]);

    setIsLoading(true);

    // Send via WebSocket with sessionId
    sendJsonMessage({
      type: "chat",
      content,
      chatId: selectedChatId,
      sessionId: selectedChatId, // Use chatId as sessionId
    });
  };

  // Initial fetch when authenticated
  useEffect(() => {
    if (isAuthenticated) {
      fetchChats();
    }
  }, [isAuthenticated]);

  // Show login modal if not authenticated
  if (!isAuthenticated) {
    return (
      <div className="flex h-screen items-center justify-center bg-gray-50">
        <LoginModal isOpen={true} onLogin={handleLogin} error={loginError} />
      </div>
    );
  }

  return (
    <div className="flex h-screen">
      {/* Sidebar */}
      <div className="w-64 shrink-0">
        <ChatList
          chats={chats}
          selectedChatId={selectedChatId}
          onSelectChat={selectChat}
          onNewChat={() => setShowNewChatModal(true)}
          onDeleteChat={deleteChat}
        />
      </div>

      {/* Main chat area */}
      <ChatWindow
        chatId={selectedChatId}
        messages={messages}
        isConnected={isConnected}
        isLoading={isLoading}
        onSendMessage={handleSendMessage}
      />

      {/* New Chat Modal */}
      <NewChatModal
        isOpen={showNewChatModal}
        onClose={() => setShowNewChatModal(false)}
        onCreate={createChatWithSessionId}
      />

      {/* Logout button (optional, for demo) */}
      <button
        onClick={handleLogout}
        className="fixed bottom-4 right-4 px-4 py-2 bg-red-600 text-white rounded-lg hover:bg-red-700 transition-colors text-sm"
      >
        Logout
      </button>
    </div>
  );
}
