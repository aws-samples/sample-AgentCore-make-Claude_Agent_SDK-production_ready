"""Provider acquisition and Strands-named metric instruments.

Target B (deployed AgentCore Runtime): reuse the ADOT-configured global
providers. Target A (standalone): reuse whatever providers the caller installed
before ``instrument()``. Either way we never *create* providers here — that keeps
the plugin a passive observer and avoids the OTEL set-once trap.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field
from typing import Any

from opentelemetry import metrics, trace
from opentelemetry._logs import get_logger_provider

logger = logging.getLogger(__name__)

_STRANDS_SCOPE = "strands.telemetry.tracer"
_BEDROCK_SCOPE = "opentelemetry.instrumentation.botocore.bedrock-runtime"


@dataclass
class Providers:
    """Handles to the tracer / loggers / metric instruments the wrappers use."""

    tracer: Any
    struct_logger: Any
    bedrock_logger: Any
    meter: Any
    metrics: dict[str, Any] = field(default_factory=dict)


def acquire_providers(meter_name: str = "claude_agent_sdk_strands") -> Providers:
    """Acquire the global providers and build the Strands-named instruments."""
    tracer = trace.get_tracer(_STRANDS_SCOPE)

    log_provider = get_logger_provider()
    struct_logger = log_provider.get_logger(_STRANDS_SCOPE)
    bedrock_logger = log_provider.get_logger(
        _BEDROCK_SCOPE, schema_url="https://opentelemetry.io/schemas/1.30.0"
    )

    meter = metrics.get_meter(meter_name)
    instruments = {
        "cycle_count": meter.create_counter(
            "strands.event_loop.cycle_count", unit="Count"
        ),
        "start_cycle": meter.create_counter(
            "strands.event_loop.start_cycle", unit="Count"
        ),
        "end_cycle": meter.create_counter(
            "strands.event_loop.end_cycle", unit="Count"
        ),
        "cycle_duration": meter.create_histogram(
            "strands.event_loop.cycle_duration", unit="Seconds"
        ),
        "loop_input_tokens": meter.create_histogram("strands.event_loop.input.tokens"),
        "loop_output_tokens": meter.create_histogram(
            "strands.event_loop.output.tokens"
        ),
        "loop_latency": meter.create_histogram(
            "strands.event_loop.latency", unit="Milliseconds"
        ),
        "model_ttft": meter.create_histogram(
            "strands.model.time_to_first_token", unit="Milliseconds"
        ),
        "tool_call_count": meter.create_counter("strands.tool.call_count", unit="Count"),
        "tool_duration": meter.create_histogram(
            "strands.tool.duration", unit="Seconds"
        ),
        "tool_success_count": meter.create_counter(
            "strands.tool.success_count", unit="Count"
        ),
        "operation_duration": meter.create_histogram(
            "gen_ai.client.operation.duration", unit="Seconds"
        ),
        "token_usage": meter.create_histogram("gen_ai.client.token.usage"),
    }
    return Providers(
        tracer=tracer,
        struct_logger=struct_logger,
        bedrock_logger=bedrock_logger,
        meter=meter,
        metrics=instruments,
    )
