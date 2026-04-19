# Pitfalls and Fixes

Common errors encountered when instrumenting Claude Agent SDK agents for AgentCore
Evaluations, organized by category.

## Evaluation-specific errors

| Problem | Cause | Fix |
|---|---|---|
| `AgentSpanMappingException: Failed to parse user_query` | `input.messages` at invoke_agent level contains `role: "tool"` alongside `role: "user"` | Remove all `role: "tool"` from invoke_agent-level `input.messages`; only user message |
| `LogEventMissingException: ...invoke_agent <name> is missing a corresponding log event` despite the I/O summary log existing in CloudWatch | Logs were exported to `/aws/bedrock-agentcore/runtimes/{AGENT_ID}` (bare), but the eval log-matcher queries `/aws/bedrock-agentcore/runtimes/{AGENT_ID}-{ENDPOINT}` (e.g. `-DEFAULT`) — see the AWS SDK sample in the [on-demand docs](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/getting-started-on-demand.html#download-span-logs) | Change `aws.log.group.names`, `x-aws-log-group` header, and EMF `log_group_name` **all** to the `-{ENDPOINT}`-suffixed path. Verify with `aws logs describe-log-streams --log-group-name /aws/bedrock-agentcore/runtimes/<id>-<endpoint>` |
| `agentcore run eval --runtime-arn ...` returns no spans / empty session list | Resource missing `cloud.resource_id` (required for runtime-arn → span filtering) | Add `"cloud.resource_id": "arn:aws:bedrock-agentcore:<region>:<acct>:runtime/<id>/endpoint/<name>"` to the Resource |
| `TypeError: LogRecord.__init__() got an unexpected keyword argument 'resource'` | opentelemetry-sdk ≥ 1.40 removed the `resource` kwarg from `LogRecord` | Drop `resource=resource` from every `LogRecord(...)` — the `LoggerProvider`'s resource is attached automatically at emit time |
| `LogEventMissingException: Session span data is incomplete. Span with ID: <id> and name: tool.<name>` | Each tool span needs its own I/O summary log, but only invoke_agent had one | Emit per-tool I/O summary in `post_tool_use_hook` before `span.end()`, using tool span's `span_context=` |
| Per-tool I/O log gets wrong spanId | `_emit_structured_log` uses `trace.get_current_span()` which is the cycle span | Pass `span_context=(tid, sid, flags)` from tool span's own context |
| "traceIds that do not exist in the provided data" | `aws/spans` log group is empty because X-Ray export failed | Fix X-Ray export (use `OTLPAwsSpanExporter`); don't write to `aws/spans` directly |
| Fresh runs stop appearing in `aws/spans` | Transaction Search not enabled, or X-Ray ingestion throttled | Confirm Transaction Search is **on** in CloudWatch (required per [on-demand prereqs](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/getting-started-on-demand.html#prerequisites-on-demand)); wait 2–5 min after a run before evaluating |
| Duplicate bare-string tool result entries in output | Code appended `{"content": "<json>", "role": "assistant"}` as bare strings | Remove duplicates; tool results are in the `tool.result` key of tool-calling messages |

## Trace/span errors

| Problem | Cause | Fix |
|---|---|---|
| Tool spans in separate traceId | Hook runs in Claude SDK async context without OTel context | Pass `context=_active_cycle_context` to `tracer.start_span()` in `pre_tool_use_hook` |
| I/O summary log gets wrong spanId (cycle instead of invoke_agent) | Emitted while `execute_event_loop_cycle` is current span | Emit after `context.detach(_cycle_ctx)` so `invoke_agent` is current |
| Empty `traceId` on tool hook logs | Hooks run outside the OTel span context | Save span context in main loop at `ToolUseBlock`; pass via `_tool_span_contexts` |
| Token counts not visible per session | (1) Wrong tracer scope, (2) missing GenAI attributes, (3) no `gen_ai.usage.*` on span | Fix all three: scope=`strands.telemetry.tracer`, standard attributes, token usage attrs |
| Missing `status.code = OK` | Not auto-set by manual instrumentation | `agent_span.set_status(trace.Status(trace.StatusCode.OK))` |

## Export errors

| Problem | Cause | Fix |
|---|---|---|
| `403 Missing Authentication Token` / zero traces | `OTLPSpanExporter` + `BotoAWSRequestsAuth` signs before body serialization | Use `OTLPAwsSpanExporter` from `amazon.opentelemetry.distro` |
| `ConnectionRefusedError: localhost:4318` | No explicit `endpoint=` on exporter | Pass `endpoint=f"https://xray.{region}.amazonaws.com/v1/traces"` |
| Zero traces, no visible errors | `BatchSpanProcessor` silently drops export failures | Add `logging.basicConfig(level=logging.WARNING)` at module top |
| `400: CRequest headers... cannot be null or empty` | Missing routing headers on log exporter | Add `headers={"x-aws-log-group": ..., "x-aws-log-stream": ..., "x-aws-metric-namespace": ...}` |
| `CloudWatchLogClient.__init__() missing 'session'` | EMF exporter needs botocore session | Pass `session=botocore.session.Session()` |

## Log format errors

| Problem | Cause | Fix |
|---|---|---|
| `TypeError: int() argument... not 'NoneType'` | `trace_flags=None` in `LogRecord` | Use `0` as fallback, not `None` |
| `UnicodeEncodeError: surrogates not allowed` | Terminal `input()` produces surrogate chars | `_sanitize()` with `.encode("utf-8", errors="replace").decode("utf-8")` |
| `severityText` mismatch | Strands uses `""`, code used `"INFO"` | Set `severity_text=""` in all `LogRecord` constructors |
| `gen_ai.tool.message` has Python repr | `str(tool_response)` on dict/list | Extract text from content items; handle dict and list formats |
| I/O summary missing `usage` key | `ResultMessage.usage` was `None`; proto3 drops zero-valued dict | Set `usage_summary = "unavailable"` (string survives serialization) |
| Tool metrics use MCP-prefixed names | Names like `mcp__tools__word_count` | `_strip_tool_prefix()` extracts plain name via `name.split("__")[-1]` |

## Metric errors

| Problem | Cause | Fix |
|---|---|---|
| Token usage EMF has wrong structure | Defined as Counter instead of Histogram | Use `create_histogram()` |
| Token usage EMF missing model dimensions | Only `gen_ai.token.type` dimension | Add all 6 dimensions via `_BEDROCK_ATTRS` |
| Token usage EMF `Unit` mismatch | `unit="Count"` set but Strands omits it | Remove `unit=` from `create_histogram("gen_ai.client.token.usage")` |
| `gen_ai.system` is `"anthropic"` | Claude SDK calls Anthropic API directly | Change to `"aws.bedrock"` in `_BEDROCK_ATTRS` |
| Logs from final interaction lost | `BatchLogRecordProcessor` not flushed | Call `_log_provider.shutdown()` on exit |
| Traces from final interaction lost | `TracerProvider` not shut down | Call `provider.shutdown()` before log/metric shutdown |

## Hook registration errors

| Problem | Cause | Fix |
|---|---|---|
| `TypeError: 'function' object is not iterable` | `hooks` expects `dict[str, list[HookMatcher]]`, not bare functions | Wrap in `HookMatcher(hooks=[callback])` inside a list |
