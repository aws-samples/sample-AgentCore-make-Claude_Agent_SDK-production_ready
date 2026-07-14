"""Structured-log emitters and small helpers.

These produce the two log shapes AgentCore Evaluation parses:

* I/O-summary logs under the ``strands.telemetry.tracer`` scope, whose ``body``
  carries ``input.messages`` / ``output.messages`` (+ ``usage`` at invoke level,
  per-tool ``tool.result`` enrichment).
* Bedrock-format per-message logs under the
  ``opentelemetry.instrumentation.botocore.bedrock-runtime`` scope.

The logic is byte-compatible with Strands auto-instrumentation, which is what
makes the telemetry evaluation-parseable. Everything here takes its logger and
providers explicitly so the module holds no global state.
"""

from __future__ import annotations

import time
from datetime import datetime, timezone
from typing import Any

from opentelemetry import baggage, trace
from opentelemetry._logs import SeverityNumber

try:  # LogRecord moved out of the public module in opentelemetry-sdk >= 1.40.
    from opentelemetry.sdk._logs import LogRecord  # < 1.40
except ImportError:  # pragma: no cover - version dependent
    from opentelemetry.sdk._logs._internal import LogRecord  # >= 1.40


def sanitize(value: str) -> str:
    """Replace surrogate characters the OTLP exporter cannot encode."""
    return value.encode("utf-8", errors="replace").decode("utf-8")


def iso_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def strip_tool_prefix(name: str) -> str:
    """Strip the ``mcp__<server>__`` prefix from MCP tool names."""
    return name.split("__")[-1] if "__" in name else name


def _span_ctx_tuple(span_context=None):
    if span_context:
        return span_context
    span = trace.get_current_span()
    sc = span.get_span_context() if span else None
    if sc and sc.is_valid:
        return (sc.trace_id, sc.span_id, sc.trace_flags)
    return (0, 0, 0)


def emit_structured_log(
    struct_logger,
    body,
    *,
    attributes: dict | None = None,
    span_context=None,
    session_id: str | None = None,
) -> None:
    """Emit an I/O-summary log under the strands.telemetry.tracer scope."""
    tid, sid, flags = _span_ctx_tuple(span_context)
    merged = dict(attributes) if attributes else {}
    merged.setdefault("event.name", "strands.telemetry.tracer")
    session_id = session_id or baggage.get_baggage("session.id")
    if session_id:
        merged["session.id"] = session_id
    struct_logger.emit(
        LogRecord(
            timestamp=int(time.time_ns()),
            body=body,
            severity_number=SeverityNumber.INFO,
            severity_text="",  # Strands uses empty string, not "INFO"
            trace_id=tid,
            span_id=sid,
            trace_flags=flags,
            attributes=merged or None,
        )
    )


def emit_bedrock_log(
    bedrock_logger, body, event_name: str, *, span_context=None
) -> None:
    """Emit a per-message log under the bedrock-runtime scope."""
    tid, sid, flags = _span_ctx_tuple(span_context)
    bedrock_logger.emit(
        LogRecord(
            timestamp=int(time.time_ns()),
            body=body,
            severity_number=SeverityNumber.INFO,
            severity_text="",
            trace_id=tid,
            span_id=sid,
            trace_flags=flags,
            attributes={"event.name": event_name, "gen_ai.system": "aws.bedrock"},
        )
    )


def extract_result_content(tool_response: Any) -> list[dict]:
    """Normalize a tool response into a list of ``{"text": ...}`` items."""
    out: list[dict] = []
    items = None
    if isinstance(tool_response, dict) and "content" in tool_response:
        items = tool_response["content"]
    elif isinstance(tool_response, list):
        items = tool_response
    if items is not None:
        for item in items:
            if isinstance(item, dict) and item.get("type") == "text":
                out.append({"text": item["text"]})
            elif isinstance(item, dict) and "text" in item:
                out.append({"text": item["text"]})
            else:
                out.append({"text": str(item)})
    else:
        out.append({"text": str(tool_response)})
    return out
