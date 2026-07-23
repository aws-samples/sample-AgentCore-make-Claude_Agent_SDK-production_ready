"""The BaseInstrumentor: transparently emit Strands-parity telemetry.

Wraps ``ClaudeSDKClient.__init__`` (inject tool hooks + stash config),
``ClaudeSDKClient.query`` (open the invoke_agent + cycle + chat spans), and
``ClaudeSDKClient.receive_response`` (an async generator that observes the
message stream and finalizes the turn). The caller's code is unchanged — it still
does ``async for message in client.receive_response()``.

Only ``ClaudeSDKClient`` is wrapped (not the one-shot ``query()`` helper), because
the streaming client is the surface real agents use and the one whose turn
boundaries we can observe cleanly.
"""

from __future__ import annotations

import json
import logging
import os
import time
import uuid
from typing import Any, Collection

import wrapt
from opentelemetry import baggage, context, trace
from opentelemetry.instrumentation.instrumentor import BaseInstrumentor

from ._context import InvocationContext
from ._emit import emit_bedrock_log, emit_structured_log, iso_now, sanitize
from ._hooks import build_instrumentation_hooks, merge_hooks
from ._telemetry import acquire_providers

logger = logging.getLogger(__name__)

_BEDROCK_ATTRS_BASE = {"gen_ai.system": "aws.bedrock", "gen_ai.operation.name": "chat"}


