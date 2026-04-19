"""Claude Agent SDK wrapper."""

from claude_agent_sdk import query


SYSTEM_PROMPT = """You are a helpful assistant. Answer questions clearly and concisely."""


async def send_message(chat_id: str, content: str, history: list) -> str:
    """Send a message to the Claude agent and return the response."""
    result = await query(
        prompt=content,
        model="sonnet",
        system_prompt=SYSTEM_PROMPT,
        tools=["Bash", "Read", "Write", "Glob", "Grep"],
        history=history,
    )
    return result.content
