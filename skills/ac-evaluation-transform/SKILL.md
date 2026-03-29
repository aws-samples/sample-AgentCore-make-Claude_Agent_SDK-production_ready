---
name: ac-evaluation-transform
description: >-
  Transform a Claude Agent SDK agent to emit correct OpenTelemetry traces, structured logs,
  and CloudWatch EMF metrics so that all 9 Amazon Bedrock AgentCore Evaluation built-in
  evaluators pass with zero errors. Use this skill whenever the user mentions AgentCore
  evaluations, OTEL instrumentation for Claude Agent SDK agents, making a Claude agent
  compatible with Bedrock evaluations, or adding observability/telemetry to a Claude Agent
  SDK application. Also trigger when the user encounters AgentCore evaluation errors like
  AgentSpanMappingException, LogEventMissingException, or "span data is incomplete". This
  skill modifies only the instrumentation layer — it never changes the agent's application
  logic, tools, or prompts.
---

# AC Evaluation Transform

Transform any Claude Agent SDK agent to produce OpenTelemetry telemetry compatible with
all 9 Amazon Bedrock AgentCore built-in evaluators.

## When to use this skill

- Adding OTEL instrumentation to a new Claude Agent SDK agent
- Fixing AgentCore evaluation errors on an existing instrumented agent
- Achieving telemetry parity with Strands SDK auto-instrumentation

## Overview

The Claude Agent SDK has **no built-in OTEL auto-instrumentation** (unlike Strands SDK).
This skill adds traces, structured logs, and CloudWatch EMF metrics manually — targeting
**byte-level parity** with Strands so AgentCore Evaluations treats both agents identically.

The 9 evaluators that must pass:

| Evaluator | Level |
|---|---|
| `Builtin.Helpfulness` | Trace |
| `Builtin.Faithfulness` | Trace |
| `Builtin.Correctness` | Trace |
| `Builtin.Coherence` | Trace |
| `Builtin.Conciseness` | Trace |
| `Builtin.Harmfulness` | Trace |
| `Builtin.InstructionFollowing` | Trace |
| `Builtin.GoalSuccessRate` | Session |
| `Builtin.ToolSelectionAccuracy` | Tool span |

## Transformation process

Work through these steps in order. Each step references a detail file — read it when you
reach that step. **Do not change the agent's application logic, tools, or prompts.**

### Step 1: Add dependencies and imports

Read `references/otel-setup.md` for the full import list and provider setup.

Required packages:
- `opentelemetry-api`, `opentelemetry-sdk`, `opentelemetry-exporter-otlp-proto-http`
- `aws-opentelemetry-distro` (provides `OTLPAwsSpanExporter` + `AwsCloudWatchEmfExporter`)
- `aws-requests-auth`, `botocore`, `requests`

### Step 2: Create the OTEL Resource

The Resource **must** include these attributes — without them, AgentCore cannot discover
the agent's logs:

```python
resource = Resource.create({
    "service.name": SERVICE_NAME,
    "aws.local.service": SERVICE_NAME,
    "aws.service.type": "gen_ai_agent",
    "aws.log.group.names": f"/aws/bedrock-agentcore/runtimes/{AGENT_ID}",
    "telemetry.auto.version": "0.12.2-aws",
})
```

The `aws.log.group.names` value **must** use the `/runtimes/` path prefix.

### Step 3: Set up TracerProvider

Read `references/otel-setup.md` → "TracerProvider" section.

Key requirements:
- Use `OTLPAwsSpanExporter` (NOT `OTLPSpanExporter` — SigV4 signing breaks otherwise)
- Add `BaggageSpanProcessor` BEFORE `BatchSpanProcessor`
- Tracer scope name must be `"strands.telemetry.tracer"` (not `__name__`)
- Pass explicit `endpoint=` to `OTLPAwsSpanExporter`

### Step 4: Set up LoggerProvider with two loggers

Read `references/structured-logs.md` for full details.

Two loggers with specific scope names:

| Logger | Scope | Purpose |
|---|---|---|
| `_struct_logger` | `strands.telemetry.tracer` | I/O summary logs |
| `_bedrock_logger` | `opentelemetry.instrumentation.botocore.bedrock-runtime` | Per-message Bedrock-format logs |

### Step 5: Set up MeterProvider with EMF exporter

Read `references/otel-setup.md` → "Metrics" section.

Use `AwsCloudWatchEmfExporter` with `botocore.session.Session()`. Define all metric
instruments matching Strands names:
- `strands.event_loop.*` (cycle_count, start_cycle, end_cycle, cycle_duration, etc.)
- `strands.tool.*` (call_count, duration, success_count)
- `strands.model.time_to_first_token`
- `gen_ai.client.operation.duration`, `gen_ai.client.token.usage`

### Step 6: Add helper functions

Read `references/structured-logs.md` → "Helper functions" section.

Four helpers are needed:
- `_sanitize(value)` — Replace surrogate characters for OTLP encoding
- `_iso_now()` — ISO-8601 UTC timestamp for span attributes
- `_emit_structured_log(body, attributes=None, span_context=None)` — I/O summary logs
- `_emit_bedrock_log(body, event_name, span_context=None)` — Bedrock-format logs

