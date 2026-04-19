import argparse
import json
import logging
import os
import re
import time
import uuid
from datetime import datetime, timezone
from urllib.parse import urlparse

logging.basicConfig(level=logging.WARNING)
_logger = logging.getLogger(__name__)

import anyio
import botocore.session
import requests as _requests
from amazon.opentelemetry.distro.exporter.aws.metrics.aws_cloudwatch_emf_exporter import (
    AwsCloudWatchEmfExporter,
)
from aws_requests_auth.boto_utils import BotoAWSRequestsAuth
from claude_agent_sdk import (
    ClaudeSDKClient,
    ClaudeAgentOptions,
    create_sdk_mcp_server,
    tool,
    AssistantMessage,
    ResultMessage,
    TextBlock,
    ToolUseBlock,
    ToolResultBlock,
)
from claude_agent_sdk.types import HookMatcher
from opentelemetry import baggage, context, metrics, trace
from opentelemetry._logs import set_logger_provider, SeverityNumber
from opentelemetry.sdk._logs import LoggerProvider, LogRecord
from opentelemetry.sdk._logs.export import BatchLogRecordProcessor
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import SpanProcessor, TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.http._log_exporter import OTLPLogExporter
from amazon.opentelemetry.distro.exporter.otlp.aws.traces.otlp_aws_span_exporter import OTLPAwsSpanExporter

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
_service_name = "super-simple-agent-claude"
# Substitute with the real AgentCore runtime id + endpoint (usually DEFAULT).
_agent_id = os.environ.get("AGENTCORE_AGENT_ID", f"{_service_name}-1234567890")
_endpoint = os.environ.get("AGENTCORE_ENDPOINT", "DEFAULT")

# Resolve region from OTEL_EXPORTER_OTLP_ENDPOINT or environment
_traces_endpoint = os.environ.get(
    "OTEL_EXPORTER_OTLP_ENDPOINT", "https://xray.us-east-1.amazonaws.com"
)
_parsed = urlparse(_traces_endpoint)
_region_match = re.search(r"\.([a-z]{2}-[a-z]+-\d)\.amazonaws\.com", _parsed.hostname or "")
_region = _region_match.group(1) if _region_match else os.environ.get("AWS_REGION", "us-east-1")
_account_id = os.environ.get("AWS_ACCOUNT_ID", "000000000000")

# The -{endpoint}-suffixed log group is what agentcore run eval queries for
# I/O summary logs. Override via AGENT_LOG_GROUP only if you know what you're doing.
_log_group_path = os.environ.get(
    "AGENT_LOG_GROUP",
    f"/aws/bedrock-agentcore/runtimes/{_agent_id}-{_endpoint}",
)
_cloud_resource_id = (
    f"arn:aws:bedrock-agentcore:{_region}:{_account_id}:"
    f"runtime/{_agent_id}/endpoint/{_endpoint}"
)

# ---------------------------------------------------------------------------
# SigV4 sessions
# ---------------------------------------------------------------------------
# Logs -> CloudWatch Logs (SigV4 service: logs)
_logs_host = f"logs.{_region}.amazonaws.com"
_logs_endpoint = f"https://{_logs_host}/v1/logs"
_log_session = _requests.Session()
_log_session.auth = BotoAWSRequestsAuth(
    aws_host=_logs_host,
    aws_region=_region,
    aws_service="logs",
)

# ---------------------------------------------------------------------------
# OTEL Resource  (#1: add telemetry.auto.version to match Strands)
# ---------------------------------------------------------------------------
resource = Resource.create({
    "service.name": _service_name,
    "aws.local.service": _service_name,
    "aws.service.type": "gen_ai_agent",
    "aws.log.group.names": _log_group_path,
    "cloud.resource_id": _cloud_resource_id,
    "telemetry.auto.version": "0.12.2-aws",
})

# ---------------------------------------------------------------------------
# Traces
# ---------------------------------------------------------------------------

