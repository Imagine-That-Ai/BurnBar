"""Frontier-model extraction: the gated transcript goes out, provenance comes back, and every failure degrades."""

from __future__ import annotations

import json
import sys
from pathlib import Path

MCP_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(MCP_DIR))
sys.path.insert(0, str(MCP_DIR / "tests"))

import memory_engine as me  # noqa: E402
from fakes.fake_gateway import FakeGateway, chat_reply, error_reply  # noqa: E402
from test_memory_providers import POLICY  # noqa: E402

FAKE_GITHUB_TOKEN = "ghp_" + "A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8"


def _engine(tmp_path: Path, gw: FakeGateway | None, monkeypatch) -> me.MemoryEngine:
    monkeypatch.setenv(me.MEMORY_KEY_ENV, __import__("base64").b64encode(b"\x00" * 32).decode())
    models = None
    if gw is not None:
        policy = dict(POLICY, gatewayURL=gw.url)
        monkeypatch.setenv(me.MODEL_POLICY_JSON_ENV, json.dumps(policy))
        models = me.ModelRouter(me.load_policy(courier=lambda: None, ttl_seconds=0))
    return me.MemoryEngine.open(db_path=tmp_path / "m.sqlite", models=models)


def _project(tmp_path: Path) -> str:
    project = tmp_path / "project"
    project.mkdir(exist_ok=True)
    return str(project)


def test_pro_extractor_sends_the_gated_transcript_and_stores_provenance(tmp_path, monkeypatch):
    seen: dict[str, str] = {}

    def responder(path, body):
        seen["user"] = body["messages"][1]["content"]
        seen["system"] = body["messages"][0]["content"]
        return chat_reply(
            {
                "facts": [
                    {
                        "text": "Deploys run from the release branch.",
                        "kind": "procedure",
                        "confidence": 0.9,
                        "evidence_message_index": 1,
                        "tags": ["deploy"],
                        "entities": [],
                    }
                ]
            }
        )

    with FakeGateway(responder) as gw:
        engine = _engine(tmp_path, gw, monkeypatch)
        try:
            result = engine.memorize(
                project_path=_project(tmp_path),
                messages=[
                    {"role": "user", "content": f"Deploys run from the release branch, token {FAKE_GITHUB_TOKEN}"}
                ],
                extractor="pro",
            )
            assert result["summary"]["ADD"] == 1, result
            assert FAKE_GITHUB_TOKEN not in seen["user"] and "[REDACTED" in seen["user"]
            assert "UNTRUSTED" in seen["system"].upper()
            row = engine.conn.execute(
                "SELECT extractor, metadata_json FROM memories WHERE id = ?", (result["decisions"][0]["memoryID"],)
            ).fetchone()
            assert row["extractor"] == "llm:openrouter/anthropic/claude-opus-5"
            metadata = json.loads(row["metadata_json"])
            assert metadata["extractPromptVersion"] == me.EXTRACT_PROMPT_VERSION == "openburnbar-memory-extract-v2"
            assert len(metadata["transcriptGateHash"]) == 16
            assert isinstance(metadata["modelLatencyMs"], int)
            assert result["extraction"]["provider"] == "openrouter"
            assert result["extraction"]["applied"] is True
        finally:
            engine.close()


def test_pro_extractor_falls_back_to_heuristic_on_refusal(tmp_path, monkeypatch):
    with FakeGateway(lambda p, b: error_reply(403, "BUDGET_EXCEEDED")) as gw:
        engine = _engine(tmp_path, gw, monkeypatch)
        try:
            result = engine.memorize(
                project_path=_project(tmp_path),
                messages=[{"role": "user", "content": "We decided to use SQLCipher for the local store."}],
                extractor="pro",
            )
            assert result["extractionError"].startswith("pro: BUDGET_EXCEEDED")
            assert result["extraction"]["applied"] is False
            assert result["extraction"]["code"] == "BUDGET_EXCEEDED"
            assert result["summary"]["ADD"] >= 1, "the heuristic fallback still extracted"
            row = engine.conn.execute(
                "SELECT extractor, metadata_json FROM memories WHERE id = ?", (result["decisions"][0]["memoryID"],)
            ).fetchone()
            assert row["extractor"] == "heuristic"
        finally:
            engine.close()


def test_pro_extractor_without_policy_is_local(tmp_path, monkeypatch):
    engine = _engine(tmp_path, None, monkeypatch)
    try:
        result = engine.memorize(
            project_path=_project(tmp_path),
            messages=[{"role": "user", "content": "We decided to use SQLCipher for the local store."}],
            extractor="pro",
        )
        assert result["extractionError"].startswith("pro: CLOUD_CONSENT_REQUIRED")
        assert result["extraction"]["applied"] is False
        assert result["summary"]["ADD"] >= 1
    finally:
        engine.close()


