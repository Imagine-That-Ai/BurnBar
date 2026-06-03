#!/usr/bin/env python3
"""Deterministic local test for the BurnBar adapter's runtime-state, model-switch,
and human-in-the-loop oversight behavior.

It loads the in-repo adapter mirror with a local Hermes checkout on the path and
exercises the new logic against a fake gateway HTTP client and a fake
``tools.slash_confirm`` module — no network, no real Hermes runtime.

Run it with the Hermes virtualenv so the ``gateway.*`` imports resolve:

    HERMES_REPO=~/.hermes/hermes-agent \
      "$HERMES_REPO/.venv/bin/python" tools/hermes-platform-burnbar/test_oversight_local.py

Exits non-zero on the first failed assertion.
"""

from __future__ import annotations

import asyncio
import importlib.util
import os
import sys
import types
from pathlib import Path

HERMES_REPO = os.path.expanduser(os.getenv("HERMES_REPO", "~/.hermes/hermes-agent"))
if not Path(HERMES_REPO, "gateway").is_dir():
    print(f"SKIP: no Hermes checkout at {HERMES_REPO} (set HERMES_REPO)")
    sys.exit(0)
sys.path.insert(0, HERMES_REPO)

# A version string the adapter should echo into the runtime payload.
os.environ["HERMES_BURNBAR_AGENT_VERSION"] = "hermes-agent/test-1.2.3"

ADAPTER_PATH = Path(__file__).resolve().with_name("adapter.py")
_spec = importlib.util.spec_from_file_location("burnbar_adapter_under_test", ADAPTER_PATH)
adapter = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(adapter)


# --- Fakes --------------------------------------------------------------------
class FakeResponse:
    def __init__(self, status_code=200, json_data=None):
        self.status_code = status_code
        self._json = json_data if json_data is not None else {}

    def raise_for_status(self):
        if self.status_code >= 400:
            raise RuntimeError(f"HTTP {self.status_code}")

    def json(self):
        return self._json


class FakeClient:
    """Records calls; serves canned responses matched by URL suffix/substring."""

    def __init__(self):
        self.calls = []
        self.get_routes = {}   # substring -> FakeResponse | callable(params)->FakeResponse
        self.post_routes = {}  # substring -> FakeResponse

    async def get(self, url, headers=None, params=None):
        self.calls.append(("GET", url, params))
        for key, resp in self.get_routes.items():
            if key in url:
                return resp(params) if callable(resp) else resp
        return FakeResponse(200, {})

    async def post(self, url, headers=None, json=None):
        self.calls.append(("POST", url, json))
        for key, resp in self.post_routes.items():
            if key in url:
                return resp
        return FakeResponse(200, {})


# Fake tools.slash_confirm that records every resolution.
_resolved = []


async def _fake_resolve(session_key, confirm_id, choice, timeout=None):
    _resolved.append((session_key, confirm_id, choice))
    return f"resolved:{choice}"


_tools_pkg = types.ModuleType("tools")
_slash_confirm = types.ModuleType("tools.slash_confirm")
_slash_confirm.resolve = _fake_resolve
_tools_pkg.slash_confirm = _slash_confirm
sys.modules["tools"] = _tools_pkg
sys.modules["tools.slash_confirm"] = _slash_confirm


class _TestAdapter(adapter.BurnBarAdapter):
    # ``name`` is a read-only property on the base; shadow it with a plain value
    # so we can build an instance without the full Hermes config plumbing.
    name = "burnbar"


def make_adapter(oversight="supervised"):
    a = object.__new__(_TestAdapter)
    a._client = FakeClient()
    a._api_base = "https://api.test/v1/hermes-gateway"
    a._token = "tok"
    a._home_channel = "burnbar:home"
    a._oversight_mode = oversight
    a._oversight_checked_at = 0.0
    a._pending_confirms = {}
    a._last_runtime_publish = 123.0
    return a


def _posts(client, suffix):
    return [c for c in client.calls if c[0] == "POST" and suffix in c[1]]


# --- Tests --------------------------------------------------------------------
async def test_runtime_payload_includes_agent_version():
    body = adapter._runtime_status_payload()
    # build_models_payload may be unavailable here; agentVersion must still appear
    # because _agent_version reads the env override.
    assert body.get("agentVersion") == "hermes-agent/test-1.2.3", body
    print("  ✓ runtime payload carries agentVersion")


