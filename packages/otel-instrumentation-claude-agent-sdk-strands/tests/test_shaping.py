"""End-to-end shaping tests: drive a scripted turn through the wrappers and assert
the span tree + structured I/O log bodies match the Strands schema the evaluators
parse."""

from __future__ import annotations

import json

import pytest

import claude_agent_sdk as sdk
from otel_instrumentation_claude_agent_sdk_strands import (
    ClaudeAgentSdkStrandsInstrumentor,
)


def _struct_bodies(logs):
    """Structured (strands-scope) log bodies = dict bodies with input/output."""
    return [
        r.body
        for r in logs
        if isinstance(r.body, dict) and "input" in r.body and "output" in r.body
    ]


@pytest.mark.asyncio
async def test_tool_using_turn_shapes_io_summary(otel_memory):
    inst = ClaudeAgentSdkStrandsInstrumentor()
    inst.instrument(agent_name="test-agent", model="test-model")
    try:
        options = sdk.ClaudeAgentOptions()
        client = sdk.ClaudeSDKClient(options=options)

        # A tool-calling turn: assistant calls a tool, then answers.
        client.script(
            [
                sdk.AssistantMessage(
                    content=[
                        sdk.TextBlock("Let me look that up."),
                        sdk.ToolUseBlock(
                            id="toolu_1",
                            name="mcp__claims__lookup_policy",
                            input={"policy_id": "AUTO-1001"},
                        ),
                    ],
                    model="test-model",
                ),
                sdk.AssistantMessage(
                    content=[sdk.TextBlock("Your claim is approved.")],
                    model="test-model",
                ),
                sdk.ResultMessage(
                    usage={"input_tokens": 10, "output_tokens": 20},
                    model="test-model",
                    session_id="sess-123",
                ),
            ]
        )

        # Fire the tool hooks the way the SDK would (Pre then Post), so the
        # per-tool span + I/O log are produced.
        hooks = options.hooks
        pre = hooks["PreToolUse"][0].hooks[0]
        post = hooks["PostToolUse"][0].hooks[0]

        await client.query("Adjudicate AUTO-1001")
        # Emulate the SDK invoking the tool between messages.
        await pre(
            {"tool_name": "mcp__claims__lookup_policy", "tool_input": {"policy_id": "AUTO-1001"}},
            "toolu_1",
            None,
        )
        await post(
            {
                "tool_name": "mcp__claims__lookup_policy",
                "tool_response": {"content": [{"type": "text", "text": "coverage 25000"}]},
            },
            "toolu_1",
            None,
        )
        collected = [m async for m in client.receive_response()]

        # Caller still gets the original stream unchanged.
        assert len(collected) == 3

        # --- Spans ---
        spans = otel_memory["spans"].get_finished_spans()
        names = {s.name for s in spans}
        assert f"invoke_agent test-agent" in names
        assert "execute_event_loop_cycle" in names
        assert "chat" in names
        assert any(n.startswith("tool.") for n in names)
        # All under the strands scope.
        assert all(
            s.instrumentation_scope.name == "strands.telemetry.tracer"
            for s in spans
        )

        # --- Structured I/O summary (invoke-level) ---
        bodies = _struct_bodies(otel_memory["logs"])
        # There is at least the per-tool summary and the invoke-level summary.
        assert len(bodies) >= 2
        invoke = bodies[-1]  # emitted last, after cycle detach

        # input.messages: user-only, dict content (no role:tool at invoke level)
        in_msgs = invoke["input"]["messages"]
        assert len(in_msgs) == 1 and in_msgs[0]["role"] == "user"
        assert isinstance(in_msgs[0]["content"], dict)

        # output.messages: tool-calling message enriched with tool.result;
        # final text message has finish_reason.
        out_msgs = invoke["output"]["messages"]
        assert any(
            isinstance(m["content"], dict) and "tool.result" in m["content"]
            for m in out_msgs
        )
        assert any(
            isinstance(m["content"], dict)
            and m["content"].get("finish_reason") == "end_turn"
            for m in out_msgs
        )

        # usage in camelCase.
        assert invoke["usage"]["inputTokens"] == 10
        assert invoke["usage"]["totalTokens"] == 30
    finally:
        inst.uninstrument()


@pytest.mark.asyncio
async def test_text_only_turn(otel_memory):
    inst = ClaudeAgentSdkStrandsInstrumentor()
    inst.instrument(agent_name="t2", model="m")
    try:
        client = sdk.ClaudeSDKClient(options=sdk.ClaudeAgentOptions())
        client.script(
            [
                sdk.AssistantMessage([sdk.TextBlock("Hello there.")], model="m"),
                sdk.ResultMessage(usage={"input_tokens": 3, "output_tokens": 4}),
            ]
        )
        await client.query("hi")
        _ = [m async for m in client.receive_response()]

        bodies = _struct_bodies(otel_memory["logs"])
        assert bodies, "expected an invoke-level I/O summary"
        invoke = bodies[-1]
        out = invoke["output"]["messages"]
        assert out and out[-1]["content"].get("finish_reason") == "end_turn"
        # No tool.result on a text-only turn.
        assert not any(
            isinstance(m["content"], dict) and "tool.result" in m["content"]
            for m in out
        )
    finally:
        inst.uninstrument()


@pytest.mark.asyncio
async def test_uninstrument_restores_original(otel_memory):
    orig_query = sdk.ClaudeSDKClient.query
    inst = ClaudeAgentSdkStrandsInstrumentor()
    inst.instrument(agent_name="t3")
    assert sdk.ClaudeSDKClient.query is not orig_query  # wrapped
    inst.uninstrument()
    assert sdk.ClaudeSDKClient.query is orig_query  # restored
