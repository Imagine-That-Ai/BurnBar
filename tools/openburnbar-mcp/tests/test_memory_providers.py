"""The provider layer: policy from the courier, a keyless gateway client, the CLI client, and the router."""

from __future__ import annotations

import json
import os
import subprocess
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


def test_cli_argv_disables_every_tool_and_ignores_user_config():
    claude = me.CLIClient.claude_argv("prompt", None)
    disallowed = claude[claude.index("--disallowedTools") + 1].split(",")
    for tool in ("Bash", "Write", "Edit", "Read", "Grep", "Glob", "WebFetch", "WebSearch", "Agent", "Task"):
        assert tool in disallowed, tool
    codex = me.CLIClient.codex_argv("prompt", None)
    assert (
        "--ignore-user-config" in codex
        and "--ignore-rules" in codex
        and codex[codex.index("--sandbox") + 1] == "read-only"
    )


def test_cli_calls_run_in_an_empty_isolated_directory_with_a_sanitized_environment(monkeypatch, tmp_path):
    seen: dict = {}

    def fake_run(argv, **kwargs):
        seen["cwd"] = kwargs.get("cwd")
        seen["env"] = kwargs.get("env")
        seen["contents"] = sorted(os.listdir(kwargs["cwd"]))
        return subprocess.CompletedProcess(argv, 0, stdout='{"result": "{\\"ok\\": true}"}', stderr="")

    monkeypatch.setattr(me.providers.subprocess, "run", fake_run)
    monkeypatch.setenv("OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN", "daemon-secret")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "aws-secret")
    monkeypatch.setenv("GITHUB_TOKEN", "gh-secret")
    monkeypatch.setenv("ANTHROPIC_API_KEY", "keep-for-cli")
    me.CLIClient().chat_json(provider="claude_cli", model=None, prompt="p", timeout=5)
    assert seen["cwd"] != os.getcwd() and not seen["contents"], "runs in an empty throwaway directory"
    assert not os.path.isdir(seen["cwd"]), "the throwaway directory is removed afterwards"
    env = seen["env"]
    assert "OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN" not in env and "AWS_SECRET_ACCESS_KEY" not in env
    assert "GITHUB_TOKEN" not in env and env.get("ANTHROPIC_API_KEY") == "keep-for-cli"
    assert env.get("PATH") and env.get("HOME")


def test_courier_verification_requires_the_first_party_signature(monkeypatch, tmp_path):
    cli = tmp_path / "OpenBurnBarCLI"
    cli.write_text("#!/bin/sh\n")
    cli.chmod(0o755)
    good = 'designated => identifier "com.openburnbar.cli" and anchor apple generic and certificate leaf[subject.OU] = "4Y367DF25B"'

    def runner(output: str, verify_rc: int = 0):
        def fake_run(argv, **kwargs):
            if "--verify" in argv:
                return subprocess.CompletedProcess(argv, verify_rc, stdout="", stderr="")
            return subprocess.CompletedProcess(argv, 0, stdout=output, stderr="")

        return fake_run

    assert me.providers.verify_courier(str(cli), platform="darwin", run=runner(good)) is True
    assert (
        me.providers.verify_courier(str(cli), platform="darwin", run=runner(good.replace("4Y367DF25B", "EVIL")))
        is False
    )
    assert (
        me.providers.verify_courier(str(cli), platform="darwin", run=runner(good.replace("com.openburnbar.cli", "x")))
        is False
    )
    assert me.providers.verify_courier(str(cli), platform="darwin", run=runner(good, verify_rc=1)) is False
    assert (
        me.providers.verify_courier("/opt/openburnbar/bin/openburnbar-cli", platform="linux", run=runner(good)) is False
    ), "not root-owned here"
    assert me.providers.verify_courier(str(cli), platform="linux", run=runner(good)) is False


def test_signed_cli_path_prefers_the_release_helper_and_only_verified_candidates(monkeypatch, tmp_path):
    helper = tmp_path / "Applications/OpenBurnBar.app/Contents/Helpers/OpenBurnBarCLI"
    legacy = tmp_path / "Applications/OpenBurnBar.app/Contents/MacOS/openburnbar-cli"
    for path in (helper, legacy):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("#!/bin/sh\n")
        path.chmod(0o755)
    monkeypatch.setattr(me.providers, "CLI_CANDIDATE_ROOTS", [str(tmp_path / "Applications/OpenBurnBar.app")])
    monkeypatch.delenv(me.CLI_PATH_ENV, raising=False)
    monkeypatch.setattr(me.providers, "verify_courier", lambda path, **_: path.endswith("Helpers/OpenBurnBarCLI"))
    assert me.signed_cli_path() == str(helper)
    monkeypatch.setattr(me.providers, "verify_courier", lambda path, **_: False)
    assert me.signed_cli_path() is None, "an unverified binary is never the courier"


def test_router_skips_cli_providers_unless_spawning_is_allowed():
    policy = _policy(
        {
            "providers": [
                {
                    "id": "openrouter",
                    "consented": True,
                    "retention": "deny",
                    "purposes": {"memory-judge": ["anthropic/claude-opus-5"], "memory-answer": []},
                }
            ],
            "cli": {"claude_cli": True, "codex_cli": False},
        }
    )
    guarded = me.ModelRouter(policy, allow_cli=False)
    assert guarded.call("memory-judge").provider == "openrouter", "a gateway candidate is used instead of the CLI"
    with pytest.raises(me.ModelUnavailable) as refused:
        guarded.call("memory-answer")
    assert refused.value.code == "SPAWN_PROCESS_REQUIRED"
    with pytest.raises(me.ModelUnavailable) as hinted:
        guarded.call("memory-judge", "claude_cli")
    assert hinted.value.code == "SPAWN_PROCESS_REQUIRED", "a caller hint cannot force a spawn"
    assert not guarded.serves("memory-answer"), "a purpose only a CLI could serve is not served"
    assert me.ModelRouter(policy).call("memory-answer").provider == "claude_cli", (
        "allowed by default for callers that own the process"
    )
