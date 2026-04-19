"""Vanilla Claude Agent SDK math agent — fixture for eval id=3.

No OTEL, no logging, no hooks. The skill should add full instrumentation to
this file without changing the @tool bodies, the create_sdk_mcp_server call,
the allowed_tools list, or the CLI loop.
"""
import argparse

import anyio
from claude_agent_sdk import (
    AssistantMessage,
    ClaudeAgentOptions,
    ClaudeSDKClient,
    ResultMessage,
    TextBlock,
    ToolUseBlock,
    create_sdk_mcp_server,
    tool,
)

MODEL_ID = "us.anthropic.claude-sonnet-4-20250514-v1:0"


@tool("word_count", "Count the number of words in the given text", {"text": str})
async def word_count(args):
    count = len(args["text"].split())
    return {"content": [{"type": "text", "text": str(count)}]}


@tool("reverse_string", "Reverse the given text string", {"text": str})
async def reverse_string(args):
    return {"content": [{"type": "text", "text": args["text"][::-1]}]}


async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--query", action="append", default=[])
    args = parser.parse_args()

    server = create_sdk_mcp_server(
        name="tools",
        version="1.0.0",
        tools=[word_count, reverse_string],
    )
    options = ClaudeAgentOptions(
        mcp_servers={"tools": server},
        allowed_tools=["mcp__tools__word_count", "mcp__tools__reverse_string"],
    )

    async with ClaudeSDKClient(options=options) as client:
        for user_input in args.query or []:
            print(f"\nYou: {user_input}")
            await client.query(user_input)
            async for message in client.receive_response():
                if isinstance(message, AssistantMessage):
                    for block in message.content:
                        if isinstance(block, TextBlock):
                            print(f"\nAgent: {block.text}")
                        elif isinstance(block, ToolUseBlock):
                            pass
                elif isinstance(message, ResultMessage):
                    pass


if __name__ == "__main__":
    anyio.run(main)
