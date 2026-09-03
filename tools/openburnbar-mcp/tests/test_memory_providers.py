"""The provider layer: policy from the courier, a keyless gateway client, the CLI client, and the router."""

from __future__ import annotations

import json
import os
import stat
import sys
import time
from pathlib import Path

import pytest

MCP_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(MCP_DIR))
sys.path.insert(0, str(MCP_DIR / "tests"))

import memory_engine as me  # noqa: E402
from fakes.fake_gateway import FakeGateway, chat_reply, embed_reply, error_reply  # noqa: E402

POLICY = {
    "proActive": True,
    "enabled": True,
    "gatewayURL": "http://127.0.0.1:1",
    "gatewayToken": "tok-1",
    "tokenExpiresAt": "2099-01-01T00:00:00Z",
    "providers": [
        {
            "id": "openrouter",
            "consented": True,
            "retention": "deny",
            "purposes": {
                "memory-extract": ["anthropic/claude-opus-5"],
                "memory-judge": ["anthropic/claude-opus-5"],
                "memory-embed": ["openai/text-embedding-3-small"],
                "memory-rerank": ["anthropic/claude-haiku-4-5"],
                "memory-answer": ["anthropic/claude-opus-5"],
            },
        },
        {"id": "openai", "consented": False, "retention": "provider-policy", "purposes": {"memory-extract": ["gpt-5"]}},
    ],
    "cli": {"claude_cli": True, "codex_cli": False},
}


def _policy(overrides: dict | None = None) -> me.MemoryModelPolicy:
    payload = json.loads(json.dumps(POLICY))
    payload.update(overrides or {})
    return me.MemoryModelPolicy.from_payload(payload)


def test_policy_lists_only_consented_providers_and_available_clis():
    policy = _policy()
    assert policy.models_for("memory-extract") == ["openrouter/anthropic/claude-opus-5", "claude_cli/default"]
    assert policy.models_for("memory-embed") == ["openrouter/openai/text-embedding-3-small"]
    assert policy.usable("memory-embed") is True
    assert _policy({"enabled": False}).usable("memory-extract") is False
    assert _policy({"proActive": False}).usable("memory-extract") is False


def test_load_policy_uses_the_courier_and_caches_for_the_ttl():
    calls: list[float] = []

    def courier() -> dict:
        calls.append(time.time())
        return POLICY

    first = me.load_policy(courier=courier, ttl_seconds=300)
    second = me.load_policy(courier=courier, ttl_seconds=300)
    assert first is second and len(calls) == 1
    assert me.load_policy(courier=lambda: None, ttl_seconds=0) is None  # courier absent: no policy, no exception


def test_env_policy_override_is_honored_only_under_pytest(monkeypatch):
    monkeypatch.setenv(me.MODEL_POLICY_JSON_ENV, json.dumps(POLICY))
    assert me.load_policy(courier=lambda: None, ttl_seconds=0) is not None
    monkeypatch.delenv("PYTEST_CURRENT_TEST", raising=False)
    assert me.load_policy(courier=lambda: None, ttl_seconds=0) is None


def test_gateway_client_sends_purpose_and_bearer_and_parses_json():
    def responder(path, body):
        assert path == "/v1/chat/completions"
        return chat_reply({"ok": True, "echo": body["model"]})

    with FakeGateway(responder) as gw:
        client = me.GatewayClient(gw.url, "tok-1")
        parsed, usage = client.chat_json(
            purpose="memory-extract", model="openrouter/anthropic/claude-opus-5", system="s", user="u"
        )
    assert parsed == {"ok": True, "echo": "openrouter/anthropic/claude-opus-5"}
    assert usage["prompt_tokens"] == 10
    _, headers, body = gw.requests[0]
    assert headers["authorization"] == "Bearer tok-1"
    assert headers["x-openburnbar-purpose"] == "memory-extract"
    assert body["response_format"] == {"type": "json_object"}
    assert body["temperature"] == 0.0
    assert body["stream"] is False


def test_gateway_client_maps_policy_errors_and_retries_only_transient_failures():
    attempts = {"n": 0}

    def responder(path, body):
        attempts["n"] += 1
        if attempts["n"] == 1:
            return error_reply(503, "UPSTREAM")
        return chat_reply({"ok": True})

    with FakeGateway(responder) as gw:
        client = me.GatewayClient(gw.url, "tok-1")
        parsed, _ = client.chat_json(purpose="memory-judge", model="m", system="s", user="u")
        assert parsed == {"ok": True} and attempts["n"] == 2

    with FakeGateway(lambda p, b: error_reply(403, "PRO_REQUIRED")) as gw:
        client = me.GatewayClient(gw.url, "tok-1")
        with pytest.raises(me.ModelUnavailable) as exc:
            client.chat_json(purpose="memory-judge", model="m", system="s", user="u")
        assert exc.value.code == "PRO_REQUIRED"
        assert len(gw.requests) == 1  # policy refusals are never retried