class ClaudeAgentSdkStrandsInstrumentor(BaseInstrumentor):
    """Zero-code instrumentation emitting AgentCore-Evaluation-parseable telemetry."""

    def instrumentation_dependencies(self) -> Collection[str]:
        return ("claude-agent-sdk >= 0.2.0",)

    # -- lifecycle ---------------------------------------------------------
    def _instrument(self, **kwargs: Any) -> None:
        self._agent_name = kwargs.get("agent_name") or os.getenv(
            "OTEL_SERVICE_NAME", "claude-agent"
        )
        self._model = kwargs.get("model") or os.getenv(
            "GEN_AI_REQUEST_MODEL", os.getenv("CLAIMCLEAR_MODEL", "")
        )
        cc_env = os.getenv(
            "OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT", "true"
        ).lower()
        self._capture_content = kwargs.get("capture_content", cc_env in ("1", "true", "yes"))
        self._session_id = kwargs.get("session_id")

        try:
            self._providers = acquire_providers()
        except Exception:  # pragma: no cover - no provider available → no-op
            logger.warning(
                "Strands instrumentor: no OTEL providers available; running as no-op",
                exc_info=True,
            )
            self._providers = None
            return

        wrapt.wrap_function_wrapper(
            "claude_agent_sdk", "ClaudeSDKClient.__init__", self._wrap_client_init
        )
        wrapt.wrap_function_wrapper(
            "claude_agent_sdk", "ClaudeSDKClient.query", self._wrap_client_query
        )
        wrapt.wrap_function_wrapper(
            "claude_agent_sdk",
            "ClaudeSDKClient.receive_response",
            self._wrap_client_receive_response,
        )

    def _uninstrument(self, **kwargs: Any) -> None:
        import claude_agent_sdk

        for attr in ("__init__", "query", "receive_response"):
            target = getattr(claude_agent_sdk.ClaudeSDKClient, attr, None)
            if isinstance(target, wrapt.ObjectProxy):
                setattr(
                    claude_agent_sdk.ClaudeSDKClient, attr, target.__wrapped__
                )

    # -- session id helper -------------------------------------------------
    def _resolve_session_id(self, result_session: str | None = None) -> str | None:
        return (
            self._session_id
            or baggage.get_baggage("session.id")
            or result_session
        )

    # -- __init__ : inject hooks + stash a context ------------------------
    def _wrap_client_init(self, wrapped, instance, args, kwargs):
        wrapped(*args, **kwargs)
        options = getattr(instance, "options", None)
        model = (self._model or getattr(options, "model", "") or "") if options else self._model

        ctx = InvocationContext(
            providers=self._providers,
            agent_name=self._agent_name,
            model=model,
            capture_content=self._capture_content,
            session_id=self._resolve_session_id(),
        )
        instance._otel_ctx = ctx

        if options is not None:
            # Hooks resolve the live per-turn ctx from the instance at call time.
            hooks = build_instrumentation_hooks(instance)
            options.hooks = merge_hooks(getattr(options, "hooks", None) or {}, hooks)

    # -- query : open the span tree ---------------------------------------
    def _wrap_client_query(self, wrapped, instance, args, kwargs):
        ctx: InvocationContext | None = getattr(instance, "_otel_ctx", None)
        if ctx is None:
            return wrapped(*args, **kwargs)

        prompt = kwargs.get("prompt")
        if prompt is None and args:
            prompt = args[0]
        ctx.user_input = sanitize(str(prompt)) if isinstance(prompt, str) else ""
        ctx.session_id = self._resolve_session_id()
        ctx.query_start = time.time()
        ctx.cycle_id = str(uuid.uuid4())
        ctx.first_token_time = None
        ctx.output_messages = []
        ctx.pending_text_blocks = []
        ctx.tool_use_records = []

        if ctx.session_id:
            context.attach(baggage.set_baggage("session.id", ctx.session_id))

        p = ctx.providers
        agent_attrs = {
            "user.input": ctx.user_input,
            "gen_ai.operation.name": "invoke_agent",
            "gen_ai.system": "aws.bedrock",
            "gen_ai.agent.name": ctx.agent_name,
            "gen_ai.event.start_time": iso_now(),
        }
        if ctx.model:
            agent_attrs["gen_ai.request.model"] = ctx.model
        if ctx.tool_names:
            agent_attrs["gen_ai.agent.tools"] = json.dumps(ctx.tool_names)
        if ctx.session_id:
            agent_attrs["session.id"] = ctx.session_id

        ctx.agent_span = p.tracer.start_span(
            f"invoke_agent {ctx.agent_name}", attributes=agent_attrs
        )
        agent_context = trace.set_span_in_context(ctx.agent_span)

        p.metrics["start_cycle"].add(1, {"event_loop_cycle_id": ctx.cycle_id})
        p.metrics["cycle_count"].add(1, {"event_loop_cycle_id": ctx.cycle_id})
        emit_bedrock_log(
            p.bedrock_logger,
            {"content": [{"text": ctx.user_input}]},
            "gen_ai.user.message",
            span_context=_ctx_of(ctx.agent_span),
        )

        ctx.cycle_span = p.tracer.start_span(
            "execute_event_loop_cycle",
            context=agent_context,
            attributes={"gen_ai.event.start_time": iso_now()},
        )
        ctx.active_cycle_context = trace.set_span_in_context(ctx.cycle_span)
        ctx.cycle_token = context.attach(ctx.active_cycle_context)

        ctx.chat_start = time.time()
        chat_attrs = {
            "gen_ai.operation.name": "chat",
            "gen_ai.system": "aws.bedrock",
            "gen_ai.event.start_time": iso_now(),
        }
        if ctx.model:
            chat_attrs["gen_ai.request.model"] = ctx.model
        ctx.chat_span = p.tracer.start_span("chat", attributes=dict(chat_attrs))
        ctx.client_span = p.tracer.start_span(
            f"chat {ctx.model}".strip(),
            kind=trace.SpanKind.CLIENT,
            attributes=dict(chat_attrs),
        )
        return wrapped(*args, **kwargs)

    # -- receive_response : observe + finalize ----------------------------
    def _wrap_client_receive_response(self, wrapped, instance, args, kwargs):
        return self._instrumented_receive_response(wrapped, instance, args, kwargs)

    async def _instrumented_receive_response(self, wrapped, instance, args, kwargs):
        ctx: InvocationContext | None = getattr(instance, "_otel_ctx", None)
        if ctx is None or ctx.agent_span is None:
            async for message in wrapped(*args, **kwargs):
                yield message
            return

        from claude_agent_sdk import (
            AssistantMessage,
            ResultMessage,
            TextBlock,
            ToolUseBlock,
        )

        finalized = False
        try:
            async for message in wrapped(*args, **kwargs):
                if isinstance(message, AssistantMessage):
                    for block in message.content:
                        if isinstance(block, TextBlock):
                            if ctx.first_token_time is None:
                                ctx.first_token_time = time.time()
                            ctx.pending_text_blocks.append(block.text)
                        elif isinstance(block, ToolUseBlock):
                            if ctx.first_token_time is None:
                                ctx.first_token_time = time.time()
                            self._observe_tool_use(ctx, block)
                elif isinstance(message, ResultMessage):
                    self._finalize(ctx, message)
                    finalized = True
                yield message
        finally:
            if not finalized:
                self._finalize(ctx, None)
            instance._otel_ctx = _reset_after_turn(ctx)

    # -- helpers -----------------------------------------------------------
    def _observe_tool_use(self, ctx: InvocationContext, block) -> None:
        p = ctx.providers
        cur = trace.get_current_span()
        if cur and getattr(block, "id", None):
            sc = cur.get_span_context()
            if sc and sc.is_valid:
                ctx.tool_span_contexts[block.id] = (
                    sc.trace_id,
                    sc.span_id,
                    sc.trace_flags,
                )
        plain_name = block.name.split("__")[-1] if "__" in block.name else block.name
        tool_input = getattr(block, "input", {}) or {}
        assistant_content = [{"text": t} for t in ctx.pending_text_blocks]
        assistant_content.append(
            {"toolUse": {"name": plain_name, "input": tool_input, "toolUseId": block.id}}
        )
        tool_call_entry = {
            "type": "function",
            "id": block.id,
            "function": {"name": plain_name, "arguments": tool_input},
        }
        emit_bedrock_log(
            p.bedrock_logger,
            {"content": assistant_content, "tool_calls": [tool_call_entry]},
            "gen_ai.assistant.message",
        )
        emit_bedrock_log(
            p.bedrock_logger,
            {
                "message": {"tool_calls": [tool_call_entry], "role": "assistant"},
                "index": 0,
                "finish_reason": "tool_use",
            },
            "gen_ai.choice",
        )
        ctx.tool_use_records.append({"id": block.id})
        ctx.output_messages.append(
            {"content": {"content": json.dumps(assistant_content)}, "role": "assistant"}
        )
        ctx.pending_text_blocks = []

    def _finalize(self, ctx: InvocationContext, result_message) -> None:
        p = ctx.providers
        query_duration = time.time() - ctx.query_start
        usage = getattr(result_message, "usage", None) or {} if result_message else {}

        if ctx.pending_text_blocks:
            for t in ctx.pending_text_blocks:
                emit_bedrock_log(
                    p.bedrock_logger, {"content": [{"text": t}]}, "gen_ai.assistant.message"
                )
                emit_bedrock_log(
                    p.bedrock_logger,
                    {
                        "message": {"content": [{"text": t}], "role": "assistant"},
                        "index": 0,
                        "finish_reason": "end_turn",
                    },
                    "gen_ai.choice",
                )
            ctx.output_messages.append(
                {
                    "content": {
                        "content": json.dumps(
                            [{"text": t} for t in ctx.pending_text_blocks]
                        )
                    },
                    "role": "assistant",
                }
            )
            ctx.pending_text_blocks = []

        for rec in ctx.tool_use_records:
            result_content = ctx.tool_results.pop(rec["id"], [{"text": ""}])
            tool_result_json = json.dumps(
                [
                    {
                        "toolResult": {
                            "toolUseId": rec["id"],
                            "status": "success",
                            "content": result_content,
                        }
                    }
                ]
            )
            for msg in ctx.output_messages:
                c = msg.get("content", {})
                if isinstance(c, dict) and "content" in c and rec["id"] in c.get(
                    "content", ""
                ):
                    c["message"] = c.pop("content")
                    c["tool.result"] = tool_result_json
                    break

        if ctx.output_messages:
            last = ctx.output_messages[-1]
            c = last.get("content", {})
            if isinstance(c, dict) and "content" in c:
                c["message"] = c.pop("content")
                c["finish_reason"] = "end_turn"

        input_tokens = usage.get("input_tokens", 0) if usage else 0
        output_tokens = usage.get("output_tokens", 0) if usage else 0
        total_tokens = input_tokens + output_tokens
        if usage:
            usage_summary: Any = {
                "inputTokens": input_tokens,
                "outputTokens": output_tokens,
                "totalTokens": total_tokens,
            }
            if usage.get("cache_read_input_tokens"):
                usage_summary["cacheReadInputTokens"] = usage["cache_read_input_tokens"]
            if usage.get("cache_creation_input_tokens"):
                usage_summary["cacheWriteInputTokens"] = usage[
                    "cache_creation_input_tokens"
                ]
        else:
            usage_summary = "unavailable"

        token_attrs = {
            "gen_ai.usage.input_tokens": input_tokens,
            "gen_ai.usage.output_tokens": output_tokens,
            "gen_ai.usage.prompt_tokens": input_tokens,
            "gen_ai.usage.completion_tokens": output_tokens,
            "gen_ai.usage.total_tokens": total_tokens,
        }

        chat_duration_s = time.time() - ctx.chat_start
        ttft_s = (
            (ctx.first_token_time - ctx.chat_start)
            if ctx.first_token_time
            else chat_duration_s
        )
        model = getattr(result_message, "model", None) if result_message else None
        if model and not ctx.model:
            ctx.model = model
        for span in (ctx.client_span, ctx.chat_span):
            if span is None:
                continue
            span.set_attribute("gen_ai.event.end_time", iso_now())
            span.set_attribute("gen_ai.server.request.duration", chat_duration_s)
            span.set_attribute("gen_ai.server.time_to_first_token", ttft_s)
            if ctx.model:
                span.set_attribute("gen_ai.response.model", ctx.model)
            for k, v in token_attrs.items():
                span.set_attribute(k, v)
            span.end()

        if ctx.cycle_span is not None:
            ctx.cycle_span.set_attribute("gen_ai.event.end_time", iso_now())
            ctx.cycle_span.end()
        if ctx.cycle_token is not None:
            context.detach(ctx.cycle_token)
        ctx.active_cycle_context = None

        # I/O summary — emitted after cycle detach so invoke_agent is current;
        # input carries ONLY the user message (tool results are in output).
        emit_structured_log(
            p.struct_logger,
            {
                "output": {"messages": ctx.output_messages},
                "input": {
                    "messages": [
                        {
                            "content": {
                                "content": json.dumps([{"text": ctx.user_input}])
                            },
                            "role": "user",
                        }
                    ]
                },
                "usage": usage_summary,
            },
            span_context=_ctx_of(ctx.agent_span),
            session_id=ctx.session_id,
        )

        for k, v in token_attrs.items():
            ctx.agent_span.set_attribute(k, v)
        ctx.agent_span.set_attribute("gen_ai.event.end_time", iso_now())
        ctx.agent_span.set_status(trace.Status(trace.StatusCode.OK))
        ctx.agent_span.end()

        query_ms = query_duration * 1000
        ttft_ms = (
            ((ctx.first_token_time - ctx.query_start) * 1000)
            if ctx.first_token_time
            else query_ms
        )
        m = p.metrics
        bedrock_attrs = dict(_BEDROCK_ATTRS_BASE)
        if ctx.model:
            bedrock_attrs["gen_ai.request.model"] = ctx.model
        m["end_cycle"].add(1, {"event_loop_cycle_id": ctx.cycle_id})
        m["cycle_duration"].record(query_duration, {"event_loop_cycle_id": ctx.cycle_id})
        m["loop_input_tokens"].record(input_tokens)
        m["loop_output_tokens"].record(output_tokens)
        m["loop_latency"].record(query_ms)
        m["model_ttft"].record(ttft_ms)
        m["operation_duration"].record(query_duration, bedrock_attrs)
        if input_tokens:
            m["token_usage"].record(
                input_tokens, {**bedrock_attrs, "gen_ai.token.type": "input"}
            )
        if output_tokens:
            m["token_usage"].record(
                output_tokens, {**bedrock_attrs, "gen_ai.token.type": "output"}
            )


def _ctx_of(span):
    sc = span.get_span_context() if span else None
    if sc and sc.is_valid:
        return (sc.trace_id, sc.span_id, sc.trace_flags)
    return (0, 0, 0)


def _reset_after_turn(ctx: InvocationContext) -> InvocationContext:
    """Return a fresh per-turn context sharing config, so the client can be
    queried again."""
    return InvocationContext(
        providers=ctx.providers,
        agent_name=ctx.agent_name,
        model=ctx.model,
        capture_content=ctx.capture_content,
        session_id=ctx.session_id,
        tool_names=ctx.tool_names,
    )
