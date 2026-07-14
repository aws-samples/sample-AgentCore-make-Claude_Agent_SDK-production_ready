# otel-instrumentation-claude-agent-sdk-strands

Zero-code OpenTelemetry instrumentation for the **Claude Agent SDK** that emits
**Strands-parity** telemetry — the shape that **Amazon Bedrock AgentCore
Evaluation** can actually parse.

## Why this exists

AgentCore Evaluation does not accept arbitrary `gen_ai.*` telemetry. It gates on:

1. **Instrumentation scope** — only `strands.telemetry.tracer`,
   `opentelemetry.instrumentation.langchain`, or
   `openinference.instrumentation.langchain`.
2. **Structured log events** — the user query / agent response / tool output must
   live in the Strands **event body** (`body.input.messages` /
   `body.output.messages` / per-tool `tool.result`), not on span attributes.

The general-purpose [`otel-instrumentation-claude-agent-sdk`](https://pypi.org/project/otel-instrumentation-claude-agent-sdk/)
package emits valid `gen_ai.*` spans — perfect for the CloudWatch **Observability**
dashboard — but it satisfies neither gate, so **Evaluation** rejects every session
(`AgentSpanMappingException` / `ToolSpanMappingException`).

This package produces the evaluation-parseable Strands shape transparently, so a
Claude Agent SDK agent passes all of AgentCore's built-in evaluators with **no
code changes**.

## Install & use

```bash
pip install otel-instrumentation-claude-agent-sdk-strands
```

**Zero-code (recommended)** — launch under the OTEL auto-instrumentor:

```bash
opentelemetry-instrument python your_agent.py
```

**Explicit** — if you prefer a call:

```python
from otel_instrumentation_claude_agent_sdk_strands import (
    ClaudeAgentSdkStrandsInstrumentor,
)

ClaudeAgentSdkStrandsInstrumentor().instrument(agent_name="my-agent")
# ... use ClaudeSDKClient exactly as normal ...
```

Your agent keeps its ordinary loop:

```python
async with ClaudeSDKClient(options=options) as client:
    await client.query(prompt)
    async for message in client.receive_response():   # instrumented transparently
        ...
```

## What it emits

- **Spans** (`strands.telemetry.tracer` scope):
  `invoke_agent → execute_event_loop_cycle → chat` / `chat <model>` (CLIENT) and
  `tool.<name>` for each tool call, with `gen_ai.*` attributes and token usage.
- **Structured I/O logs** — one invoke-level summary (`input`/`output`/`usage`)
  and one per tool call, in the Strands event-body schema.
- **Bedrock-format per-message logs**
  (`opentelemetry.instrumentation.botocore.bedrock-runtime` scope).
- **Strands-named metrics** (`strands.event_loop.*`, `strands.tool.*`,
  `gen_ai.client.*`).

## Configuration

| kwarg | env | default |
|---|---|---|
| `agent_name` | `OTEL_SERVICE_NAME` | `"claude-agent"` |
| `model` | `GEN_AI_REQUEST_MODEL` / `CLAIMCLEAR_MODEL` | inherited from options |
| `capture_content` | `OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT` | `true` |
| `session_id` | (else OTEL baggage `session.id`, else `ResultMessage.session_id`) | — |

`session.id` ties a session's spans together for the session-level
`GoalSuccessRate` evaluator. In an AgentCore Runtime, set it from the request
`context.session_id` into OTEL baggage before invoking, or pass
`instrument(session_id=...)`.

## Deployment targets

- **Deployed AgentCore Runtime (Target B):** the runtime's ADOT setup
  (`opentelemetry-instrument` + the AWS distro) installs the global providers,
  OTLP exporters, and `-{ENDPOINT}`-suffixed log-group routing. This package
  **reuses** those providers — install it and it just works.
- **Standalone (Target A):** build your own providers/exporters (AWS SigV4 OTLP)
  before calling `instrument()`, as with any OpenTelemetry app.

## Supported surface & limitations

This release targets the **most common Claude Agent SDK pattern** and is verified
against it end-to-end (all built-in AgentCore evaluators pass, zero errors):

- ✅ A `ClaudeSDKClient` used as `await client.query(...)` → `async for message in
  client.receive_response()`.
- ✅ `TextBlock` and `ToolUseBlock` content; in-process (`@tool`) and MCP tools.
- ✅ Subagents (Task tool) and user-defined Pre/PostToolUse hooks (merged, not
  replaced).
- ✅ Deployed on AgentCore Runtime with observability enabled (reuses the ADOT
  global providers).

Not yet covered (telemetry may be incomplete for these — roadmap):

- ⏳ The **module-level `query()`** one-shot helper — only `ClaudeSDKClient` is
  wrapped today. An agent written as `async for m in query(...)` gets no telemetry.
- ⏳ The lower-level **`receive_messages()`** iterator (turn won't finalize).
- ⏳ **Extended thinking** (`ThinkingBlock`) and **server-side tools**
  (`ServerToolUseBlock` / `ServerToolResultBlock`, e.g. web search) — these bypass
  the tool hooks, so they get no tool span / per-tool log.
- ⏳ **Streaming (`AsyncIterable`) prompts** — the user query is captured only when
  the prompt is a string.
- ⏳ **Concurrent turns on a single client** (`asyncio.gather`) — per-turn state is
  single-slot per instance.

If your agent uses one of the ⏳ paths, telemetry (and therefore evaluation
coverage) may be partial. These are tracked for a follow-up; contributions
welcome.

## Coexistence

Do not run this alongside `otel-instrumentation-claude-agent-sdk` — both wrap the
same functions and would double-emit. For Evaluation, use only this one (or set
`OTEL_PYTHON_DISABLED_INSTRUMENTATIONS=claude-agent-sdk` to disable the other).

## License

MIT-0.
