# OTEL Setup: Imports, Resource, Providers, and Exporters

## Table of Contents
1. [Full import list](#full-import-list)
2. [Resource creation](#resource-creation)
3. [TracerProvider](#tracerprovider)
4. [LoggerProvider](#loggerprovider)
5. [MeterProvider (Metrics)](#meterprovider-metrics)
6. [Environment variables](#environment-variables)

---

## Full import list

```python
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

import botocore.session
import requests as _requests
from amazon.opentelemetry.distro.exporter.aws.metrics.aws_cloudwatch_emf_exporter import (
    AwsCloudWatchEmfExporter,
)
from amazon.opentelemetry.distro.exporter.otlp.aws.traces.otlp_aws_span_exporter import (
    OTLPAwsSpanExporter,
)
from aws_requests_auth.boto_utils import BotoAWSRequestsAuth
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
```

Required pip packages:
```
opentelemetry-api
opentelemetry-sdk
opentelemetry-exporter-otlp-proto-http
aws-opentelemetry-distro
aws-requests-auth
botocore
requests
```

---

## Resource creation

The Resource includes all attributes that Strands auto-populates. Missing any of these
causes AgentCore to fail silently or produce no evaluation results.

```python
_service_name = "your-agent-name"
_agent_id = f"{_service_name}-1234567890"

resource = Resource.create({
    "service.name": _service_name,
    "aws.local.service": _service_name,
    "aws.service.type": "gen_ai_agent",
    "aws.log.group.names": f"/aws/bedrock-agentcore/runtimes/{_agent_id}",
    "telemetry.auto.version": "0.12.2-aws",
})
```

**Why each attribute matters:**
- `aws.service.type: "gen_ai_agent"` — AgentCore uses this to classify the service
- `aws.log.group.names` with `/runtimes/` prefix — evaluations discover logs via this
- `telemetry.auto.version: "0.12.2-aws"` — matches the Strands distro version AgentCore expects

---

## TracerProvider

### BaggageSpanProcessor

Copies all OTEL baggage entries (including `session.id`) into span attributes on start.
This is what `aws-opentelemetry-distro` does automatically for Strands.

```python
class _BaggageSpanProcessor(SpanProcessor):
    def on_start(self, span, parent_context=None):
        ctx = parent_context or context.get_current()
        for key, value in baggage.get_all(ctx).items():
            span.set_attribute(key, value)
```

### Provider setup

```python
_region = "us-east-1"  # resolve from env or endpoint URL

provider = TracerProvider(resource=resource)
provider.add_span_processor(_BaggageSpanProcessor())  # BEFORE BatchSpanProcessor

_traces_otlp_endpoint = f"https://xray.{_region}.amazonaws.com/v1/traces"
provider.add_span_processor(
    BatchSpanProcessor(OTLPAwsSpanExporter(
        aws_region=_region,
        session=botocore.session.Session(),
        endpoint=_traces_otlp_endpoint,
    ))
)
trace.set_tracer_provider(provider)
tracer = trace.get_tracer("strands.telemetry.tracer")
```

**Why `OTLPAwsSpanExporter` and NOT `OTLPSpanExporter`:**
`OTLPSpanExporter` + `BotoAWSRequestsAuth` signs the request *before* the body is
serialized, so the body is excluded from the SigV4 signature. X-Ray silently rejects
these requests, and `BatchSpanProcessor` swallows the errors — resulting in zero traces
with no visible errors. `OTLPAwsSpanExporter` uses `AwsAuthSession` which signs inside
`request()` after the body is available.

**Why explicit `endpoint=`:**
Without it, the exporter defaults to `localhost:4318` and fails with `ConnectionRefusedError`.
The endpoint must include `/v1/traces` — this differs from the `OTEL_EXPORTER_OTLP_ENDPOINT`
env var which should NOT include `/v1`.

**Why tracer scope = `"strands.telemetry.tracer"`:**
The Bedrock AgentCore console uses the scope name to identify agent spans for per-session
metrics. A mismatched scope causes the "All sessions" view to show 0 tokens.

---

## LoggerProvider

```python
_logs_host = f"logs.{_region}.amazonaws.com"
_logs_endpoint = f"https://{_logs_host}/v1/logs"
_log_session = _requests.Session()
_log_session.auth = BotoAWSRequestsAuth(
    aws_host=_logs_host,
    aws_region=_region,
    aws_service="logs",
)

_log_provider = LoggerProvider(resource=resource)
_log_provider.add_log_record_processor(
    BatchLogRecordProcessor(OTLPLogExporter(
        endpoint=_logs_endpoint,
        session=_log_session,
        headers={
            "x-aws-log-group": f"/aws/bedrock-agentcore/{_agent_id}",
            "x-aws-log-stream": "runtime-logs",
            "x-aws-metric-namespace": "bedrock-agentcore",
        },
    ))
)
set_logger_provider(_log_provider)
```

**Why the `headers` parameter is required:**
Without `x-aws-log-group`, `x-aws-log-stream`, and `x-aws-metric-namespace`, the
CloudWatch Logs OTLP endpoint returns `400: CRequest headers for log group or log stream
cannot be null or empty`.

Two loggers with scope names matching Strands exactly:

```python
_struct_logger = _log_provider.get_logger("strands.telemetry.tracer")

_bedrock_logger = _log_provider.get_logger(
    "opentelemetry.instrumentation.botocore.bedrock-runtime",
    schema_url="https://opentelemetry.io/schemas/1.30.0",
)
```

---

## MeterProvider (Metrics)

```python
_emf_log_group = f"/aws/bedrock-agentcore/{_agent_id}"

_emf_exporter = AwsCloudWatchEmfExporter(
    namespace="bedrock-agentcore",
    log_group_name=_emf_log_group,
    log_stream_name="runtime-logs",
    aws_region=_region,
    session=botocore.session.Session(),
)
_meter_provider = MeterProvider(
    resource=resource,
    metric_readers=[PeriodicExportingMetricReader(
        _emf_exporter, export_interval_millis=5000
    )],
)
metrics.set_meter_provider(_meter_provider)
_meter = metrics.get_meter("agent_metrics")
```

### Metric instruments (all names must match Strands exactly)

```python
# Bedrock dimension values
_BEDROCK_ATTRS = {
    "gen_ai.system": "aws.bedrock",
    "server.address": f"bedrock-runtime.{_region}.amazonaws.com",
    "server.port": "443",
    "gen_ai.request.model": "MODEL_ID",
    "gen_ai.operation.name": "chat",
}

# Strands event_loop metrics
_cycle_count = _meter.create_counter("strands.event_loop.cycle_count", unit="Count")
_start_cycle = _meter.create_counter("strands.event_loop.start_cycle", unit="Count")
_end_cycle = _meter.create_counter("strands.event_loop.end_cycle", unit="Count")
_cycle_duration = _meter.create_histogram("strands.event_loop.cycle_duration", unit="Seconds")
_loop_input_tokens = _meter.create_histogram("strands.event_loop.input.tokens")
_loop_output_tokens = _meter.create_histogram("strands.event_loop.output.tokens")
_loop_latency = _meter.create_histogram("strands.event_loop.latency", unit="Milliseconds")
_model_ttft = _meter.create_histogram("strands.model.time_to_first_token", unit="Milliseconds")

# Strands tool metrics
_strands_tool_call_count = _meter.create_counter("strands.tool.call_count", unit="Count")
_strands_tool_duration = _meter.create_histogram("strands.tool.duration", unit="Seconds")
_strands_tool_success_count = _meter.create_counter("strands.tool.success_count", unit="Count")

# gen_ai.client metrics
_operation_duration = _meter.create_histogram("gen_ai.client.operation.duration", unit="Seconds")
_token_usage = _meter.create_histogram("gen_ai.client.token.usage")  # No unit — Strands omits it
```

**Why `gen_ai.client.token.usage` has no `unit=`:**
Strands omits the unit on this histogram. Setting `unit="Count"` causes EMF structure mismatch.

---

## Environment variables

These are set before running the agent (matching Strands pattern):

```bash
export AGENT_OBSERVABILITY_ENABLED=true
export OTEL_PYTHON_DISTRO=aws_distro
export OTEL_PYTHON_CONFIGURATOR=aws_configurator
export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
export OTEL_SERVICE_NAME=your-agent-name
export OTEL_RESOURCE_ATTRIBUTES="service.name=your-agent-name,aws.log.group.names=/aws/bedrock-agentcore/runtimes/your-agent-id"
export OTEL_EXPORTER_OTLP_ENDPOINT=https://xray.us-east-1.amazonaws.com
export OTEL_EXPORTER_OTLP_LOGS_HEADERS="x-aws-log-group=/aws/bedrock-agentcore/your-agent-id,x-aws-log-stream=runtime-logs,x-aws-metric-namespace=bedrock-agentcore"
```

Do NOT append `/v1` to `OTEL_EXPORTER_OTLP_ENDPOINT` — the SDK appends `/v1/traces`
automatically, so adding `/v1` yourself results in `/v1/v1/traces` and a 404.
