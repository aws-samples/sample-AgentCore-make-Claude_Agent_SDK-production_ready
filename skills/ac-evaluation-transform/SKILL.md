---
name: ac-evaluation-transform
description: >-
  Transform a Claude Agent SDK agent to emit correct OpenTelemetry traces, structured logs,
  and CloudWatch EMF metrics so that all 9 Amazon Bedrock AgentCore Evaluation built-in
  evaluators pass with zero errors. Use this skill whenever the user mentions AgentCore
  evaluations, `agentcore run eval`, OTEL instrumentation for Claude Agent SDK agents,
  making a Claude agent compatible with Bedrock evaluations, or adding
  observability/telemetry to a Claude Agent SDK application. Also trigger when the user
  encounters AgentCore evaluation errors like AgentSpanMappingException,
  LogEventMissingException, "span data is incomplete", "missing a corresponding log
  event", or when their agent's spans appear in `aws/spans` but evaluators still report
  missing log events (the classic log-group-suffix mismatch). Covers BOTH standalone/local
  agents (build the OTEL providers yourself) AND agents deployed to an AgentCore Runtime with
  observability enabled (reuse the runtime's ADOT-configured providers) — so also trigger when
  the user wants a deployed Claude Agent SDK runtime's traces to show up in AgentCore
  Observability / GenAI dashboards. This skill modifies only the instrumentation layer — it
  never changes the agent's application logic, tools, or prompts.
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

> **Prefer zero code?** The same transform is available pre-packaged as a standard
> OpenTelemetry instrumentation plugin at
> [`packages/otel-instrumentation-claude-agent-sdk-strands/`](../../packages/otel-instrumentation-claude-agent-sdk-strands/).
> `pip install` it and run under `opentelemetry-instrument` and any Claude Agent SDK
> agent emits this exact Strands-parity telemetry with **no code changes** — it wraps
> `ClaudeSDKClient` with `wrapt` and auto-loads via an `opentelemetry_instrumentor`
> entry point. Use this skill when you want to understand the mechanics, do a bespoke
> in-code transform, or debug an evaluation failure; use the package when you just want
> a deployed agent's evaluators to pass. The package's telemetry has been verified
> end-to-end on a live AgentCore Runtime (all built-in evaluators return scores, zero
> errors).

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

## First decide: where will this agent run?

The instrumentation is the same telemetry, but **who owns the OTEL providers differs** by
deployment target. Getting this wrong is the most common reason a "correct-looking" transform
still produces zero evaluable telemetry. Pick your target before writing any code:

| Target | Who sets up the OTEL SDK? | What you do |
|---|---|---|
| **A. Standalone / local process** (a script you run yourself, `python agent.py`, a non-AgentCore container) | **You do.** Nothing configures OpenTelemetry for you. | Build the `TracerProvider` / `LoggerProvider` / `MeterProvider` + AWS OTLP exporters yourself (Steps 2–5). This is what `references/agent_claude_reference.py` shows. |
| **B. Deployed AgentCore Runtime** with `instrumentation.enableOtel: true` (or the container launched via `opentelemetry-instrument` + the AWS distro) | **The runtime does.** ADOT installs the global providers, AWS OTLP exporters, the full `OTEL_RESOURCE_ATTRIBUTES` (`cloud.resource_id`, `aws.log.group.names=…-{ENDPOINT}`, `aws.service.type`), and the `x-aws-log-group` OTLP header — before your code imports. | **REUSE the global providers.** Do NOT build your own — OTEL providers are set-once, so a second `TracerProvider()` / `LoggerProvider()` is silently ignored and your spans/logs never export. Read `references/agentcore-runtime.md`. |

**How to tell you're in target B at runtime:** `os.getenv("AGENT_OBSERVABILITY_ENABLED")` is
truthy and `OTEL_RESOURCE_ATTRIBUTES` already contains `cloud.resource_id`. In that case skip
the provider/exporter construction in Steps 2–5 and instead call `trace.get_tracer(...)`,
`get_logger_provider().get_logger(...)`, and `metrics.get_meter(...)` — the resource attributes,
exporters, and log-group routing the rest of this skill describes are already in place. Steps
6–11 (helpers, hooks, span hierarchy, I/O summaries) are **identical** for both targets.

If you're writing one agent file that must work both locally and deployed, gate the provider
setup on target B and fall back to a **no-op** when OTEL isn't available or observability is
off, so the agent never crashes in environments where telemetry isn't wanted (local dev, unit
tests). `references/agentcore-runtime.md` has the full dual-mode pattern.

