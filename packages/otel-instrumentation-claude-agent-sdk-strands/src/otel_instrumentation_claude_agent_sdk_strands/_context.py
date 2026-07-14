"""Per-invocation state.

State is attached to the ``ClaudeSDKClient`` instance (``instance._otel_ctx``) —
not a module global — so concurrent clients never collide. Tool hooks, which run
outside the OTEL span context, read the active cycle context from the ctx the
hook closure captured.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any


@dataclass
class InvocationContext:
    """Everything one ``query()`` → ``receive_response()`` turn needs to build the
    Strands-parity span tree and emit its structured I/O logs."""

    providers: Any
    agent_name: str
    model: str
    capture_content: bool
    session_id: str | None = None
    tool_names: list[str] | None = None

    # Spans for the current turn.
    agent_span: Any = None
    cycle_span: Any = None
    chat_span: Any = None
    client_span: Any = None
    active_cycle_context: Any = None
    cycle_token: Any = None  # context.attach token for the cycle

    # Timing.
    query_start: float = 0.0
    chat_start: float = 0.0
    cycle_id: str = ""
    first_token_time: float | None = None

    # Message accumulation for the I/O summary.
    user_input: str = ""
    output_messages: list[dict] = field(default_factory=list)
    pending_text_blocks: list[str] = field(default_factory=list)
    tool_use_records: list[dict] = field(default_factory=list)

    # Tool-hook shared state (keyed by tool_use_id).
    tool_spans: dict[str, Any] = field(default_factory=dict)
    tool_start_times: dict[str, float] = field(default_factory=dict)
    tool_span_contexts: dict[str, tuple] = field(default_factory=dict)
    tool_inputs: dict[str, dict] = field(default_factory=dict)
    tool_results: dict[str, list] = field(default_factory=dict)
