"""Tests for the `/v1/models` self-loop sanitiser in `hermes_proxy.py`.

The proxy intercepts upstream Hermes responses that advertise the harness
itself (`hermes-agent`, `pi-agent`, etc.) as the available model and drops
those rows so the mobile picker never renders a bogus single-row state.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

# Make `hermes_proxy` importable without installing the package.
TOOLS_DIR = Path(__file__).resolve().parents[1]
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

from hermes_proxy import _filter_self_loop_models  # noqa: E402


def _encode(payload: dict) -> bytes:
    return json.dumps(payload).encode("utf-8")


def _decode(body: bytes) -> dict:
    return json.loads(body.decode("utf-8"))


def test_drops_hermes_agent_self_loop():
    body = _encode(
        {
            "object": "list",
            "data": [
                {"id": "hermes-agent", "object": "model", "owned_by": "hermes"},
                {"id": "claude-opus-4-7", "object": "model", "owned_by": "anthropic"},
            ],
        }
    )
    cleaned = _decode(_filter_self_loop_models(body))
    ids = [row["id"] for row in cleaned["data"]]
    assert ids == ["claude-opus-4-7"]


def test_drops_pi_agent_and_keeps_real_models():
    body = _encode(
        {
            "object": "list",
            "data": [
                {"id": "pi-agent", "object": "model"},
                {"id": "gpt-5-5", "object": "model", "owned_by": "openai"},
                {"id": "openclaw", "object": "model"},
                {"id": "kimi-k2-6", "object": "model", "owned_by": "kimi"},
            ],
        }
    )
    cleaned = _decode(_filter_self_loop_models(body))
    ids = [row["id"] for row in cleaned["data"]]
    assert ids == ["gpt-5-5", "kimi-k2-6"]


def test_preserves_models_that_merely_start_with_harness_token():
    # `hermes-mini` is a hypothetical real model; the filter must be
    # exact-match on the placeholder token, not a prefix strip.
    body = _encode({"object": "list", "data": [{"id": "hermes-mini"}]})
    cleaned = _decode(_filter_self_loop_models(body))
    ids = [row["id"] for row in cleaned["data"]]
    assert ids == ["hermes-mini"]


def test_returns_unchanged_when_already_clean():
    body = _encode({"object": "list", "data": [{"id": "gpt-5-5"}]})
    assert _filter_self_loop_models(body) == body


def test_returns_unchanged_on_garbage_body():
    body = b"<<not json>>"
    assert _filter_self_loop_models(body) == body


def test_returns_unchanged_on_non_list_data():
    body = _encode({"object": "list", "data": "wat"})
    assert _filter_self_loop_models(body) == body


def test_handles_empty_data_array():
    body = _encode({"object": "list", "data": []})
    cleaned = _decode(_filter_self_loop_models(body))
    assert cleaned == {"object": "list", "data": []}


def test_normalizes_case_and_whitespace():
    body = _encode(
        {
            "object": "list",
            "data": [
                {"id": "  HERMES-AGENT  "},
                {"id": "claude-sonnet-4-6"},
            ],
        }
    )
    cleaned = _decode(_filter_self_loop_models(body))
    ids = [row["id"] for row in cleaned["data"]]
    assert ids == ["claude-sonnet-4-6"]