## Transformation process

Work through these steps in order. Each step references a detail file — read it when you
reach that step. **Do not change the agent's application logic, tools, or prompts.**

> **Target B (deployed AgentCore Runtime) note:** Steps 2–5 build the providers/exporters
> from scratch. In a deployed runtime these already exist — reuse them (see the decision table
> above and `references/agentcore-runtime.md`) and jump to Step 6. Steps 6–11 apply to both targets.

### Step 1: Add dependencies and imports

Read `references/otel-setup.md` for the full import list and provider setup.

Required packages (Target A / standalone only — Target B gets these from the runtime image):
- `opentelemetry-api`, `opentelemetry-sdk` (**≥ 1.40** — see the two version gotchas below)
- `opentelemetry-exporter-otlp-proto-http`
- `aws-opentelemetry-distro` (provides `OTLPAwsSpanExporter` + `AwsCloudWatchEmfExporter`)
- `aws-requests-auth`, `botocore`, `requests`

**Two `opentelemetry-sdk` ≥ 1.40 gotchas (both hit live on 1.40.0, the version the current
`aws-opentelemetry-distro` 0.17.x pulls in):**
1. **`LogRecord` moved.** `from opentelemetry.sdk._logs import LogRecord` raises `ImportError`
   on ≥ 1.40 — that module now exports `LoggerProvider`, `Logger`, `LoggingHandler`,
   `ReadableLogRecord`, `ReadWriteLogRecord`, but not `LogRecord`. Import defensively so the
   same file works across versions:
   ```python
   try:
       from opentelemetry.sdk._logs import LogRecord            # < 1.40
   except ImportError:
       from opentelemetry.sdk._logs._internal import LogRecord  # >= 1.40
   ```
   The constructor still accepts `timestamp / body / severity_number / severity_text /
   trace_id / span_id / trace_flags / attributes` (verified on 1.40.0).
2. **No `resource=` kwarg.** `LogRecord(...)` no longer accepts `resource=` on ≥ 1.40 — the
   `LoggerProvider` carries the resource and attaches it at emit time. Never pass it.

### Step 2: Create the OTEL Resource

The Resource **must** include these attributes — without them, AgentCore cannot discover
the agent's spans or match them to log events:

```python
resource = Resource.create({
    "service.name": SERVICE_NAME,
    "aws.local.service": SERVICE_NAME,
    "aws.service.type": "gen_ai_agent",
    "aws.log.group.names": f"/aws/bedrock-agentcore/runtimes/{AGENT_ID}-{ENDPOINT}",
    "cloud.resource_id": (
        f"arn:aws:bedrock-agentcore:{REGION}:{ACCOUNT_ID}:"
        f"runtime/{AGENT_ID}/endpoint/{ENDPOINT}"
    ),
    "telemetry.auto.version": "0.12.2-aws",
})
```

**Critical path rules:**

