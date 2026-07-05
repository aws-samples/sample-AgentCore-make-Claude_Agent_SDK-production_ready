# Target B: Deployed AgentCore Runtime (reuse the runtime's OTEL providers)

This is the path for an agent that runs **inside a Bedrock AgentCore Runtime** with
observability enabled — either `instrumentation.enableOtel: true` in `agentcore.json` (CLI-
managed builds), or a BYO container whose `CMD` wraps `opentelemetry-instrument` with the AWS
distro. It is proven end-to-end on a live runtime: all 9 built-in evaluators returned scores
with zero `AgentSpanMappingException` / `LogEventMissingException`.

## Why this is different from the standalone reference

`references/agent_claude_reference.py` (Target A) builds its own `TracerProvider`,
`LoggerProvider`, `MeterProvider`, and SigV4 OTLP exporters. **In a deployed runtime that is
wrong** — the AWS distro (`OTEL_PYTHON_DISTRO=aws_distro` + `OTEL_PYTHON_CONFIGURATOR=
aws_configurator`, launched by `opentelemetry-instrument`) has *already* installed the global
providers, the AWS OTLP exporters, and the routing before your module imports. OpenTelemetry
providers are **set-once**: a second `TracerProvider()` / `set_logger_provider()` is silently
ignored, so any spans/logs you emit through your own providers never leave the container. The
symptom is maddening — the code looks correct, no errors, but `agentcore run eval` finds
nothing.

**So on Target B you do NOT run Steps 2–5. You reuse what the runtime set up.**

## What the runtime already provides (verified via `agentcore exec -- printenv`)

```
AGENT_OBSERVABILITY_ENABLED=true
OTEL_PYTHON_DISTRO=aws_distro
OTEL_PYTHON_CONFIGURATOR=aws_configurator
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
OTEL_TRACES_EXPORTER=otlp / OTEL_METRICS_EXPORTER=otlp / OTEL_LOGS_EXPORTER=otlp
OTEL_RESOURCE_ATTRIBUTES=service.name=<name>.DEFAULT,aws.service.type=gen_ai_agent,
    aws.log.group.names=/aws/bedrock-agentcore/runtimes/<AGENT_ID>-DEFAULT,
    cloud.resource_id=arn:aws:bedrock-agentcore:<region>:<acct>:runtime/<AGENT_ID>/runtime-endpoint/DEFAULT:DEFAULT, ...
OTEL_EXPORTER_OTLP_LOGS_HEADERS=x-aws-log-group=/aws/bedrock-agentcore/runtimes/<AGENT_ID>-DEFAULT,
    x-aws-log-stream=otel-rt-logs,x-aws-metric-namespace=bedrock-agentcore
```

Everything Step 2 (Resource) and the log-group/header wiring ask for is here **already** and
correctly `-DEFAULT`-suffixed. You just emit through the global providers and it routes right.

## Reuse the global providers (replaces Steps 2–5)

```python
from opentelemetry import baggage, context, metrics, trace
from opentelemetry._logs import SeverityNumber, get_logger_provider

try:
    from opentelemetry.sdk._logs import LogRecord            # otel-sdk < 1.40
except ImportError:
    from opentelemetry.sdk._logs._internal import LogRecord  # >= 1.40 (moved)

tracer = trace.get_tracer("strands.telemetry.tracer")   # scope name still matters

_log_provider = get_logger_provider()
_struct_logger  = _log_provider.get_logger("strands.telemetry.tracer")
_bedrock_logger = _log_provider.get_logger(
    "opentelemetry.instrumentation.botocore.bedrock-runtime",
    schema_url="https://opentelemetry.io/schemas/1.30.0",
)

_meter = metrics.get_meter("agent_metrics")
# ...create the same Strands-named instruments as in references/otel-setup.md
```

The helpers (`_sanitize`, `_iso_now`, `_emit_structured_log`, `_emit_bedrock_log`), the
tool-span tracking dicts, the `pre_tool_use_hook` / `post_tool_use_hook`, the span hierarchy,
and the I/O-summary rules (Steps 6–9) are **identical** to Target A — only the provider
acquisition changed. Emit `LogRecord`s through `_struct_logger` / `_bedrock_logger` exactly as
the standalone reference does (with `severity_text=""`, explicit `trace_id/span_id/trace_flags`,
no `resource=`).

## Disable the openinference auto-instrumentor (critical)