class _BaggageSpanProcessor(SpanProcessor):
    """Copy all OTEL baggage entries into span attributes on start."""

    def on_start(self, span, parent_context=None):
        ctx = parent_context or context.get_current()
        for key, value in baggage.get_all(ctx).items():
            span.set_attribute(key, value)


provider = TracerProvider(resource=resource)
provider.add_span_processor(_BaggageSpanProcessor())
_traces_otlp_endpoint = f"https://xray.{_region}.amazonaws.com/v1/traces"
provider.add_span_processor(
    BatchSpanProcessor(OTLPAwsSpanExporter(aws_region=_region, session=botocore.session.Session(), endpoint=_traces_otlp_endpoint))
)
trace.set_tracer_provider(provider)
tracer = trace.get_tracer("strands.telemetry.tracer")

_AGENT_NAME = "super-simple-agent-claude"

# ---------------------------------------------------------------------------
# Logs  (#3/#4/#5: scope="strands.telemetry.tracer", event.name same, severityText="")
# ---------------------------------------------------------------------------
_log_provider = LoggerProvider(resource=resource)
_log_provider.add_log_record_processor(
    BatchLogRecordProcessor(OTLPLogExporter(
        endpoint=_logs_endpoint,
        session=_log_session,
        headers={
            # Must match aws.log.group.names resource attr exactly.
            "x-aws-log-group": _log_group_path,
            "x-aws-log-stream": "runtime-logs",
            "x-aws-metric-namespace": "bedrock-agentcore",
        },
    ))
)
set_logger_provider(_log_provider)

# Strands-compatible structured logger (scope name matches Strands exactly)
_struct_logger = _log_provider.get_logger("strands.telemetry.tracer")

# Bedrock-runtime format logger (gen_ai.choice, gen_ai.user.message, etc.)
_bedrock_logger = _log_provider.get_logger(
    "opentelemetry.instrumentation.botocore.bedrock-runtime",
    schema_url="https://opentelemetry.io/schemas/1.30.0",
)

# ---------------------------------------------------------------------------
# Metrics — OTEL SDK + AwsCloudWatchEmfExporter (same pipeline as Strands)
# ---------------------------------------------------------------------------
_emf_exporter = AwsCloudWatchEmfExporter(
    namespace="bedrock-agentcore",
    log_group_name=_log_group_path,
    log_stream_name="runtime-logs",
    aws_region=_region,
    session=botocore.session.Session(),
)
_meter_provider = MeterProvider(
    resource=resource,
    metric_readers=[PeriodicExportingMetricReader(_emf_exporter, export_interval_millis=5000)],
)
metrics.set_meter_provider(_meter_provider)
_meter = metrics.get_meter("agent_claude")

# Bedrock dimension values (matching Strands auto-instrumentation format)
_BEDROCK_ATTRS = {
    "gen_ai.system": "aws.bedrock",
    "server.address": f"bedrock-runtime.{_region}.amazonaws.com",
    "server.port": "443",
    "gen_ai.request.model": "us.anthropic.claude-sonnet-4-20250514-v1:0",
    "gen_ai.operation.name": "chat",
}

# --- Strands event_loop metrics (#9) ---
_cycle_count = _meter.create_counter("strands.event_loop.cycle_count", unit="Count")
_start_cycle = _meter.create_counter("strands.event_loop.start_cycle", unit="Count")
_end_cycle = _meter.create_counter("strands.event_loop.end_cycle", unit="Count")
_cycle_duration = _meter.create_histogram("strands.event_loop.cycle_duration", unit="Seconds")
_loop_input_tokens = _meter.create_histogram("strands.event_loop.input.tokens")
_loop_output_tokens = _meter.create_histogram("strands.event_loop.output.tokens")
_loop_latency = _meter.create_histogram("strands.event_loop.latency", unit="Milliseconds")
_model_ttft = _meter.create_histogram("strands.model.time_to_first_token", unit="Milliseconds")

# --- Strands tool metrics (#9) ---
_strands_tool_call_count = _meter.create_counter("strands.tool.call_count", unit="Count")
_strands_tool_duration = _meter.create_histogram("strands.tool.duration", unit="Seconds")
_strands_tool_success_count = _meter.create_counter("strands.tool.success_count", unit="Count")