Critical details for `_emit_structured_log`:
- `severity_text=""` (empty string, NOT `"INFO"`)
- `event.name` attribute = `"strands.telemetry.tracer"`
- `trace_flags` fallback must be `0`, not `None`
- `span_context` parameter enables emitting logs tied to specific spans (required for
  per-tool I/O summaries)

### Step 7: Add module-level tracking dicts and tool hooks

Read `references/hooks-and-spans.md` for complete hook implementations.

Add these tracking dicts:
```python
_tool_spans: dict[str, trace.Span] = {}
_tool_start_times: dict[str, float] = {}
_tool_span_contexts: dict[str, tuple] = {}
_tool_inputs: dict[str, dict] = {}
_tool_results: dict[str, list] = {}
_active_cycle_context = None
```

**`pre_tool_use_hook`**: Creates a tool span with `context=_active_cycle_context` (critical
— without this, tool spans get a different traceId). Stores span, start time, and input.

**`post_tool_use_hook`**: Must emit a **per-tool I/O summary log** before `span.end()`.
This is the #1 cause of evaluation failures — without per-tool I/O logs, the evaluator
throws `LogEventMissingException`. Also emits bedrock-format logs and records tool metrics.

Register hooks:
```python
hooks={
    "PreToolUse": [HookMatcher(hooks=[pre_tool_use_hook])],
    "PostToolUse": [HookMatcher(hooks=[post_tool_use_hook])],
}
```

### Step 8: Wrap the query loop with span hierarchy

Read `references/hooks-and-spans.md` → "Span hierarchy" section.

The span tree must match Strands:
```
invoke_agent <agent-name> (INTERNAL, status=OK)
  └── execute_event_loop_cycle (INTERNAL)
        ├── chat (INTERNAL)
        ├── chat <model-id> (CLIENT)
        └── tool.<name> (INTERNAL, created by hooks)
```

For each user query:
1. Open `invoke_agent <name>` span with standard GenAI attributes
2. Open `execute_event_loop_cycle` span, attach to context, store as `_active_cycle_context`
3. Open `chat` + `chat <model>` spans before the model call
4. Process response — save tool span contexts at `ToolUseBlock` time
5. On `ResultMessage`: end chat/cycle spans, **detach cycle context**, then emit I/O summary
6. Set token attributes and status on `invoke_agent` span

### Step 9: Emit the invoke_agent-level I/O summary

Read `references/structured-logs.md` → "I/O summary format" section.

**Critical rules** (violations cause evaluation failures):
1. `input.messages` must contain **ONLY** `role: "user"` — no `role: "tool"` entries
2. Tool results go in `output.messages` via the `tool.result` key
3. Final text message uses `content.message` + `content.finish_reason: "end_turn"`
4. Intermediate tool messages use `content.content` (converted to `content.message` +
   `content["tool.result"]` after tool results arrive)
5. No bare-string `content` entries (must always be a dict)
6. The log must be emitted AFTER `context.detach(cycle_ctx)` so `invoke_agent` is current

### Step 10: Add session ID via argparse + baggage

```python
session_id = args.session_id or str(uuid.uuid4())
ctx = baggage.set_baggage("session.id", session_id)
context.attach(ctx)
```

### Step 11: Add clean shutdown

```python
provider.shutdown()        # Traces → X-Ray
_log_provider.shutdown()   # Logs → CloudWatch
_meter_provider.shutdown() # Metrics → CloudWatch EMF
```

`provider.shutdown()` must come first — it flushes trace spans with token attributes.

## Verification checklist

After transformation, verify these properties:

- [ ] Resource has `aws.service.type: "gen_ai_agent"` and `aws.log.group.names`
- [ ] Tracer scope is `"strands.telemetry.tracer"` (not `__name__`)
- [ ] Agent span named `invoke_agent <name>` with `gen_ai.operation.name`, `gen_ai.system`,
      `gen_ai.agent.name`, `gen_ai.request.model`
- [ ] `execute_event_loop_cycle` span wraps model call + tool execution
- [ ] `chat` (INTERNAL) + `chat <model>` (CLIENT) spans created per model call
- [ ] Tool spans parented via `context=_active_cycle_context`
- [ ] Per-tool I/O summary emitted before `span.end()` with tool span's own `span_context`
- [ ] invoke_agent I/O summary has user-only input (no `role: "tool"`)
- [ ] I/O summary emitted after cycle context detach (gets `invoke_agent` spanId)
- [ ] `severity_text=""` on all structured logs
- [ ] `gen_ai.usage.*` token attributes on `invoke_agent` span
- [ ] All three providers shut down on exit
- [ ] `_sanitize()` applied to all user-provided strings

## Common evaluation errors and fixes

Read `references/pitfalls.md` for the complete pitfalls table. The three most common:

| Error | Cause | Fix |
|---|---|---|
| `AgentSpanMappingException: Failed to parse user_query` | `role: "tool"` in invoke_agent input | Remove — only `role: "user"` in input |
| `LogEventMissingException: span data is incomplete` | Missing per-tool I/O summary | Emit in `post_tool_use_hook` before `span.end()` |
| Per-tool I/O log gets wrong spanId | `_emit_structured_log` uses current span | Pass `span_context=` with tool span's context |

## Reference implementation

Read `references/agent_claude_reference.py` — a fully working Claude Agent SDK agent with
all OTEL instrumentation applied. It demonstrates every pattern from Steps 1–11 in a
complete, tested agent that passes all 9 AgentCore evaluators with zero errors.
