"""Partially-instrumented Claude agent missing the per-tool I/O summary log.

Fixture for eval id=2 (LogEventMissingException on tool.<name> spans).

What's correct:
- TracerProvider, LoggerProvider, MeterProvider all configured
- invoke_agent, execute_event_loop_cycle, chat, chat<model> spans created
- Tool spans created in pre_tool_use_hook with context=_active_cycle_context
- invoke_agent-level I/O summary emitted after cycle context detach

What's broken:
- post_tool_use_hook ends the tool span but never emits a per-tool I/O
  summary log tied to that span. AgentCore's ToolSelectionAccuracy evaluator
  then fails with LogEventMissingException: span data is incomplete. Span
  with ID: <tool-span-id> and name: tool.<toolname>

The fix: inside post_tool_use_hook, before span.end(), call
_emit_structured_log(body, span_context=(tool_trace_id, tool_span_id,
tool_flags)) with an input.messages role:tool entry and an output.messages
role:assistant entry (see references/structured-logs.md §"Per-tool I/O
summary format").
"""
import time

from claude_agent_sdk.types import HookMatcher
from opentelemetry import trace


# Assume these were set up by a parent _instrumentation module.
tracer: trace.Tracer = None  # type: ignore
_active_cycle_context = None
_tool_spans: dict = {}
_tool_start_times: dict = {}
_tool_inputs: dict = {}
_strands_tool_call_count = None
_strands_tool_duration = None
_strands_tool_success_count = None


async def pre_tool_use_hook(hook_input, tool_use_id, hook_context):
    tool_name = hook_input["tool_name"]
    tool_input = hook_input["tool_input"]

    span = tracer.start_span(
        f"tool.{tool_name}",
        context=_active_cycle_context,
        attributes={
            "tool.input": str(tool_input),
            "gen_ai.tool.name": tool_name.split("__")[-1],
            "gen_ai.tool.call.id": tool_use_id or "",
            "gen_ai.operation.name": "execute_tool",
        },
    )
    if tool_use_id:
        _tool_spans[tool_use_id] = span
        _tool_start_times[tool_use_id] = time.time()
        _tool_inputs[tool_use_id] = tool_input
    return {}


async def post_tool_use_hook(hook_input, tool_use_id, hook_context):
    # BUG: this hook records metrics and ends the tool span but never emits a
    # per-tool I/O summary log. The ToolSelectionAccuracy evaluator needs a
    # log record whose spanId matches the tool span's spanId; without it,
    # AgentCore returns LogEventMissingException.
    tool_name = hook_input.get("tool_name", "unknown")
    plain_name = tool_name.split("__")[-1]

    span = _tool_spans.pop(tool_use_id, None) if tool_use_id else None
    start_time = _tool_start_times.pop(tool_use_id, None) if tool_use_id else None
    _tool_inputs.pop(tool_use_id, None)

    if span:
        span.set_attribute("gen_ai.tool.status", "success")
        span.end()  # <-- needs per-tool I/O log BEFORE this line

    duration = time.time() - start_time if start_time else 0
    tool_attrs = {"tool_name": plain_name, "tool_use_id": tool_use_id or ""}
    _strands_tool_call_count.add(1, tool_attrs)
    _strands_tool_duration.record(duration, tool_attrs)
    _strands_tool_success_count.add(1, tool_attrs)
    return {}


HOOKS = {
    "PreToolUse": [HookMatcher(hooks=[pre_tool_use_hook])],
    "PostToolUse": [HookMatcher(hooks=[post_tool_use_hook])],
}
