"""Tool-span hooks and hook merging.

The Claude Agent SDK hook system shares no context between PreToolUse and
PostToolUse, so the hooks close over a specific :class:`InvocationContext` (bound
to one client instance) and key their scratch state by ``tool_use_id``.

``build_instrumentation_hooks`` returns a ``dict[str, list[HookMatcher]]`` ready
to hand to ``merge_hooks``. Emitting a per-tool I/O-summary log before the tool
span ends is REQUIRED — without it the tool-level evaluators throw
LogEventMissingException / ToolSpanMappingException.
"""

from __future__ import annotations

import json
import time
from typing import Any

from opentelemetry import trace

from ._context import InvocationContext
from ._emit import (
    emit_bedrock_log,
    emit_structured_log,
    extract_result_content,
    iso_now,
    sanitize,
    strip_tool_prefix,
)


def build_instrumentation_hooks(instance: Any) -> dict:
    """Build the Pre/PostToolUse hooks for a client ``instance``.

    The hooks resolve the *current* per-turn :class:`InvocationContext` from
    ``instance._otel_ctx`` at call time (not a captured reference), because the
    context is replaced after each turn. If instrumentation is off / between
    turns, the hooks are inert.
    """
    from claude_agent_sdk import HookMatcher

    def _ctx() -> InvocationContext | None:
        c = getattr(instance, "_otel_ctx", None)
        return c if c is not None and c.agent_span is not None else None

    async def pre_tool_use_hook(hook_input, tool_use_id, hook_context):
        ctx = _ctx()
        if ctx is None:
            return {}
        tool_name = hook_input["tool_name"]
        tool_input = hook_input.get("tool_input", {})
        span = ctx.providers.tracer.start_span(
            f"tool.{tool_name}",
            context=ctx.active_cycle_context,
            attributes={
                "tool.input": sanitize(str(tool_input)),
                "gen_ai.tool.name": strip_tool_prefix(tool_name),
                "gen_ai.tool.call.id": tool_use_id or "",
                "gen_ai.operation.name": "execute_tool",
                "gen_ai.event.start_time": iso_now(),
            },
        )
        if tool_use_id:
            ctx.tool_spans[tool_use_id] = span
            ctx.tool_start_times[tool_use_id] = time.time()
            ctx.tool_inputs[tool_use_id] = tool_input
        return {}

    async def post_tool_use_hook(hook_input, tool_use_id, hook_context):
        ctx = _ctx()
        if ctx is None:
            return {}
        tool_name = hook_input.get("tool_name", "unknown")
        tool_response = hook_input.get("tool_response", "")
        plain_name = strip_tool_prefix(tool_name)

        span = ctx.tool_spans.pop(tool_use_id, None) if tool_use_id else None
        start_time = ctx.tool_start_times.pop(tool_use_id, None) if tool_use_id else None
        tool_input_args = ctx.tool_inputs.pop(tool_use_id, {}) if tool_use_id else {}
        if span:
            span.set_attribute("tool.output", sanitize(str(tool_response)))
            span.set_attribute("gen_ai.tool.status", "success")
            span.set_attribute("gen_ai.event.end_time", iso_now())

        saved_ctx = (
            ctx.tool_span_contexts.pop(tool_use_id, None) if tool_use_id else None
        )
        result_content = extract_result_content(tool_response)
        if tool_use_id:
            ctx.tool_results[tool_use_id] = result_content

        # Per-tool I/O summary — MUST be emitted (tied to the tool span) before
        # span.end() or the tool-level evaluators fail.
        if span and tool_use_id:
            tsc = span.get_span_context()
            emit_structured_log(
                ctx.providers.struct_logger,
                {
                    "output": {
                        "messages": [
                            {
                                "content": {
                                    "message": json.dumps(
                                        [{"text": t["text"]} for t in result_content]
                                    ),
                                    "id": tool_use_id,
                                },
                                "role": "assistant",
                            }
                        ]
                    },
                    "input": {
                        "messages": [
                            {
                                "content": {
                                    "content": json.dumps(tool_input_args)
                                    if tool_input_args
                                    else "{}",
                                    "role": "tool",
                                    "id": tool_use_id,
                                },
                                "role": "tool",
                            }
                        ]
                    },
                },
                span_context=(tsc.trace_id, tsc.span_id, tsc.trace_flags),
                session_id=ctx.session_id,
            )
            span.end()
        elif span:
            span.end()

        emit_bedrock_log(
            ctx.providers.bedrock_logger,
            {"content": result_content, "id": tool_use_id or ""},
            "gen_ai.tool.message",
            span_context=saved_ctx,
        )
        emit_bedrock_log(
            ctx.providers.bedrock_logger,
            {
                "content": [
                    {
                        "toolResult": {
                            "toolUseId": tool_use_id or "",
                            "content": result_content,
                            "status": "success",
                        }
                    }
                ]
            },
            "gen_ai.user.message",
            span_context=saved_ctx,
        )

        m = ctx.providers.metrics
        tool_attrs = {"tool_name": plain_name, "tool_use_id": tool_use_id or ""}
        duration = time.time() - start_time if start_time else 0
        m["tool_call_count"].add(1, tool_attrs)
        m["tool_duration"].record(duration, tool_attrs)
        m["tool_success_count"].add(1, tool_attrs)
        return {}

    return {
        "PreToolUse": [HookMatcher(hooks=[pre_tool_use_hook])],
        "PostToolUse": [HookMatcher(hooks=[post_tool_use_hook])],
    }


def merge_hooks(existing: dict | None, extra: dict) -> dict:
    """Merge instrumentation hooks into a user's hooks dict, per event, without
    dropping the caller's own hooks."""
    merged: dict[str, list[Any]] = {}
    for src in (existing or {}, extra):
        for event, matchers in src.items():
            merged.setdefault(event, []).extend(matchers)
    return merged