# --- gen_ai.client metrics (#2: add operation.duration; token.usage already present) ---
_operation_duration = _meter.create_histogram("gen_ai.client.operation.duration", unit="Seconds")
_token_usage = _meter.create_histogram("gen_ai.client.token.usage")


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def _sanitize(value: str) -> str:
    """Replace surrogate characters that the OTLP exporter cannot encode."""
    return value.encode("utf-8", errors="replace").decode("utf-8")


def _iso_now():
    """Return current UTC time as ISO-8601 string."""
    return datetime.now(timezone.utc).isoformat()


def _emit_structured_log(body, attributes=None, span_context=None):
    """Emit a structured dict-body log under the strands.telemetry.tracer scope.

    Args:
        span_context: Optional (trace_id, span_id, trace_flags) tuple to use
                      instead of the current span context.
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
        severity_text="",
        trace_id=tid,
        span_id=sid,
        trace_flags=flags,
        attributes=merged_attrs or None,
    )
    _struct_logger.emit(record)


def _emit_bedrock_log(body, event_name, span_context=None):
    """Emit a log under the opentelemetry.instrumentation.botocore.bedrock-runtime scope.

    Args:
        span_context: Optional (trace_id, span_id, trace_flags) tuple to use
                      instead of the current span context.
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
        trace_id=tid,
        span_id=sid,
        trace_flags=flags,
        attributes={"event.name": event_name, "gen_ai.system": "aws.bedrock"},
    )
    _bedrock_logger.emit(record)


# Track in-flight tool spans, timing, span contexts, and results
_tool_spans: dict[str, trace.Span] = {}
_tool_start_times: dict[str, float] = {}
_tool_span_contexts: dict[str, tuple] = {}
_tool_inputs: dict[str, dict] = {}  # tool_use_id -> tool input args
_tool_results: dict[str, list] = {}  # tool_use_id -> result content list
_active_cycle_context = None  # Parent context for tool spans (set during cycle)


def _strip_tool_prefix(name: str) -> str:
    """Strip the ``mcp__<server>__`` prefix from MCP tool names."""
    return name.split("__")[-1] if "__" in name else name


# ---------------------------------------------------------------------------
# Tools
# ---------------------------------------------------------------------------
@tool("word_count", "Count the number of words in the given text", {"text": str})
async def word_count(args):
    count = len(args["text"].split())
    return {"content": [{"type": "text", "text": str(count)}]}


@tool("reverse_string", "Reverse the given text string", {"text": str})
async def reverse_string(args):
    reversed_text = args["text"][::-1]
    return {"content": [{"type": "text", "text": reversed_text}]}


# ---------------------------------------------------------------------------
# Hooks
# ---------------------------------------------------------------------------
async def pre_tool_use_hook(hook_input, tool_use_id, hook_context):
    tool_name = hook_input["tool_name"]
    tool_input = hook_input["tool_input"]

    # Trace span (parent to cycle span so it shares the same traceId)
    span = tracer.start_span(
        f"tool.{tool_name}",
        context=_active_cycle_context,
        attributes={
            "tool.input": _sanitize(str(tool_input)),
            "gen_ai.tool.name": _strip_tool_prefix(tool_name),
            "gen_ai.tool.call.id": tool_use_id or "",
            "gen_ai.operation.name": "execute_tool",
            "gen_ai.event.start_time": _iso_now(),
        }
    )
    if tool_use_id:
        _tool_spans[tool_use_id] = span
        _tool_start_times[tool_use_id] = time.time()
        _tool_inputs[tool_use_id] = tool_input

    return {}