def test_out_of_contract_answers_yield_no_facts_not_errors(tmp_path, monkeypatch):
    with FakeGateway(lambda p, b: chat_reply({"facts": "not a list"})) as gw:
        engine = _engine(tmp_path, gw, monkeypatch)
        try:
            result = engine.memorize(
                project_path=_project(tmp_path),
                messages=[{"role": "user", "content": "hello there"}],
                extractor="pro",
            )
            assert result["status"] == "ok"
            assert result["extraction"]["applied"] is True
            assert sum(result["summary"].values()) == 0
        finally:
            engine.close()


def test_server_gates_argument_selected_pro_extraction(server_env, monkeypatch):
    import server

    denied = json.loads(
        server.burnbar_memorize(
            messages=[{"role": "user", "content": "x"}], extractor="pro", project_path=str(server_env)
        )
    )
    assert denied["code"] == "MCP_CAPABILITY_DISABLED"
    monkeypatch.setenv("OPENBURNBAR_LOCAL_MCP_ENABLE_MEMORY_LLM_EXTRACT", "1")
    monkeypatch.setenv("OPENBURNBAR_LOCAL_MCP_ENABLE_MEMORY_WRITE", "1")
    allowed = json.loads(
        server.burnbar_memorize(
            messages=[{"role": "user", "content": "We decided to use SQLCipher for the local store."}],
            extractor="pro",
            project_path=str(server_env),
        )
    )
    assert allowed["status"] == "ok"
    assert allowed["extractionError"].startswith("pro: CLOUD_CONSENT_REQUIRED")


def test_facts_without_valid_transcript_evidence_are_dropped(tmp_path, monkeypatch):
    def responder(path, body):
        return chat_reply(
            {
                "facts": [
                    {
                        "text": "Grounded: deploys run from the release branch.",
                        "kind": "procedure",
                        "confidence": 0.9,
                        "evidence_message_index": 1,
                    },
                    {"text": "Hallucinated: the team uses COBOL.", "kind": "fact", "confidence": 0.9},
                    {
                        "text": "Out of range: the team uses Fortran.",
                        "kind": "fact",
                        "confidence": 0.9,
                        "evidence_message_index": 42,
                    },
                    {
                        "text": "Wrong type: the team uses BASIC.",
                        "kind": "fact",
                        "confidence": 0.9,
                        "evidence_message_index": "one",
                    },
                ]
            }
        )

    with FakeGateway(responder) as gw:
        engine = _engine(tmp_path, gw, monkeypatch)
        try:
            result = engine.memorize(
                project_path=_project(tmp_path),
                messages=[{"role": "user", "content": "Deploys run from the release branch."}],
                extractor="pro",
            )
        finally:
            engine.close()
    texts = [d.get("text", "") for d in result["decisions"]]
    assert result["summary"]["ADD"] == 1 and any("Grounded" in t for t in texts), result
    assert result["extraction"]["droppedUngrounded"] == 3


def test_pro_extractor_needs_spawn_process_when_the_policy_can_route_to_a_cli(server_env, monkeypatch):
    from test_memory_engine import _load_server, _repo

    monkeypatch.setenv("BURNBAR_MCP_TOOLSET", "memory")
    server = _load_server()
    monkeypatch.setattr(server, "_signed_cli_path", lambda: None)
    server._memory_provider_override = me.FakeEmbeddingProvider()
    repo = _repo(server_env)
    cli_policy = json.loads(json.dumps(POLICY))
    cli_policy["providers"][0]["purposes"]["memory-extract"] = ["claude_cli/default"]
    cli_policy["cli"] = {"claude_cli": True, "codex_cli": False}
    monkeypatch.setenv(me.MODEL_POLICY_JSON_ENV, json.dumps(cli_policy))
    me.reset_provider_cache_for_tests()
    monkeypatch.setenv("OPENBURNBAR_LOCAL_MCP_ENABLE_MEMORY_LLM_EXTRACT", "true")
    monkeypatch.delenv("OPENBURNBAR_LOCAL_MCP_ENABLE_SPAWN", raising=False)
    denied = json.loads(server.burnbar_memorize(messages="We deploy on Fridays.", project_path=repo, extractor="pro"))
    assert denied["code"] == "MCP_CAPABILITY_DISABLED" and denied["capability"] == "spawn_process", denied
