import React, { useState } from "react";
import { v4 as uuidv4 } from "uuid";

interface NewChatModalProps {
  isOpen: boolean;
  onClose: () => void;
  onCreate: (sessionId: string, title?: string) => void;
}

/**
 * Modal for creating a new chat with custom Session ID
 */
export function NewChatModal({ isOpen, onClose, onCreate }: NewChatModalProps) {
  const [sessionId, setSessionId] = useState(() => uuidv4());
  const [title, setTitle] = useState("");

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    onCreate(sessionId.trim(), title.trim() || undefined);
    // Reset form
    setSessionId(uuidv4());
    setTitle("");
    onClose();
  };

  const handleGenerateNew = () => {
    setSessionId(uuidv4());
  };

  if (!isOpen) return null;

  return (
    <div className="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center z-50">
      <div className="bg-white rounded-lg shadow-xl p-6 w-full max-w-md">
        <h2 className="text-xl font-bold text-gray-800 mb-4">Create New Chat</h2>

        <form onSubmit={handleSubmit} className="space-y-4">
          <div>
            <label htmlFor="title" className="block text-sm font-medium text-gray-700 mb-1">
              Chat Title (Optional)
            </label>
            <input
              type="text"
              id="title"
              value={title}
              onChange={(e) => setTitle(e.target.value)}
              placeholder="New Chat"
              className="w-full px-4 py-2 border border-gray-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent"
            />
          </div>

          <div>
            <label htmlFor="sessionId" className="block text-sm font-medium text-gray-700 mb-1">
              Session ID
            </label>
            <div className="flex gap-2">
              <input
                type="text"
                id="sessionId"
                value={sessionId}
                onChange={(e) => setSessionId(e.target.value)}
                placeholder="Enter or generate Session ID"
                className="flex-1 px-4 py-2 border border-gray-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent font-mono text-sm"
              />
              <button
                type="button"
                onClick={handleGenerateNew}
                className="px-4 py-2 bg-gray-100 text-gray-700 rounded-lg hover:bg-gray-200 transition-colors text-sm font-medium"
                title="Generate new UUID"
              >
                ↻
              </button>
            </div>
            <p className="text-xs text-gray-500 mt-1">
              This Session ID will be used for AgentCore Runtime conversation tracking
            </p>
          </div>

          <div className="flex gap-3 pt-2">
            <button
              type="button"
              onClick={onClose}
              className="flex-1 px-4 py-2 bg-gray-100 text-gray-700 rounded-lg hover:bg-gray-200 transition-colors font-medium"
            >
              Cancel
            </button>
            <button
              type="submit"
              disabled={!sessionId.trim()}
              className="flex-1 px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 disabled:opacity-50 disabled:cursor-not-allowed transition-colors font-medium"
            >
              Create
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}
