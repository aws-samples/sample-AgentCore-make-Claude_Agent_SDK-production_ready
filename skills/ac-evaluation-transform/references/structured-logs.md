# Structured Logs: Helpers, I/O Summaries, and Bedrock-Format Logs

## Table of Contents
1. [Helper functions](#helper-functions)
2. [_emit_structured_log](#_emit_structured_log)
3. [_emit_bedrock_log](#_emit_bedrock_log)
4. [I/O summary format (invoke_agent level)](#io-summary-format-invoke_agent-level)
5. [Per-tool I/O summary format](#per-tool-io-summary-format)
6. [Bedrock-format log events](#bedrock-format-log-events)
7. [Usage data in I/O summary](#usage-data-in-io-summary)

---

## Helper functions

```python
def _sanitize(value: str) -> str:
    """Replace surrogate characters that the OTLP exporter cannot encode."""
    return value.encode("utf-8", errors="replace").decode("utf-8")

def _iso_now():
    """Return current UTC time as ISO-8601 string."""
    return datetime.now(timezone.utc).isoformat()

def _strip_tool_prefix(name: str) -> str:
    """Strip ``mcp__<server>__`` prefix from MCP tool names."""
    return name.split("__")[-1] if "__" in name else name
```

Apply `_sanitize()` to every user-provided string set as a span attribute or log body.
Terminal `input()` can produce surrogate characters (e.g. `\udce5`) that fail UTF-8
encoding inside the OTLP exporter.

---

## _emit_structured_log

Emits I/O summary logs under the `strands.telemetry.tracer` scope.

```python
def _emit_structured_log(body, attributes=None, span_context=None):
    """Emit a structured dict-body log under the strands.telemetry.tracer scope.

    Args:
        body: Dict body (I/O summary).
        attributes: Optional extra attributes.
        span_context: Optional (trace_id, span_id, trace_flags) tuple to use
                      instead of the current span context. Required when emitting
                      logs tied to a specific span (e.g. per-tool I/O summaries).
    """
    if span_context:
        tid, sid, flags = span_context
    else:
        span = trace.get_current_span()
        span_ctx = span.get_span_context() if span else None
        tid = span_ctx.trace_id if span_ctx and span_ctx.is_valid else 0
        sid = span_ctx.span_id if span_ctx and span_ctx.is_valid else 0
        flags = span_ctx.trace_flags if span_ctx and span_ctx.is_valid else 0

    merged_attrs = dict(attributes) if attributes else {}
    merged_attrs.setdefault("event.name", "strands.telemetry.tracer")
    session_id = baggage.get_baggage("session.id")
    if session_id:
        merged_attrs["session.id"] = session_id

    record = LogRecord(
        timestamp=int(time.time_ns()),
        body=body,
        severity_number=SeverityNumber.INFO,
        severity_text="",       # Strands uses empty string, NOT "INFO"
        trace_id=tid,
        span_id=sid,
        trace_flags=flags,
        resource=resource,
        attributes=merged_attrs or None,
    )
    _struct_logger.emit(record)
```

**Why `severity_text=""`:** Strands structured logs use empty severityText. Using `"INFO"`
causes a mismatch that can confuse log filtering.

**Why `trace_flags` fallback is `0`:** Passing `None` causes `TypeError: int() argument
must be... not 'NoneType'` inside the OTLP log encoder.

**Why `span_context` parameter exists:** Per-tool I/O logs must be tied to the tool span
(not the current active span). Without this parameter, `trace.get_current_span()` returns
the cycle span, and the evaluator can't find the tool-level log.

---

## _emit_bedrock_log

Emits per-message logs under the bedrock-runtime scope.

```python
def _emit_bedrock_log(body, event_name, span_context=None):
    """Emit a log under the bedrock-runtime scope.

    Args:
        body: Dict body.
        event_name: One of gen_ai.choice, gen_ai.user.message, etc.
        span_context: Optional (trace_id, span_id, trace_flags) tuple.
    """
    if span_context:
        tid, sid, flags = span_context
    else:
        span = trace.get_current_span()
        span_ctx = span.get_span_context() if span else None
        tid = span_ctx.trace_id if span_ctx and span_ctx.is_valid else 0
        sid = span_ctx.span_id if span_ctx and span_ctx.is_valid else 0
        flags = span_ctx.trace_flags if span_ctx and span_ctx.is_valid else 0

    record = LogRecord(
        timestamp=int(time.time_ns()),
        body=body,
        severity_number=SeverityNumber.INFO,
        severity_text="",
        trace_id=tid, span_id=sid, trace_flags=flags,
        resource=resource,
        attributes={"event.name": event_name, "gen_ai.system": "aws.bedrock"},
    )
    _bedrock_logger.emit(record)
```

Use `gen_ai.system: "aws.bedrock"` in attributes (not `"anthropic"`) for AgentCore
compatibility, even though Claude Agent SDK calls the Anthropic API directly.

---

## I/O summary format (invoke_agent level)

This is what AgentCore Evaluations parses to extract the user query and agent response.

### Critical rules

1. **`input.messages` must contain ONLY `role: "user"`** — no `role: "tool"` entries.
   Including tool entries causes `AgentSpanMappingException: Failed to parse user_query`.
2. **Tool results go in `output.messages`** via the `tool.result` key.
3. **Final text message** uses `content.message` + `content.finish_reason: "end_turn"`.
4. **Intermediate tool messages** use `content.content` initially, then convert to
   `content.message` + `content["tool.result"]` after tool results arrive.
5. **No bare-string `content` entries** — must always be a dict.
6. **Emit AFTER `context.detach(cycle_ctx)`** so `invoke_agent` is the current span.

### Example I/O summary (tool-calling flow)

```json
{
    "output": {
        "messages": [
            {
                "content": {
                    "message": "[{\"toolUse\": {\"name\": \"word_count\", \"input\": {\"text\": \"hello world\"}, \"toolUseId\": \"toolu_...\"}}]",
                    "tool.result": "[{\"toolResult\": {\"toolUseId\": \"toolu_...\", \"status\": \"success\", \"content\": [{\"text\": \"2\"}]}}]"
                },
                "role": "assistant"
            },
            {
                "content": {
                    "message": "[{\"text\": \"The text contains 2 words.\"}]",
                    "finish_reason": "end_turn"
                },
                "role": "assistant"
            }
        ]
    },
    "input": {
        "messages": [
            {
                "content": {"content": "[{\"text\": \"count the words in hello world\"}]"},
                "role": "user"
            }
        ]
    },
    "usage": {
        "inputTokens": 7,
        "outputTokens": 205,
        "totalTokens": 212
    }
}
```

### Implementation pattern

```python
# Track during response processing:
output_messages = []
tool_use_records = []
pending_text_blocks = []

# On ToolUseBlock:
assistant_content = [{"toolUse": {"name": name, "input": inp, "toolUseId": block_id}}]
output_messages.append({
    "content": {"content": json.dumps(assistant_content)},
    "role": "assistant",
})

# On ResultMessage — enrich tool messages with results:
for rec in tool_use_records:
    result_content = _tool_results.pop(rec["id"], [{"text": ""}])
    tool_result_json = json.dumps([{"toolResult": {
        "toolUseId": rec["id"], "status": "success", "content": result_content,
    }}])
    for msg in output_messages:
        c = msg.get("content", {})
        if isinstance(c, dict) and "content" in c and rec["id"] in c["content"]:
            c["message"] = c.pop("content")
            c["tool.result"] = tool_result_json
            break

# Convert last text message to final format:
last = output_messages[-1]
c = last.get("content", {})
if isinstance(c, dict) and "content" in c:
    c["message"] = c.pop("content")
    c["finish_reason"] = "end_turn"

# Emit with user-only input:
_emit_structured_log({
    "output": {"messages": output_messages},
    "input": {"messages": [{
        "content": {"content": json.dumps([{"text": _sanitize(user_input)}])},
        "role": "user",
    }]},
    "usage": usage_summary,
})
```

---

## Per-tool I/O summary format

Each tool span needs its own I/O summary log. Emitted in `post_tool_use_hook` before
`span.end()`, tied to the tool span via `span_context=`.

```json
{
    "output": {
        "messages": [{
            "content": {
                "message": "[{\"text\": \"4\"}]",
                "id": "toolu_..."
            },
            "role": "assistant"
        }]
    },
    "input": {
        "messages": [{
            "content": {
                "content": "{\"text\": \"I have a pen\"}",
                "role": "tool",
                "id": "toolu_..."
            },
            "role": "tool"
        }]
    }
}
```

---

## Bedrock-format log events

These logs go under the `opentelemetry.instrumentation.botocore.bedrock-runtime` scope:

| When | event.name | Body |
|---|---|---|
| Before LLM call (history) | `gen_ai.user.message` / `gen_ai.assistant.message` | `{"content": [{"text": "..."}]}` |
| Current user input | `gen_ai.user.message` | `{"content": [{"text": "..."}]}` |
| Tool call from model | `gen_ai.assistant.message` | `{"content": [..., {"toolUse": {...}}], "tool_calls": [...]}` |
| Tool call from model | `gen_ai.choice` | `{"message": {"tool_calls": [...]}, "index": 0, "finish_reason": "tool_use"}` |
| After tool execution | `gen_ai.tool.message` | `{"content": [{"text": "4"}], "id": "tool_use_id"}` |
| After tool execution | `gen_ai.user.message` | `{"content": [{"toolResult": {...}}]}` |
| Final text response | `gen_ai.assistant.message` | `{"content": [{"text": "..."}]}` |
| Final text response | `gen_ai.choice` | `{"message": {"content": [...], "role": "assistant"}, "index": 0, "finish_reason": "end_turn"}` |

---

## Usage data in I/O summary

The I/O summary body includes a `usage` field with camelCase keys (Bedrock format):

```python
if usage:
    input_tokens = usage.get("input_tokens", 0)
    output_tokens = usage.get("output_tokens", 0)
    usage_summary = {
        "inputTokens": input_tokens,
        "outputTokens": output_tokens,
        "totalTokens": input_tokens + output_tokens,
    }
    cache_read = usage.get("cache_read_input_tokens", 0)
    cache_write = usage.get("cache_creation_input_tokens", 0)
    if cache_read:
        usage_summary["cacheReadInputTokens"] = cache_read
    if cache_write:
        usage_summary["cacheWriteInputTokens"] = cache_write
else:
    usage_summary = "unavailable"  # string survives proto3 serialization
```

Claude SDK uses snake_case (`input_tokens`), Strands/Bedrock uses camelCase
(`inputTokens`). Always convert to camelCase for the I/O summary.
