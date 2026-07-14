"""Zero-code OpenTelemetry instrumentation for the Claude Agent SDK that emits
Strands-parity telemetry parseable by Amazon Bedrock AgentCore Evaluation.

Usage (zero code) — run your agent under the OTEL launcher:

    pip install otel-instrumentation-claude-agent-sdk-strands
    opentelemetry-instrument python your_agent.py

Or activate explicitly:

    from otel_instrumentation_claude_agent_sdk_strands import (
        ClaudeAgentSdkStrandsInstrumentor,
    )
    ClaudeAgentSdkStrandsInstrumentor().instrument(agent_name="my-agent")

Either way, any ``ClaudeSDKClient`` in the process transparently emits the
Strands-shaped spans + structured I/O log events that AgentCore's built-in
evaluators parse — no changes to your agent's loop, tools, or prompts.
"""

from .instrumentor import ClaudeAgentSdkStrandsInstrumentor

__version__ = "0.1.0"
__all__ = ["ClaudeAgentSdkStrandsInstrumentor"]