- `aws.log.group.names` **must** be `/aws/bedrock-agentcore/runtimes/{AGENT_ID}-{ENDPOINT}`
  (e.g. `...HEDP-DEFAULT`). The `agentcore run eval` CLI and the AWS SDK sample in the
  [on-demand eval docs](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/getting-started-on-demand.html#download-span-logs)
  query this `-{ENDPOINT}`-suffixed group. Writing to the bare `/aws/.../runtimes/{AGENT_ID}`
  (as the 3P env-var doc example shows) causes `LogEventMissingException` because the eval
  log-matching step cannot find the I/O summary log in the group it queries.
- `cloud.resource_id` must be the full runtime endpoint ARN. Without it `agentcore run eval`
  cannot resolve spans for `--runtime-arn`, and the evaluator cannot join spans→logs.
- The **same** log-group path must be used in three places: the `aws.log.group.names`
  resource attribute, the `x-aws-log-group` OTLP header, and the EMF exporter's
  `log_group_name` kwarg. A mismatch in any one makes logs split across groups and breaks
  evaluation.

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

### Step 10: Add the session ID

`session.id` ties a session's spans together for the session-level `GoalSuccessRate`
evaluator. Put it in baggage (so the `BaggageSpanProcessor` copies it onto every span and
`_emit_structured_log` stamps it on the logs) and, belt-and-suspenders, set it directly on
the `invoke_agent` span attributes (the reused ADOT pipeline in Target B may not include a
baggage processor):

```python
if session_id:
    context.attach(baggage.set_baggage("session.id", session_id))
    agent_attrs["session.id"] = session_id   # also set on the invoke_agent span
```

**Where `session_id` comes from depends on the target:**
- **Target A (standalone):** `argparse` → `session_id = args.session_id or str(uuid.uuid4())`.
- **Target B (deployed AgentCore Runtime):** the runtime delivers it via the entrypoint's
  request context, but **only when the 2nd parameter is literally named `context`**:
  ```python
  @app.entrypoint
  async def invoke(payload: dict, context=None):   # MUST be named `context`
      session_id = getattr(context, "session_id", None)
  ```

### Step 11: Add clean shutdown

```python
provider.shutdown()        # Traces → X-Ray
_log_provider.shutdown()   # Logs → CloudWatch
_meter_provider.shutdown() # Metrics → CloudWatch EMF
```

`provider.shutdown()` must come first — it flushes trace spans with token attributes.

**Target B:** you don't hold references to providers you created, so resolve them from the
API and guard the calls (some are no-ops depending on the ADOT setup):
```python
for getter in (trace.get_tracer_provider, get_logger_provider, metrics.get_meter_provider):
    fn = getattr(getter(), "shutdown", None)
    if callable(fn):
        fn()
```
Also — the runtime handles process lifecycle, so don't shut down after every single request
if the process is long-lived; flush per-turn only if you need the final turn's spans
immediately. A `force_flush()` per turn + `shutdown()` at process exit is the safe pattern.

## Verification checklist

After transformation, verify these properties:

- [ ] Resource has `aws.service.type: "gen_ai_agent"`, `cloud.resource_id` (full
      `runtime/<id>/endpoint/<name>` ARN), and `aws.log.group.names` ending in
      `-{ENDPOINT}` (e.g. `-DEFAULT`)
- [ ] `aws.log.group.names`, the `x-aws-log-group` OTLP header, and the EMF exporter
      `log_group_name` all point to the **same** `-{ENDPOINT}`-suffixed group
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
- [ ] **Target B only:** you did NOT construct new providers/exporters — you reused the
      global ones (`trace.get_tracer` / `get_logger_provider().get_logger` /
      `metrics.get_meter`); the resource attrs + log-group header come from the runtime
- [ ] **Target B only:** the openinference `claude_agent_sdk` auto-instrumentor is disabled
      (`OTEL_PYTHON_DISABLED_INSTRUMENTATIONS=claude_agent_sdk`) so it doesn't emit competing
      spans that break span↔log matching
- [ ] **Target B only:** the entrypoint's 2nd param is named `context` (for `session_id`)
- [ ] Instrumentation is a no-op when observability is off / OTEL is missing (local + tests)

## Common evaluation errors and fixes

Read `references/pitfalls.md` for the complete pitfalls table. The three most common:

| Error | Cause | Fix |
|---|---|---|
| `AgentSpanMappingException: Failed to parse user_query` | `role: "tool"` in invoke_agent input | Remove — only `role: "user"` in input |
| `LogEventMissingException: ...invoke_agent <name> is missing a corresponding log event` | Logs exported to `/runtimes/{AGENT_ID}` but eval queries `/runtimes/{AGENT_ID}-{ENDPOINT}` | Use `{AGENT_ID}-{ENDPOINT}` in **all three** places (resource attr, OTLP header, EMF exporter) |
| `LogEventMissingException: ...tool.<name>` | Missing per-tool I/O summary | Emit in `post_tool_use_hook` before `span.end()` |
| Eval can't discover any spans for `--runtime-arn` | Resource missing `cloud.resource_id` | Add full endpoint ARN `arn:aws:bedrock-agentcore:<region>:<acct>:runtime/<id>/endpoint/<name>` |
| `TypeError: LogRecord.__init__() got unexpected keyword 'resource'` | opentelemetry-sdk ≥ 1.40 removed the kwarg | Drop `resource=resource` from every `LogRecord(...)` call; the LoggerProvider already carries the resource |
| `ImportError: cannot import name 'LogRecord' from 'opentelemetry.sdk._logs'` | opentelemetry-sdk ≥ 1.40 moved it to `_logs._internal` | `try: from opentelemetry.sdk._logs import LogRecord` / `except ImportError: from opentelemetry.sdk._logs._internal import LogRecord` |
| Per-tool I/O log gets wrong spanId | `_emit_structured_log` uses current span | Pass `span_context=` with tool span's context |
| **Deployed runtime:** spans/logs never appear even though the code "looks right" | Rebuilt your own `TracerProvider`/`LoggerProvider` on top of the runtime's ADOT setup — OTEL is set-once, so yours is ignored | Reuse the global providers via `get_tracer`/`get_logger_provider`/`get_meter` (Target B, `references/agentcore-runtime.md`) |
| **Deployed runtime:** duplicate/overlapping agent + tool spans, evaluator can't map spans→logs | The openinference `claude_agent_sdk` auto-instrumentor also emitted spans alongside your hand-built ones | Set `OTEL_PYTHON_DISABLED_INSTRUMENTATIONS=claude_agent_sdk` in the container env |
| **Deployed runtime:** `session_id` is always `None`, `GoalSuccessRate` can't group the session | Entrypoint 2nd param isn't named `context` | Name it exactly `context`: `async def invoke(payload, context=None)` |

## Reference implementations

- `references/agent_claude_reference.py` — **Target A (standalone).** A fully working Claude
  Agent SDK CLI agent that builds all providers/exporters itself and applies every pattern
  from Steps 1–11. Passes all 9 AgentCore evaluators with zero errors.
- `references/agentcore-runtime.md` — **Target B (deployed AgentCore Runtime).** How to
  reuse the runtime's ADOT-configured global providers instead of building your own, wire
  the hooks + turn driver into a `build_agent_options()` / `@app.entrypoint` architecture,
  the dual-mode no-op fallback, and the container env (`OTEL_PYTHON_DISABLED_INSTRUMENTATIONS`).
  This is the path proven end-to-end on a live AgentCore Runtime (all 9 evaluators returned
  scores, zero errors).
- [`packages/otel-instrumentation-claude-agent-sdk-strands/`](../../packages/otel-instrumentation-claude-agent-sdk-strands/)
  — **the packaged, zero-code form of this skill.** A pip-installable
  `BaseInstrumentor` that applies the Target-B patterns automatically via `wrapt`
  interception of `ClaudeSDKClient` (no `run_instrumented`-style loop rewrite, no hook
  wiring in your agent). Install it + `opentelemetry-instrument` and you're done. Reach
  for the package to ship; reach for this skill to learn, customize, or debug.