def test_gateway_embed_returns_vectors_in_order():
    with FakeGateway(lambda p, b: embed_reply([[1.0, 0.0], [0.0, 1.0]])) as gw:
        vectors = me.GatewayClient(gw.url, "t").embed(purpose="memory-embed", model="m", texts=["a", "b"])
    assert vectors == [[1.0, 0.0], [0.0, 1.0]]
    assert gw.requests[0][0] == "/v1/embeddings"
    assert gw.requests[0][1]["x-openburnbar-purpose"] == "memory-embed"


def _fake_cli(tmp_path: Path, name: str, stdout: str) -> Path:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir(exist_ok=True)
    script = bin_dir / name
    script.write_text(f"#!/bin/sh\ncat >/dev/null\nprintf '%s' '{stdout}'\n")
    script.chmod(script.stat().st_mode | stat.S_IEXEC)
    return bin_dir


def test_cli_client_runs_claude_and_codex_with_read_only_flags(tmp_path, monkeypatch):
    claude_out = json.dumps({"result": json.dumps({"facts": []})})
    codex_out = json.dumps(
        {"type": "item.completed", "item": {"type": "agent_message", "text": json.dumps({"facts": []})}}
    )
    bin_dir = _fake_cli(tmp_path, "claude", claude_out)
    _fake_cli(tmp_path, "codex", codex_out)
    monkeypatch.setenv("PATH", f"{bin_dir}:{os.environ['PATH']}")
    client = me.CLIClient()
    assert client.chat_json(provider="claude_cli", model=None, prompt="p", timeout=10) == {"facts": []}
    assert client.chat_json(provider="codex_cli", model="gpt-5-codex", prompt="p", timeout=10) == {"facts": []}
    assert "--permission-mode" in me.CLIClient.claude_argv("p", None)
    assert "read-only" in me.CLIClient.codex_argv("p", None)


def test_cli_client_times_out(tmp_path, monkeypatch):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    slow = bin_dir / "claude"
    slow.write_text("#!/bin/sh\nsleep 5\n")
    slow.chmod(slow.stat().st_mode | stat.S_IEXEC)
    monkeypatch.setenv("PATH", f"{bin_dir}:{os.environ['PATH']}")
    with pytest.raises(me.ModelUnavailable) as exc:
        me.CLIClient().chat_json(provider="claude_cli", model=None, prompt="p", timeout=0.5)
    assert exc.value.code == "MODEL_UNAVAILABLE"


def test_router_prefers_the_hint_then_policy_order_and_refuses_unconsented():
    with FakeGateway(lambda p, b: chat_reply({"ok": True})) as gw:
        policy = _policy({"gatewayURL": gw.url})
        router = me.ModelRouter(policy)
        call = router.call("memory-extract")
        assert (call.provider, call.model) == ("openrouter", "anthropic/claude-opus-5")
        parsed, _ = call.json("s", "u")
        assert parsed == {"ok": True}
        assert gw.requests[-1][2]["model"] == "openrouter/anthropic/claude-opus-5"
        with pytest.raises(me.ModelUnavailable) as exc:
            router.call("memory-extract", provider_hint="openai")
        assert exc.value.code == "PROVIDER_NOT_CONSENTED"
        cli_call = router.call("memory-extract", provider_hint="claude_cli")
        assert (cli_call.provider, cli_call.model) == ("claude_cli", "default")
        with pytest.raises(me.ModelUnavailable) as exc:
            cli_call.embed(["x"])
        assert exc.value.code == "MODEL_UNAVAILABLE"
    assert me.ModelRouter(None).outcome("memory-extract", applied=False, code="CLOUD_CONSENT_REQUIRED") == {
        "purpose": "memory-extract",
        "applied": False,
        "code": "CLOUD_CONSENT_REQUIRED",
        "model": None,
    }
    with pytest.raises(me.ModelUnavailable) as exc:
        me.ModelRouter(None).call("memory-extract")
    assert exc.value.code == "CLOUD_CONSENT_REQUIRED"
    with pytest.raises(me.ModelUnavailable) as exc:
        me.ModelRouter(_policy({"proActive": False})).call("memory-extract")
    assert exc.value.code == "PRO_REQUIRED"


def test_engine_open_accepts_a_router(tmp_path):
    engine = me.MemoryEngine.open(db_path=tmp_path / "m.sqlite", models=me.ModelRouter(None))
    try:
        assert isinstance(engine.models, me.ModelRouter)
    finally:
        engine.close()
    plain = me.MemoryEngine.open(db_path=tmp_path / "n.sqlite")
    try:
        assert plain.models is None
    finally:
        plain.close()


def test_no_key_material_reaches_the_engine_process():
    policy = _policy()
    text = json.dumps(policy.__dict__, default=str)
    assert "sk-" not in text and "api_key" not in text.lower()
    assert all(not k.endswith("_API_KEY") for k in os.environ if "OPENBURNBAR_MEMORY" in k)
