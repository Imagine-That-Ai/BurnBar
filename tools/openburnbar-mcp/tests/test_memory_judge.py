"""The reconciliation judge decides only the ambiguous cases, inside guardrails the rules keep."""

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

CANDIDATE = "We deploy the API from the main branch every Friday."
INCOMING = "We deploy the API from the release branch every Friday now."


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


def _judge_reply(event: str, targets: list[str], rationale: str = "the branch changed"):
    return chat_reply({"event": event, "targets": targets, "rationale": rationale, "confidence": 0.9})


def test_judge_runs_only_in_the_ambiguous_band_and_records_provenance(tmp_path, monkeypatch):
    calls: list[dict] = []
    state = {"target": ""}

    def responder(path, body):
        calls.append(body)
        payload = json.loads(body["messages"][1]["content"])
        assert payload["incoming"]["text"] == INCOMING
        assert [c["id"] for c in payload["candidates"]] == [state["target"]]
        return _judge_reply("UPDATE", [state["target"]])

    with FakeGateway(responder) as gw:
        engine = _engine(tmp_path, gw, monkeypatch)
        try:
            first = engine.remember(CANDIDATE, project_path=_project(tmp_path), kind="procedure")
            state["target"] = first["memoryID"]
            assert first["decidedBy"] == "rules" and first["rationale"] is None
            assert calls == [], "the first fact has no candidates, so the judge is not consulted"
            second = engine.remember(INCOMING, project_path=_project(tmp_path), kind="procedure")
            assert second["event"] == "UPDATE", second
            assert second["decidedBy"] == "judge:openrouter/anthropic/claude-opus-5"
            assert second["rationale"] == "the branch changed"
            assert second["superseded"] == [first["memoryID"]]
            assert len(calls) == 1
            row = engine.conn.execute(
                "SELECT superseded_by FROM memories WHERE id = ?", (first["memoryID"],)
            ).fetchone()
            assert row["superseded_by"] == second["memoryID"]
            history = engine.history(second["memoryID"])
            assert any(item.get("meta", {}).get("decidedBy", "").startswith("judge:") for item in history["events"])
        finally:
            engine.close()


def test_judge_cannot_touch_immutable_or_unlisted_rows(tmp_path, monkeypatch):
    with FakeGateway(lambda p, b: _judge_reply("DELETE", ["mem_not_a_candidate"])) as gw:
        engine = _engine(tmp_path, gw, monkeypatch)
        try:
            first = engine.remember(CANDIDATE, project_path=_project(tmp_path), kind="procedure", immutable=True)
            second = engine.remember(INCOMING, project_path=_project(tmp_path), kind="procedure")
            assert second["decidedBy"] == "rules"
            assert second["event"] == "ADD"
            row = engine.conn.execute("SELECT valid_to FROM memories WHERE id = ?", (first["memoryID"],)).fetchone()
            assert row["valid_to"] is None, "the immutable row must stay active"
        finally:
            engine.close()


def test_out_of_contract_judge_answers_are_discarded(tmp_path, monkeypatch):
    with FakeGateway(lambda p, b: chat_reply({"event": "MERGE", "targets": [], "rationale": "?"})) as gw:
        engine = _engine(tmp_path, gw, monkeypatch)
        try:
            engine.remember(CANDIDATE, project_path=_project(tmp_path), kind="procedure")
            second = engine.remember(INCOMING, project_path=_project(tmp_path), kind="procedure")
            assert second["decidedBy"] == "rules"
            assert second["event"] in {"ADD", "UPDATE"}
        finally:
            engine.close()


def test_judge_is_skipped_when_unavailable_and_rules_decide(tmp_path, monkeypatch):
    with FakeGateway(lambda p, b: error_reply(403, "PRO_REQUIRED")) as gw:
        engine = _engine(tmp_path, gw, monkeypatch)
        try:
            engine.remember(CANDIDATE, project_path=_project(tmp_path), kind="procedure")
            second = engine.remember(INCOMING, project_path=_project(tmp_path), kind="procedure")
            assert second["decidedBy"] == "rules"
            assert second["judge"] == {
                "purpose": "memory-judge",
                "applied": False,
                "code": "PRO_REQUIRED",
                "model": None,
            }
        finally:
            engine.close()


def test_exact_duplicates_never_reach_the_judge(tmp_path, monkeypatch):
    with FakeGateway(lambda p, b: _judge_reply("DELETE", [])) as gw:
        engine = _engine(tmp_path, gw, monkeypatch)
        try:
            engine.remember(CANDIDATE, project_path=_project(tmp_path), kind="procedure")
            again = engine.remember(CANDIDATE, project_path=_project(tmp_path), kind="procedure")
            assert again["event"] == "NONE"
            assert gw.requests == []
        finally:
            engine.close()


def test_judge_none_reinforces_the_named_candidate(tmp_path, monkeypatch):
    state = {"target": ""}
    with FakeGateway(lambda p, b: _judge_reply("NONE", [state["target"]], "same fact, different words")) as gw:
        engine = _engine(tmp_path, gw, monkeypatch)
        try:
            first = engine.remember(CANDIDATE, project_path=_project(tmp_path), kind="procedure")
            state["target"] = first["memoryID"]
            second = engine.remember(INCOMING, project_path=_project(tmp_path), kind="procedure")
            assert second["event"] == "NONE"
            assert second["memoryID"] == first["memoryID"]
            assert second["decidedBy"].startswith("judge:")
            assert second["rationale"] == "same fact, different words"
        finally:
            engine.close()


def test_ingest_receipt_keeps_the_judge_provenance():
    assert {"decidedBy", "rationale"} <= set(me.INGEST_DECISION_KEYS)
