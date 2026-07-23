"""Shared fixtures: in-memory OTEL providers + a fake ClaudeSDKClient.

These let us exercise the wrappers end-to-end (span tree + structured log bodies)
without AWS or a real model — the shaping logic is what we most need to lock down.
"""

from __future__ import annotations

import sys
import types

import pytest


# --- Fake claude_agent_sdk module (installed before the plugin imports it) ---
class TextBlock:
    def __init__(self, text):
        self.text = text


class ToolUseBlock:
    def __init__(self, id, name, input):
        self.id = id
        self.name = name
        self.input = input


class ToolResultBlock:  # not used directly but part of the public surface
    pass


class AssistantMessage:
    def __init__(self, content, model=None):
        self.content = content
        self.model = model


class UserMessage:
    def __init__(self, content):
        self.content = content


class ResultMessage:
    def __init__(self, usage=None, model=None, session_id=None):
        self.usage = usage
        self.model = model
        self.session_id = session_id


class HookMatcher:
    def __init__(self, hooks=None, matcher=None):
        self.hooks = hooks
        self.matcher = matcher


class ClaudeAgentOptions:
    def __init__(self, hooks=None, model=None, system_prompt=None):
        self.hooks = hooks
        self.model = model
        self.system_prompt = system_prompt


class ClaudeSDKClient:
    """Minimal stand-in whose query()/receive_response() the plugin wraps."""

    def __init__(self, options=None):
        self.options = options
        self._scripted: list = []

    def script(self, messages):
        self._scripted = messages

    async def query(self, prompt, session_id="default"):
        self._prompt = prompt

    async def receive_response(self):
        for m in self._scripted:
            yield m


def _install_fake_sdk():
    mod = types.ModuleType("claude_agent_sdk")
    for name in (
        "TextBlock",
        "ToolUseBlock",
        "ToolResultBlock",
        "AssistantMessage",
        "UserMessage",
        "ResultMessage",
        "HookMatcher",
        "ClaudeAgentOptions",
        "ClaudeSDKClient",
    ):
        setattr(mod, name, globals()[name])
    sys.modules["claude_agent_sdk"] = mod
    return mod


_install_fake_sdk()


@pytest.fixture
def otel_memory():
    """In-memory tracer + a capturing log emitter wired as the global providers."""
    from opentelemetry import trace
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import SimpleSpanProcessor
    from opentelemetry.sdk.trace.export.in_memory_span_exporter import (
        InMemorySpanExporter,
    )

    tp = TracerProvider()
    span_exporter = InMemorySpanExporter()
    tp.add_span_processor(SimpleSpanProcessor(span_exporter))

    # Capture structured/bedrock logs by monkeypatching acquire_providers to use
    # the in-memory tracer and a list-appending logger.
    captured_logs: list = []

    class _CapturingLogger:
        def emit(self, record):
            captured_logs.append(record)

    class _NoopInstrument:
        def add(self, *a, **k):
            pass

        def record(self, *a, **k):
            pass

    from otel_instrumentation_claude_agent_sdk_strands import _telemetry

    def _fake_acquire(meter_name="claude_agent_sdk_strands"):
        return _telemetry.Providers(
            tracer=tp.get_tracer("strands.telemetry.tracer"),
            struct_logger=_CapturingLogger(),
            bedrock_logger=_CapturingLogger(),
            meter=None,
            metrics={
                k: _NoopInstrument()
                for k in (
                    "cycle_count",
                    "start_cycle",
                    "end_cycle",
                    "cycle_duration",
                    "loop_input_tokens",
                    "loop_output_tokens",
                    "loop_latency",
                    "model_ttft",
                    "tool_call_count",
                    "tool_duration",
                    "tool_success_count",
                    "operation_duration",
                    "token_usage",
                )
            },
        )

    _orig = _telemetry.acquire_providers
    _telemetry.acquire_providers = _fake_acquire
    # instrumentor.py imported the name directly — patch there too.
    from otel_instrumentation_claude_agent_sdk_strands import instrumentor as _inst

    _inst.acquire_providers = _fake_acquire
    try:
        yield {"spans": span_exporter, "logs": captured_logs, "tracer_provider": tp}
    finally:
        _telemetry.acquire_providers = _orig
        _inst.acquire_providers = _orig