If the bundle depends on `openinference-instrumentation-claude-agent-sdk`, then
`opentelemetry-instrument` will auto-load it and it will emit its OWN `claude_agent_sdk`
agent/tool spans alongside your hand-built Strands-shaped spans. Two competing span trees
pollute the trace and break the evaluator's span↔log-event mapping. Disable it in the
container env (keep the dependency for local/non-eval use if you like):

```dockerfile
ENV OTEL_PYTHON_DISABLED_INSTRUMENTATIONS=claude_agent_sdk
```

## Wiring into a `build_agent_options()` / `@app.entrypoint` architecture

Real agents rarely have the standalone reference's `while True: input()` loop. Typically:
`agent.py` owns `build_agent_options()` (system prompt, tools, MCP server) and
`agent_agentcore.py` is a thin `@app.entrypoint`. Keep it that way — add instrumentation
without changing agent logic:

1. **Register the hooks in `build_agent_options()`.** Return the hooks dict from the
   instrumentation module so there's one source of truth and no duplicated logic:
   ```python
   import observability
   _hooks = observability.hooks_config()   # None when observability is off → no-op
   if _hooks is not None:
       defaults["hooks"] = _hooks
   ```
2. **Wrap the entrypoint's streaming loop with the turn driver.** The driver opens the
   `invoke_agent → execute_event_loop_cycle → chat / chat <model>` spans, iterates
   `client.receive_response()` (building `output_messages` on `ToolUseBlock`, finalizing on
   `ResultMessage`), and yields text — so the entrypoint just does:
   ```python
   @app.entrypoint
   async def invoke(payload: dict, context=None):   # 2nd param MUST be named `context`
       session_id = getattr(context, "session_id", None)
       options = build_agent_options(request_id=request_id)
       async with ClaudeSDKClient(options=options) as client:
           async for text in observability.run_instrumented(client, prompt, session_id=session_id):
               yield text
       observability.shutdown()
   ```

## Dual-mode: safe no-op when observability is off

The same file must import cleanly locally (no OTEL installed, no creds) and in unit tests.
Gate everything on a module-level flag and fall back to a plain passthrough:

```python
ENABLED = os.getenv("AGENT_OBSERVABILITY_ENABLED", "").lower() in ("1", "true", "yes")
try:
    from opentelemetry import trace, ...
except Exception:
    ENABLED = False   # OTEL not installed → stay silent, never crash

def hooks_config():
    return None if not ENABLED else {"PreToolUse": [...], "PostToolUse": [...]}

async def run_instrumented(client, user_input, *, session_id=None):
    if not ENABLED:                      # plain passthrough, byte-identical behavior
        await client.query(user_input)
        async for m in client.receive_response():
            for b in getattr(m, "content", []) or []:
                if getattr(b, "text", None):
                    yield b.text
        return
    # ... full instrumented turn ...
```

This keeps `build_agent_options()` a pure, credential-free call the fast tests exercise, and
means the deployed container is the only place telemetry actually fires.

## session.id for GoalSuccessRate

The reused ADOT pipeline may not include a `BaggageSpanProcessor`, so don't rely on baggage
alone — set `session.id` in baggage AND directly on the `invoke_agent` span attributes, and
stamp it on the structured logs (`_emit_structured_log` reads `baggage.get_baggage("session.id")`).

## Verifying it worked (before running eval)

1. Invoke the deployed agent with a fixed `--session-id` **≥ 33 chars** (`agentcore invoke`
   rejects shorter ids).
2. Wait ~2–5 min for CloudWatch ingestion.
3. Confirm your structured logs landed in the `-{ENDPOINT}` group:
   ```bash
   aws logs filter-log-events --region <r> \
     --log-group-name /aws/bedrock-agentcore/runtimes/<AGENT_ID>-DEFAULT \
     --filter-pattern '"strands.telemetry.tracer"' --max-items 3
   ```
   You should see records with `scope.name: strands.telemetry.tracer`, a `body` containing
   `input`/`output`(/`usage`), your `session.id` attribute, and valid `traceId`/`spanId`.
4. Then run all 9: `agentcore run eval --runtime <name> --session-id <sid> --evaluator
   Builtin.Helpfulness Builtin.Faithfulness Builtin.Correctness Builtin.Coherence
   Builtin.Conciseness Builtin.Harmfulness Builtin.InstructionFollowing
   Builtin.GoalSuccessRate Builtin.ToolSelectionAccuracy --json`. Success = every evaluator
   returns a numeric `aggregateScore` and no `errorMessage` / `*Exception` fields anywhere.