async def test_autonomous_auto_approves():
    _resolved.clear()
    a = make_adapter("autonomous")
    res = await a.send_slash_confirm("burnbar:home", "reload-mcp", "Reload?", "sess-1", "cid-1")
    assert res.success is True
    # Autonomous resolves "once" immediately and arms NO gate.
    assert _resolved == [("sess-1", "cid-1", "once")], _resolved
    assert _posts(a._client, "/approvals") == [], "autonomous must not arm a gate"
    assert a._pending_confirms == {}
    print("  ✓ autonomous mode auto-approves without a gate")


async def test_supervised_arms_gate_and_waits():
    _resolved.clear()
    a = make_adapter("supervised")
    a._client.post_routes["/approvals"] = FakeResponse(200, {"approval": {"status": "waiting_for_approval"}})
    res = await a.send_slash_confirm("burnbar:home", "shell", "rm -rf /tmp/x", "sess-2", "cid-2")
    assert res.success is True
    armed = _posts(a._client, "/approvals")
    assert len(armed) == 1, armed
    assert armed[0][2]["actionId"] == "cid-2"
    assert armed[0][2]["summary"] == "rm -rf /tmp/x"
    assert armed[0][2]["toolName"] == "shell"
    # Gate is pending; nothing resolved yet (the phone has not decided).
    assert "cid-2" in a._pending_confirms
    assert _resolved == [], "must not resolve before the phone decides"
    # An approval card is posted to the conversation.
    assert _posts(a._client, "/messages"), "should surface a prompt to the phone"
    print("  ✓ supervised mode arms a gate and waits for the phone")


async def test_pending_resolves_approved_and_denied():
    for status, expected_choice in (("approved", "once"), ("rejected", "cancel"), ("expired", "cancel")):
        _resolved.clear()
        a = make_adapter("supervised")
        a._pending_confirms["cid-x"] = {"session_key": "sess-x", "chat_id": "burnbar:home", "metadata": None}
        a._client.get_routes["/approvals"] = FakeResponse(200, {"approval": {"status": status}})
        await a._resolve_pending_confirms()
        assert _resolved == [("sess-x", "cid-x", expected_choice)], (status, _resolved)
        assert "cid-x" not in a._pending_confirms, "resolved gate must be cleared"
        print(f"  ✓ pending gate '{status}' -> slash_confirm '{expected_choice}'")


async def test_pending_stays_while_waiting():
    _resolved.clear()
    a = make_adapter("supervised")
    a._pending_confirms["cid-w"] = {"session_key": "sess-w", "chat_id": "burnbar:home", "metadata": None}
    a._client.get_routes["/approvals"] = FakeResponse(200, {"approval": {"status": "waiting_for_approval"}})
    await a._resolve_pending_confirms()
    assert _resolved == []
    assert "cid-w" in a._pending_confirms, "a still-waiting gate must remain pending"
    print("  ✓ still-waiting gate stays pending")


async def test_refresh_oversight_mode_from_state():
    a = make_adapter("supervised")
    a._oversight_checked_at = -10_000.0  # force refresh
    a._client.get_routes["/state"] = FakeResponse(200, {"oversightMode": "autonomous"})
    await a._refresh_oversight_mode()
    assert a._oversight_mode == "autonomous", a._oversight_mode
    print("  ✓ oversight mode mirrors /state")


async def test_arm_failure_falls_back_to_text_confirm():
    a = make_adapter("supervised")
    a._client.post_routes["/approvals"] = FakeResponse(503, {})
    called = {"super": False}

    async def fake_super(*args, **kwargs):
        called["super"] = True
        return adapter.SendResult(success=True)

    # Patch the bound super().send_slash_confirm via the base class.
    base = adapter.BasePlatformAdapter
    orig = base.send_slash_confirm
    base.send_slash_confirm = fake_super
    try:
        await a.send_slash_confirm("burnbar:home", "shell", "danger", "sess-f", "cid-f")
    finally:
        base.send_slash_confirm = orig
    assert called["super"] is True, "unreachable gateway must fall back to Hermes text confirm (still gated)"
    assert "cid-f" not in a._pending_confirms
    print("  ✓ gateway-unreachable falls back to text confirm (fails safe, not open)")


async def main():
    tests = [
        test_runtime_payload_includes_agent_version,
        test_autonomous_auto_approves,
        test_supervised_arms_gate_and_waits,
        test_pending_resolves_approved_and_denied,
        test_pending_stays_while_waiting,
        test_refresh_oversight_mode_from_state,
        test_arm_failure_falls_back_to_text_confirm,
    ]
    for t in tests:
        await t()
    print(f"\nBurnBar adapter oversight/runtime tests passed ({len(tests)} cases)")


if __name__ == "__main__":
    asyncio.run(main())