async def post_tool_use_hook(hook_input, tool_use_id, hook_context):
    tool_name = hook_input.get("tool_name", "unknown")
    tool_response = hook_input.get("tool_response", "")
    plain_name = _strip_tool_prefix(tool_name)

    # End trace span (but don't call .end() yet — emit I/O log first)
    span = _tool_spans.pop(tool_use_id, None) if tool_use_id else None
    start_time = _tool_start_times.pop(tool_use_id, None) if tool_use_id else None
    tool_input_args = _tool_inputs.pop(tool_use_id, {}) if tool_use_id else {}
    if span:
        span.set_attribute("tool.output", _sanitize(str(tool_response)))
        span.set_attribute("gen_ai.tool.status", "success")
        span.set_attribute("gen_ai.event.end_time", _iso_now())

    # Retrieve saved span context from pre_tool_use_hook
    saved_ctx = _tool_span_contexts.pop(tool_use_id, None) if tool_use_id else None

    # Build result content list — extract plain text from content items
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

    # Store result for I/O summary enrichment
    if tool_use_id:
        _tool_results[tool_use_id] = result_content

    # Per-tool I/O summary log (matches Strands per-cycle tool pattern)
    # Emitted under the tool span so the evaluator can find it.
    if span and tool_use_id:
        tool_span_ctx = span.get_span_context()
        tool_io_body = {
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
        }
        _emit_structured_log(tool_io_body, span_context=(
            tool_span_ctx.trace_id,
            tool_span_ctx.span_id,
            tool_span_ctx.trace_flags,
        ))
        span.end()
    elif span:
        span.end()

    # Bedrock-format log: gen_ai.tool.message
    _emit_bedrock_log(
        {"content": result_content, "id": tool_use_id or ""},
        "gen_ai.tool.message",
        span_context=saved_ctx,
    )

    # Bedrock-format log: gen_ai.user.message with toolResult
    _emit_bedrock_log(
        {"content": [{"toolResult": {
            "toolUseId": tool_use_id or "",
            "content": result_content,
            "status": "success",
        }}]},
        "gen_ai.user.message",
        span_context=saved_ctx,
    )

    # Strands tool metrics (use plain tool name)
    tool_attrs = {"tool_name": plain_name, "tool_use_id": tool_use_id or ""}
    duration = time.time() - start_time if start_time else 0
    _strands_tool_call_count.add(1, tool_attrs)
    _strands_tool_duration.record(duration, tool_attrs)
    _strands_tool_success_count.add(1, tool_attrs)

    return {}


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--session-id", default=None, help="Session ID for trace correlation")
    args = parser.parse_args()

    session_id = args.session_id or str(uuid.uuid4())
    ctx = baggage.set_baggage("session.id", session_id)
    context.attach(ctx)

    server = create_sdk_mcp_server(
        name="tools",
        version="1.0.0",
        tools=[word_count, reverse_string],
    )
    options = ClaudeAgentOptions(
        mcp_servers={"tools": server},
        allowed_tools=["mcp__tools__word_count", "mcp__tools__reverse_string"],
        hooks={
            "PreToolUse": [HookMatcher(hooks=[pre_tool_use_hook])],
            "PostToolUse": [HookMatcher(hooks=[post_tool_use_hook])],
        },
    )

    print(f"Session ID: {session_id}")

    # Conversation history for bedrock-runtime format logs.
    conversation_history: list[dict] = []

    async with ClaudeSDKClient(options=options) as client:
        while True:
            user_input = input("\nYou: ")
            if user_input.lower() in ("quit", "exit"):
                break

            query_start = time.time()
            cycle_id = str(uuid.uuid4())

            with tracer.start_as_current_span(
                f"invoke_agent {_AGENT_NAME}",
                attributes={
                    "user.input": _sanitize(user_input),
                    "gen_ai.operation.name": "invoke_agent",
                    "gen_ai.system": "aws.bedrock",
                    "gen_ai.agent.name": _AGENT_NAME,
                    "gen_ai.request.model": "us.anthropic.claude-sonnet-4-20250514-v1:0",
                    "gen_ai.agent.tools": '["word_count", "reverse_string"]',
                    "gen_ai.event.start_time": _iso_now(),
                },
            ) as agent_span:
                # Strands event_loop metrics: start cycle (#9)
                _start_cycle.add(1, {"event_loop_cycle_id": cycle_id})
                _cycle_count.add(1, {"event_loop_cycle_id": cycle_id})

                # Bedrock-format logs: replay conversation history
                for msg in conversation_history:
                    _emit_bedrock_log(
                        {"content": [{"text": msg["text"]}]},
                        f"gen_ai.{msg['role']}.message",
                    )
                # Bedrock-format log: current user input
                _emit_bedrock_log(
                    {"content": [{"text": _sanitize(user_input)}]},
                    "gen_ai.user.message",
                )

                # execute_event_loop_cycle span (wraps model call + tool execution)
                global _active_cycle_context
                cycle_span = tracer.start_span("execute_event_loop_cycle", attributes={
                    "gen_ai.event.start_time": _iso_now(),
                })
                _active_cycle_context = trace.set_span_in_context(cycle_span)
                _cycle_ctx = context.attach(_active_cycle_context)

                # Model invocation span (matches Strands start_model_invoke_span)
                chat_start = time.time()
                chat_span = tracer.start_span("chat", attributes={
                    "gen_ai.operation.name": "chat",
                    "gen_ai.system": "aws.bedrock",
                    "gen_ai.request.model": "us.anthropic.claude-sonnet-4-20250514-v1:0",
                    "gen_ai.event.start_time": _iso_now(),
                })

                # Botocore-level CLIENT span (matches botocore instrumentation)
                client_span = tracer.start_span(
                    "chat us.anthropic.claude-sonnet-4-20250514-v1:0",
                    kind=trace.SpanKind.CLIENT,
                    attributes={
                        "gen_ai.operation.name": "chat",
                        "gen_ai.system": "aws.bedrock",
                        "gen_ai.request.model": "us.anthropic.claude-sonnet-4-20250514-v1:0",
                        "gen_ai.event.start_time": _iso_now(),
                    },
                )

                await client.query(user_input)

                output_messages: list[dict] = []
                last_response_text = ""
                first_token_time = None
                # Track tool use blocks for I/O summary enrichment
                pending_text_blocks: list[str] = []
                tool_use_records: list[dict] = []  # {id, name, input, preceding_text}

                async for message in client.receive_response():
                    if isinstance(message, AssistantMessage):
                        for block in message.content:
                            if isinstance(block, TextBlock):
                                if first_token_time is None:
                                    first_token_time = time.time()

                                pending_text_blocks.append(block.text)
                                last_response_text = block.text
                                print(f"\nAgent: {block.text}")

                            elif isinstance(block, ToolUseBlock):
                                if first_token_time is None:
                                    first_token_time = time.time()

                                # Save span context NOW (inside the active span)
                                # so post_tool_use_hook can use it later
                                _cur = trace.get_current_span()
                                if _cur and block.id:
                                    _sc = _cur.get_span_context()
                                    if _sc and _sc.is_valid:
                                        _tool_span_contexts[block.id] = (
                                            _sc.trace_id, _sc.span_id, _sc.trace_flags,
                                        )

                                plain_name = _strip_tool_prefix(block.name)
                                tool_input = block.input if hasattr(block, "input") else {}

                                # Build content array with text + toolUse
                                assistant_content = []
                                for t in pending_text_blocks:
                                    assistant_content.append({"text": t})
                                assistant_content.append({"toolUse": {
                                    "name": plain_name,
                                    "input": tool_input,
                                    "toolUseId": block.id,
                                }})

                                tool_call_entry = {
                                    "type": "function",
                                    "id": block.id,
                                    "function": {
                                        "name": plain_name,
                                        "arguments": tool_input,
                                    },
                                }

                                # Bedrock-format log: gen_ai.assistant.message
                                _emit_bedrock_log({
                                    "content": assistant_content,
                                    "tool_calls": [tool_call_entry],
                                }, "gen_ai.assistant.message")

                                # Bedrock-format log: gen_ai.choice with finish_reason: "tool_use"
                                _emit_bedrock_log({
                                    "message": {
                                        "tool_calls": [tool_call_entry],
                                        "role": "assistant",
                                    },
                                    "index": 0,
                                    "finish_reason": "tool_use",
                                }, "gen_ai.choice")

                                # Record for I/O summary
                                tool_use_records.append({
                                    "id": block.id,
                                    "name": plain_name,
                                    "input": tool_input,
                                    "preceding_text": list(pending_text_blocks),
                                })

                                # Add tool-calling output message for I/O summary
                                # Use "content" key (not "message") for intermediate
                                # toolUse messages — matches Strands pattern.
                                content_json = json.dumps(assistant_content)
                                output_messages.append({
                                    "content": {"content": content_json},
                                    "role": "assistant",
                                })
                                pending_text_blocks.clear()

                    elif isinstance(message, ResultMessage):
                        query_duration = time.time() - query_start
                        usage = message.usage or {}

                        # If there's remaining text that wasn't followed by a tool call,
                        # it's the final response text block.
                        if pending_text_blocks:
                            for t in pending_text_blocks:
                                # Bedrock-format log: gen_ai.assistant.message (text only)
                                _emit_bedrock_log({
                                    "content": [{"text": t}],
                                }, "gen_ai.assistant.message")

                                # Bedrock-format log: gen_ai.choice
                                _emit_bedrock_log({
                                    "message": {
                                        "content": [{"text": t}],
                                        "role": "assistant",
                                    },
                                    "index": 0,
                                    "finish_reason": "end_turn",
                                }, "gen_ai.choice")

                            output_messages.append({
                                "content": {
                                    "content": json.dumps(
                                        [{"text": t} for t in pending_text_blocks]
                                    ),
                                },
                                "role": "assistant",
                            })
                            pending_text_blocks.clear()

                        # Enrich tool-calling output messages with tool.result
                        # (matching Strands invoke_agent-level I/O pattern)
                        for rec in tool_use_records:
                            result_content = _tool_results.pop(rec["id"], [{"text": ""}])
                            tool_result_json = json.dumps([{"toolResult": {
                                "toolUseId": rec["id"],
                                "status": "success",
                                "content": result_content,
                            }}])
                            # Find the matching output message and add tool.result
                            for msg in output_messages:
                                c = msg.get("content", {})
                                if isinstance(c, dict) and "content" in c and rec["id"] in c.get("content", ""):
                                    # Convert from content→message format and add tool.result
                                    c["message"] = c.pop("content")
                                    c["tool.result"] = tool_result_json
                                    break

                        # Convert the last text-only output message to Strands
                        # final-message format: content.message + finish_reason
                        if output_messages:
                            last = output_messages[-1]
                            c = last.get("content", {})
                            if isinstance(c, dict) and "content" in c:
                                c["message"] = c.pop("content")
                                c["finish_reason"] = "end_turn"

                        # Build input messages list — only user message at
                        # invoke_agent level (matches Strands pattern; tool
                        # results live in output messages via tool.result key)
                        input_messages = [{
                            "content": {
                                "content": json.dumps(
                                    [{"text": _sanitize(user_input)}]
                                ),
                            },
                            "role": "user",
                        }]

                        # Build usage summary for I/O log
                        if usage:
                            input_tokens = usage.get("input_tokens", 0)
                            output_tokens = usage.get("output_tokens", 0)
                            total_tokens = input_tokens + output_tokens
                            usage_summary = {
                                "inputTokens": input_tokens,
                                "outputTokens": output_tokens,
                                "totalTokens": total_tokens,
                            }
                            cache_read = usage.get("cache_read_input_tokens", 0)
                            cache_write = usage.get("cache_creation_input_tokens", 0)
                            if cache_read:
                                usage_summary["cacheReadInputTokens"] = cache_read
                            if cache_write:
                                usage_summary["cacheWriteInputTokens"] = cache_write
                        else:
                            _logger.warning("ResultMessage.usage was None; token counts unavailable for this turn")
                            usage_summary = "unavailable"
                            input_tokens = 0
                            output_tokens = 0
                            total_tokens = 0
                            cache_read = 0
                            cache_write = 0

                        # Update conversation history
                        conversation_history.append({"role": "user", "text": _sanitize(user_input)})
                        if last_response_text:
                            conversation_history.append({"role": "assistant", "text": last_response_text})

                        # --- Token usage span attributes ---
                        _token_attrs = {
                            "gen_ai.usage.input_tokens": input_tokens,
                            "gen_ai.usage.output_tokens": output_tokens,
                            "gen_ai.usage.prompt_tokens": input_tokens,
                            "gen_ai.usage.completion_tokens": output_tokens,
                            "gen_ai.usage.total_tokens": total_tokens,
                        }
                        if cache_read:
                            _token_attrs["gen_ai.usage.cache_read_input_tokens"] = cache_read
                        if cache_write:
                            _token_attrs["gen_ai.usage.cache_write_input_tokens"] = cache_write

                        # --- End spans with timing attributes ---
                        chat_end_time = time.time()
                        chat_duration_s = chat_end_time - chat_start
                        ttft_s = (first_token_time - chat_start) if first_token_time else chat_duration_s

                        # End botocore CLIENT span
                        client_span.set_attribute("gen_ai.event.end_time", _iso_now())
                        client_span.set_attribute("gen_ai.server.request.duration", chat_duration_s)
                        client_span.set_attribute("gen_ai.server.time_to_first_token", ttft_s)
                        for k, v in _token_attrs.items():
                            client_span.set_attribute(k, v)
                        client_span.end()

                        # End chat INTERNAL span
                        chat_span.set_attribute("gen_ai.event.end_time", _iso_now())
                        chat_span.set_attribute("gen_ai.server.request.duration", chat_duration_s)
                        chat_span.set_attribute("gen_ai.server.time_to_first_token", ttft_s)
                        for k, v in _token_attrs.items():
                            chat_span.set_attribute(k, v)
                        chat_span.end()

                        # End execute_event_loop_cycle span
                        cycle_span.set_attribute("gen_ai.event.end_time", _iso_now())
                        cycle_span.end()
                        context.detach(_cycle_ctx)
                        _active_cycle_context = None

                        # Structured log: full I/O summary (emitted after cycle detach
                        # so current span is invoke_agent, matching evaluator expectations)
                        _emit_structured_log({
                            "output": {"messages": output_messages},
                            "input": {"messages": input_messages},
                            "usage": usage_summary,
                        })

                        # Set on invoke_agent span + status
                        for k, v in _token_attrs.items():
                            agent_span.set_attribute(k, v)
                        agent_span.set_attribute("gen_ai.event.end_time", _iso_now())
                        agent_span.set_status(trace.Status(trace.StatusCode.OK))

                        # --- Metrics ---
                        query_duration_ms = query_duration * 1000
                        ttft_ms = ((first_token_time - query_start) * 1000) if first_token_time else query_duration_ms

                        # Strands event_loop metrics (#9)
                        _end_cycle.add(1, {"event_loop_cycle_id": cycle_id})
                        _cycle_duration.record(query_duration, {"event_loop_cycle_id": cycle_id})
                        _loop_input_tokens.record(input_tokens)
                        _loop_output_tokens.record(output_tokens)
                        _loop_latency.record(query_duration_ms)
                        _model_ttft.record(ttft_ms)

                        # gen_ai.client.operation.duration (#2)
                        _operation_duration.record(query_duration, _BEDROCK_ATTRS)

                        # gen_ai.client.token.usage
                        if input_tokens:
                            _token_usage.record(input_tokens, {**_BEDROCK_ATTRS, "gen_ai.token.type": "input"})
                        if output_tokens:
                            _token_usage.record(output_tokens, {**_BEDROCK_ATTRS, "gen_ai.token.type": "output"})

    # Flush remaining traces, logs, and metrics on exit
    provider.shutdown()
    _log_provider.shutdown()
    _meter_provider.shutdown()


if __name__ == "__main__":
    anyio.run(main)
