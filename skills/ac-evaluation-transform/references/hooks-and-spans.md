# Hooks, Span Hierarchy, and Metrics

## Table of Contents
1. [Module-level tracking state](#module-level-tracking-state)
2. [pre_tool_use_hook](#pre_tool_use_hook)
3. [post_tool_use_hook](#post_tool_use_hook)
4. [Span hierarchy](#span-hierarchy)
5. [invoke_agent span](#invoke_agent-span)
6. [execute_event_loop_cycle span](#execute_event_loop_cycle-span)
7. [chat spans](#chat-spans)
8. [Saving tool span contexts in the main loop](#saving-tool-span-contexts-in-the-main-loop)
9. [Token usage attributes](#token-usage-attributes)
10. [Recording metrics per query](#recording-metrics-per-query)
11. [Recording metrics per tool call](#recording-metrics-per-tool-call)
12. [First-token tracking](#first-token-tracking)
13. [Session ID setup](#session-id-setup)
14. [Clean shutdown](#clean-shutdown)

---

## Module-level tracking state

The Claude Agent SDK hook system has no shared context between `PreToolUse` and
`PostToolUse`, so we track state in module-level dicts keyed by `tool_use_id`:

```python
_tool_spans: dict[str, trace.Span] = {}
_tool_start_times: dict[str, float] = {}
_tool_span_contexts: dict[str, tuple] = {}   # (trace_id, span_id, trace_flags)
_tool_inputs: dict[str, dict] = {}           # tool_use_id -> tool input args
_tool_results: dict[str, list] = {}          # tool_use_id -> result content list
_active_cycle_context = None                 # Parent context for tool spans
```

---

## pre_tool_use_hook

Creates a trace span for the tool execution. The span is explicitly parented to
`_active_cycle_context` so it shares the same traceId as the invoke_agent span.

```python
async def pre_tool_use_hook(hook_input, tool_use_id, hook_context):
    tool_name = hook_input["tool_name"]
    tool_input = hook_input["tool_input"]

    span = tracer.start_span(
        f"tool.{tool_name}",
        context=_active_cycle_context,
        attributes={
            "tool.input": _sanitize(str(tool_input)),
            "gen_ai.tool.name": _strip_tool_prefix(tool_name),
            "gen_ai.tool.call.id": tool_use_id or "",
            "gen_ai.operation.name": "execute_tool",
            "gen_ai.event.start_time": _iso_now(),
        },
    )
    if tool_use_id:
        _tool_spans[tool_use_id] = span
        _tool_start_times[tool_use_id] = time.time()
        _tool_inputs[tool_use_id] = tool_input
    return {}
```

**Why `context=_active_cycle_context`:** Both hooks run in the Claude SDK's async context
which does NOT inherit the OTel span context. Without explicitly passing the parent
context, tool spans get a **separate traceId** — breaking the span hierarchy and causing
evaluation errors.

---

## post_tool_use_hook

Sets span attributes, emits per-tool I/O summary (critical for evaluations), emits
bedrock-format logs, stores results, and records metrics.

```python
async def post_tool_use_hook(hook_input, tool_use_id, hook_context):
    tool_name = hook_input.get("tool_name", "unknown")
    tool_response = hook_input.get("tool_response", "")
    plain_name = _strip_tool_prefix(tool_name)

    # Retrieve span and timing (but don't end span yet)
    span = _tool_spans.pop(tool_use_id, None) if tool_use_id else None
    start_time = _tool_start_times.pop(tool_use_id, None) if tool_use_id else None
    tool_input_args = _tool_inputs.pop(tool_use_id, {}) if tool_use_id else {}
    if span:
        span.set_attribute("tool.output", _sanitize(str(tool_response)))
        span.set_attribute("gen_ai.tool.status", "success")
        span.set_attribute("gen_ai.event.end_time", _iso_now())

    # Retrieve saved span context from main response loop
    saved_ctx = _tool_span_contexts.pop(tool_use_id, None) if tool_use_id else None

    # Extract plain text from content items
    result_content = []
    if isinstance(tool_response, dict) and "content" in tool_response:
        for item in tool_response["content"]:
            if isinstance(item, dict) and item.get("type") == "text":
                result_content.append({"text": item["text"]})
            elif isinstance(item, dict) and "text" in item:
                result_content.append({"text": item["text"]})
            else:
                result_content.append({"text": str(item)})
    elif isinstance(tool_response, list):
        for item in tool_response:
            if isinstance(item, dict) and item.get("type") == "text":
                result_content.append({"text": item["text"]})
            elif isinstance(item, dict) and "text" in item:
                result_content.append({"text": item["text"]})
            else:
                result_content.append({"text": str(item)})
    else:
        result_content.append({"text": str(tool_response)})

    # Store for invoke_agent-level I/O enrichment
    if tool_use_id:
        _tool_results[tool_use_id] = result_content

    # --- Per-tool I/O summary (CRITICAL for evaluations) ---
    # Without this, evaluator throws LogEventMissingException
    if span and tool_use_id:
        tool_span_ctx = span.get_span_context()
        _emit_structured_log({
            "output": {"messages": [{
                "content": {
                    "message": json.dumps([{"text": t["text"]} for t in result_content]),
                    "id": tool_use_id,
                },
                "role": "assistant",
            }]},
            "input": {"messages": [{
                "content": {
                    "content": json.dumps(tool_input_args) if tool_input_args else "{}",
                    "role": "tool",
                    "id": tool_use_id,
                },
                "role": "tool",
            }]},
        }, span_context=(
            tool_span_ctx.trace_id,
            tool_span_ctx.span_id,
            tool_span_ctx.trace_flags,
        ))
        span.end()  # End AFTER emitting I/O log
    elif span:
        span.end()

    # Bedrock-format logs
    _emit_bedrock_log(
        {"content": result_content, "id": tool_use_id or ""},
        "gen_ai.tool.message",
        span_context=saved_ctx,
    )
    _emit_bedrock_log(
        {"content": [{"toolResult": {
            "toolUseId": tool_use_id or "",
            "content": result_content,
            "status": "success",
        }}]},
        "gen_ai.user.message",
        span_context=saved_ctx,
    )

    # Tool metrics
    tool_attrs = {"tool_name": plain_name, "tool_use_id": tool_use_id or ""}
    duration = time.time() - start_time if start_time else 0
    _strands_tool_call_count.add(1, tool_attrs)
    _strands_tool_duration.record(duration, tool_attrs)
    _strands_tool_success_count.add(1, tool_attrs)
    return {}
```

---

## Span hierarchy

The full span tree must match Strands:

```
invoke_agent <agent-name>          (INTERNAL, status=OK)
  └── execute_event_loop_cycle     (INTERNAL)
        ├── chat                   (INTERNAL)
        ├── chat <model-id>        (CLIENT)
        └── tool.<tool-name>       (INTERNAL, from hooks)
```

---

## invoke_agent span

```python
_AGENT_NAME = "your-agent-name"

with tracer.start_as_current_span(
    f"invoke_agent {_AGENT_NAME}",
    attributes={
        "user.input": _sanitize(user_input),
        "gen_ai.operation.name": "invoke_agent",
        "gen_ai.system": "aws.bedrock",
        "gen_ai.agent.name": _AGENT_NAME,
        "gen_ai.request.model": "MODEL_ID",
        "gen_ai.agent.tools": '["tool1", "tool2"]',  # JSON string
        "gen_ai.event.start_time": _iso_now(),
    },
) as agent_span:
    # ... process query ...
    agent_span.set_attribute("gen_ai.event.end_time", _iso_now())
    agent_span.set_status(trace.Status(trace.StatusCode.OK))
```

---

## execute_event_loop_cycle span

Wraps the model call + tool execution. Created with `start_span()` and manually
attached to context so child spans are parented correctly:

```python
global _active_cycle_context
cycle_span = tracer.start_span("execute_event_loop_cycle", attributes={
    "gen_ai.event.start_time": _iso_now(),
})
_active_cycle_context = trace.set_span_in_context(cycle_span)
_cycle_ctx = context.attach(_active_cycle_context)

# ... model call, response processing, tool execution ...

cycle_span.set_attribute("gen_ai.event.end_time", _iso_now())
cycle_span.end()
context.detach(_cycle_ctx)
_active_cycle_context = None

# NOW emit invoke_agent-level I/O summary (current span is invoke_agent)
_emit_structured_log({...})
```

**Why detach before emitting I/O summary:** If emitted while cycle_span is current, the
log gets the cycle span's spanId instead of invoke_agent's. The evaluator expects the I/O
summary to reference the invoke_agent span.

---

## chat spans

Both created as children of execute_event_loop_cycle:

```python
chat_start = time.time()
chat_span = tracer.start_span("chat", attributes={
    "gen_ai.operation.name": "chat",
    "gen_ai.system": "aws.bedrock",
    "gen_ai.request.model": "MODEL_ID",
    "gen_ai.event.start_time": _iso_now(),
})
client_span = tracer.start_span(
    "chat MODEL_ID",
    kind=trace.SpanKind.CLIENT,
    attributes={
        "gen_ai.operation.name": "chat",
        "gen_ai.system": "aws.bedrock",
        "gen_ai.request.model": "MODEL_ID",
        "gen_ai.event.start_time": _iso_now(),
    },
)
```

End both with timing + token attributes:

```python
chat_duration_s = time.time() - chat_start
ttft_s = (first_token_time - chat_start) if first_token_time else chat_duration_s

for s in (client_span, chat_span):
    s.set_attribute("gen_ai.event.end_time", _iso_now())
    s.set_attribute("gen_ai.server.request.duration", chat_duration_s)
    s.set_attribute("gen_ai.server.time_to_first_token", ttft_s)
    for k, v in _token_attrs.items():
        s.set_attribute(k, v)
    s.end()
```

---

## Saving tool span contexts in the main loop

When `ToolUseBlock` is received in the main response loop (inside the active span
context), save the span context for bedrock-format log correlation in hooks:

```python
# In the response processing loop, when ToolUseBlock is received:
_cur = trace.get_current_span()
if _cur and block.id:
    _sc = _cur.get_span_context()
    if _sc and _sc.is_valid:
        _tool_span_contexts[block.id] = (_sc.trace_id, _sc.span_id, _sc.trace_flags)
```

This is needed because hooks run outside the OTel span context. The main loop is the
only place where `trace.get_current_span()` returns a valid span for correlation.

---

## Token usage attributes

Set on the invoke_agent span at ResultMessage time:

```python
_token_attrs = {
    "gen_ai.usage.input_tokens": input_tokens,
    "gen_ai.usage.output_tokens": output_tokens,
    "gen_ai.usage.prompt_tokens": input_tokens,       # alias
    "gen_ai.usage.completion_tokens": output_tokens,   # alias
    "gen_ai.usage.total_tokens": total_tokens,
}
# Optional cache tokens:
if cache_read:
    _token_attrs["gen_ai.usage.cache_read_input_tokens"] = cache_read
if cache_write:
    _token_attrs["gen_ai.usage.cache_write_input_tokens"] = cache_write
```

---

## Recording metrics per query

```python
cycle_id = str(uuid.uuid4())

# Start of query
_start_cycle.add(1, {"event_loop_cycle_id": cycle_id})
_cycle_count.add(1, {"event_loop_cycle_id": cycle_id})

# After ResultMessage
_end_cycle.add(1, {"event_loop_cycle_id": cycle_id})
_cycle_duration.record(query_duration, {"event_loop_cycle_id": cycle_id})
_loop_input_tokens.record(input_tokens)
_loop_output_tokens.record(output_tokens)
_loop_latency.record(query_duration_ms)
_model_ttft.record(ttft_ms)
_operation_duration.record(query_duration, _BEDROCK_ATTRS)

if input_tokens:
    _token_usage.record(input_tokens, {**_BEDROCK_ATTRS, "gen_ai.token.type": "input"})
if output_tokens:
    _token_usage.record(output_tokens, {**_BEDROCK_ATTRS, "gen_ai.token.type": "output"})
```

---

## Recording metrics per tool call

Done in `post_tool_use_hook` (see above). Uses `_strip_tool_prefix()` to convert
MCP-prefixed names to plain names matching Strands.

---

## First-token tracking

Track when the first content block arrives from the LLM:

```python
first_token_time = None

async for message in client.receive_response():
    if isinstance(message, AssistantMessage):
        for block in message.content:
            if isinstance(block, (TextBlock, ToolUseBlock)):
                if first_token_time is None:
                    first_token_time = time.time()

# On ResultMessage:
ttft_ms = ((first_token_time - query_start) * 1000) if first_token_time else query_duration_ms
_model_ttft.record(ttft_ms)
```

---

## Session ID setup

```python
parser = argparse.ArgumentParser()
parser.add_argument("--session-id", default=None)
args = parser.parse_args()

session_id = args.session_id or str(uuid.uuid4())
ctx = baggage.set_baggage("session.id", session_id)
context.attach(ctx)
print(f"Session ID: {session_id}")
```

---

## Clean shutdown

Call all three provider shutdowns when the agent exits:

```python
provider.shutdown()        # Flush traces to X-Ray
_log_provider.shutdown()   # Flush logs to CloudWatch
_meter_provider.shutdown() # Flush metrics to CloudWatch EMF
```

`provider.shutdown()` must come first — `BatchSpanProcessor` exports trace spans with
per-session `gen_ai.usage.*` token attributes. Without this, the last session shows 0
tokens in the console.
