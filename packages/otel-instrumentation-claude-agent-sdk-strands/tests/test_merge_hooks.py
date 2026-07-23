"""merge_hooks preserves the caller's hooks and adds the instrumentation ones."""

from __future__ import annotations

from otel_instrumentation_claude_agent_sdk_strands._hooks import merge_hooks


def test_merge_preserves_user_hooks():
    user = {"PreToolUse": ["user_pre"], "PostToolUse": ["user_post"]}
    extra = {"PreToolUse": ["obs_pre"], "PostToolUse": ["obs_post"]}
    merged = merge_hooks(user, extra)
    assert merged["PreToolUse"] == ["user_pre", "obs_pre"]
    assert merged["PostToolUse"] == ["user_post", "obs_post"]


def test_merge_from_empty():
    merged = merge_hooks(None, {"PreToolUse": ["obs_pre"]})
    assert merged == {"PreToolUse": ["obs_pre"]}


def test_merge_disjoint_events():
    merged = merge_hooks({"Stop": ["s"]}, {"PreToolUse": ["p"]})
    assert merged == {"Stop": ["s"], "PreToolUse": ["p"]}
