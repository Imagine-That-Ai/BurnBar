#!/usr/bin/env python3
"""Regression tests for the sixth independent review of memory MCP v2."""

from __future__ import annotations

import json
import sys
import threading
from pathlib import Path

import pytest

_HERE = Path(__file__).resolve().parent
_PARENT = _HERE.parent
if str(_PARENT) not in sys.path:
    sys.path.insert(0, str(_PARENT))

import memory_engine as me  # noqa: E402
from test_memory_engine import FAKE_GITHUB_TOKEN, _engine, _repo  # noqa: E402
from test_memory_engine_hardening_round5 import _server_with_mirror  # noqa: E402


def test_forget_all_rejects_unknown_kind_before_delete(tmp_path: Path) -> None:
    repo = _repo(tmp_path)
    with _engine(tmp_path) as engine:
        stored = engine.remember("The release train is green.", project_path=repo)
        rejected = engine.forget_all(project_path=repo, kinds=["faact"], confirm="DELETE")
        assert rejected["status"] == "rejected" and rejected["code"] == "INVALID_KIND"
        assert engine.get(stored["memoryID"])["status"] == "ok"


class _PauseFirstEmbedding(me.FakeEmbeddingProvider):
    def __init__(self, entered: threading.Event, release: threading.Event) -> None:
        super().__init__(version_tag="update-race")
        self.entered = entered
        self.release = release
        self.calls = 0

    def embed(self, texts):  # type: ignore[override]
        self.calls += 1
        if self.calls == 1:
            self.entered.set()
            assert self.release.wait(timeout=5)
        return super().embed(texts)


def test_concurrent_update_retries_without_reverting_other_fields(tmp_path: Path) -> None:
    repo = _repo(tmp_path)
    db_path = tmp_path / "engine.sqlite"
    with me.MemoryEngine.open(db_path, provider=me.NullEmbeddingProvider()) as setup:
        memory_id = setup.remember("The release owner is Ops.", project_path=repo)["memoryID"]

    entered = threading.Event()
    release = threading.Event()
    provider = _PauseFirstEmbedding(entered, release)
    body_writer = me.MemoryEngine.open(db_path, provider=provider)
    tag_writer = me.MemoryEngine.open(db_path, provider=me.NullEmbeddingProvider())
    results: list[dict] = []

    thread = threading.Thread(
        target=lambda: results.append(body_writer.update(memory_id, text="The release owner is Platform."))
    )
    thread.start()
    assert entered.wait(timeout=5)
    tagged = tag_writer.update(memory_id, add_tags=["critical"])
    assert tagged["status"] == "ok"
    release.set()
    thread.join(timeout=10)
    body_writer.close()
    tag_writer.close()

    assert not thread.is_alive() and results[0]["status"] == "ok"
    with me.MemoryEngine.open(db_path, provider=me.NullEmbeddingProvider()) as verify:
        memory = verify.get(memory_id)["memory"]
        assert memory["body"] == "The release owner is Platform."
        assert memory["tags"] == ["critical"]
    assert provider.calls == 2


def test_retained_duplicate_promotes_redacted_row_to_secret(tmp_path: Path) -> None:
    repo = _repo(tmp_path)
    replacement = FAKE_GITHUB_TOKEN.replace("q", "r")
    with _engine(tmp_path, secret_policy="redact") as engine:
        redacted = engine.remember(f"Production token {FAKE_GITHUB_TOKEN}", project_path=repo)
        assert redacted["sensitivity"] == "redacted"
        engine.config.secret_policy = "retain"
        engine.config.retain_allowed = True
        promoted = engine.remember(f"Production token {replacement}", project_path=repo)
        assert promoted["memoryID"] == redacted["memoryID"]
        assert promoted["event"] == "UPDATE" and promoted["sensitivity"] == "secret"
        memory = engine.get(redacted["memoryID"], include_secrets=True)["memory"]
        assert memory["sensitivity"] == "secret" and replacement in memory["secretText"]


def test_absent_daemon_copy_is_cleared_and_remirrored(server_env: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    server = _server_with_mirror(server_env, monkeypatch)
    repo = _repo(server_env)
    remembers = 0
    forgets = 0

    def authority(method: str, _params: dict) -> dict:
        nonlocal remembers, forgets
        if method == "daemon.memory.remember":
            remembers += 1
            return {"mode": "daemon", "result": {"memoryID": f"daemon-{remembers}", "auditHash": "h"}}
        forgets += 1
        return {"mode": "daemon", "result": {"localDeleted": False}}

    monkeypatch.setattr(server.pcm, "write_authority", authority)
    stored = json.loads(server.burnbar_remember("The release owner is Ops.", project_path=repo))
    updated = json.loads(server.burnbar_memory_update(stored["memoryID"], text="The release owner is Platform."))
    assert updated["mirror"]["status"] == "mirrored"
    assert updated["mirror"]["previousForget"]["alreadyAbsent"] is True
    assert remembers == 2 and forgets == 1
    with server._memory_engine() as engine:
        assert engine.daemon_mirror_id(stored["memoryID"]) == "daemon-2"


def test_redacted_export_restore_preserves_secret_classification(tmp_path: Path) -> None:
    repo = _repo(tmp_path, "source")
    restored_repo = _repo(tmp_path, "restored")
    with _engine(tmp_path, secret_policy="retain", retain_allowed=True) as engine:
        engine.remember(f"Production token {FAKE_GITHUB_TOKEN}", project_path=repo)
        exported = engine.export(project_path=repo)
        assert exported["memories"][0]["sensitivity"] == "secret"
        assert exported["memories"][0]["secretText"] is None

    with me.MemoryEngine.open(tmp_path / "restored.sqlite", provider=me.NullEmbeddingProvider()) as restored:
        ordinary = restored.remember(exported["memories"][0]["body"], project_path=restored_repo)
        assert ordinary["sensitivity"] == "none"
        imported = restored.import_memories(exported["memories"], project_path=restored_repo)
        memory_id = imported["decisions"][0]["memoryID"]
        assert memory_id == ordinary["memoryID"] and imported["decisions"][0]["event"] == "UPDATE"
        memory = restored.get(memory_id, include_secrets=True)["memory"]
        assert memory["sensitivity"] == "secret" and memory["secretText"] is None


def test_invalid_pii_policy_fails_closed(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    monkeypatch.setenv(me.PII_POLICY_ENV, "reedact")
    config = me.EngineConfig.from_env()
    assert config.pii_policy == "reject"
    with me.MemoryEngine.open(tmp_path / "engine.sqlite", provider=me.FakeEmbeddingProvider(), config=config) as engine:
        result = engine.remember("Owner email is operator@example.com", project_path=_repo(tmp_path))
        assert result["status"] == "rejected" and engine.stats(project_path=_repo(tmp_path))["total"] == 0


def test_expired_memories_are_absent_from_graph_views(tmp_path: Path) -> None:
    repo = _repo(tmp_path)
    with _engine(tmp_path) as engine:
        stored = engine.remember(
            "Atlas uses SQLite.",
            project_path=repo,
            entities=["Atlas", "SQLite"],
            expires_at="2020-01-01T00:00:00Z",
        )
        assert stored["status"] == "ok"
        assert engine.entities(project_path=repo)["entities"] == []
        assert engine.relations(project_path=repo)["relations"] == []
