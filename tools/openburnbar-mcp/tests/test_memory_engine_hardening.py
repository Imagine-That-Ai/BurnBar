#!/usr/bin/env python3
"""Hardening tests for the local memory engine.

Each test here pins one finding from the PR #2485 review (Codex + Cursor
security review) so the fix cannot regress silently:

- secrets never reach plaintext columns (history meta, ingest decisions,
  tags / entities / metadata / source_ref, WAL sidecars);
- encoded or joined secret forms are redacted in place or refused;
- external extractors only ever see a gated transcript;
- lifecycle edge cases (expired / rejected duplicates, duplicate bodies on
  update, first-item pack budget, stale vectors, personal-scope conflicts,
  cross-process cache staleness, key-file publication races);
- MCP wiring (snippet and pack wrapping, durable mirror-forget retries, gated
  mirror provenance, extractor capability, explicit empty lists, malformed
  JSON arguments, retryable legacy store migration).
"""

from __future__ import annotations

import base64
import json
import os
import sqlite3
import sys
from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest

_HERE = Path(__file__).resolve().parent
_PARENT = _HERE.parent
if str(_PARENT) not in sys.path:
    sys.path.insert(0, str(_PARENT))

import memory_engine as me  # noqa: E402
import project_code_memory as pcm  # noqa: E402
from test_memory_engine import (  # noqa: E402
    FAKE_GITHUB_TOKEN,
    TRANSCRIPT,
    _engine,
    _load_server,
    _repo,
)

REDACTED_GITHUB = "[REDACTED:GitHub token detected]"


def _raw(engine: me.MemoryEngine, sql: str, params: tuple = ()) -> list[tuple]:
    return [tuple(row) for row in engine.conn.execute(sql, params).fetchall()]


# ---------------------------------------------------------------------------
# Gate: encoded / joined secret forms
# ---------------------------------------------------------------------------


def test_gate_redacts_base64_encoded_secret_in_place() -> None:
    encoded = base64.b64encode(f"token={FAKE_GITHUB_TOKEN}".encode()).decode()
    text = f"The deploy job reads {encoded} from the env file."
    decision = me.apply_gate(text, secret_policy="redact", pii_policy="keep", retain_allowed=False)
    assert decision.action == "redact"
    assert encoded not in decision.body
    assert "[REDACTED:GitHub token detected (encoded)]" in decision.body
    assert "from the env file" in decision.body


def test_gate_rejects_unlocalizable_joined_secret_under_redact_policy() -> None:
    half = FAKE_GITHUB_TOKEN[:22]
    rest = FAKE_GITHUB_TOKEN[22:]
    text = f'token = "{half}"\n"{rest}" is the deploy token.'
    findings = me.scan_text(text)
    assert findings.has_secret and findings.unlocalizable_labels
    decision = me.apply_gate(text, secret_policy="redact", pii_policy="keep", retain_allowed=False)
    assert decision.action == "reject"
    assert "cannot be redacted in place" in (decision.reason or "")
    retained = me.apply_gate(text, secret_policy="retain", pii_policy="keep", retain_allowed=True)
    assert retained.action == "retain" and retained.vault_body == text
    assert half not in retained.body and rest not in retained.body
    assert retained.body.startswith("[REDACTED:")


# ---------------------------------------------------------------------------
# Gate: auxiliary fields
# ---------------------------------------------------------------------------


def test_metadata_tags_entities_and_source_ref_are_gated(tmp_path: Path) -> None:
    repo = _repo(tmp_path)
    with _engine(tmp_path) as engine:
        stored = engine.remember(
            "CI uploads coverage to Codecov.",
            project_path=repo,
            tags=["ci", FAKE_GITHUB_TOKEN],
            entities=["Codecov", f"key {FAKE_GITHUB_TOKEN}"],
            metadata={"token": FAKE_GITHUB_TOKEN, "nested": {"list": [FAKE_GITHUB_TOKEN, "plain"]}, "n": 2},
            source_ref=f"run {FAKE_GITHUB_TOKEN}",
        )
        assert stored["event"] == "ADD" and "GitHub token detected" in stored["labels"]
        memory = engine.get(stored["memoryID"])["memory"]
        assert memory["tags"] == ["ci"]
        assert memory["entities"] == ["Codecov"] or FAKE_GITHUB_TOKEN not in " ".join(memory["entities"])
        assert memory["metadata"]["token"] == REDACTED_GITHUB
        assert memory["metadata"]["nested"]["list"] == [REDACTED_GITHUB, "plain"]
        assert memory["metadata"]["n"] == 2
        assert memory["sourceRef"] == f"run {REDACTED_GITHUB}"
        dump = "\n".join(
            str(row) for row in _raw(engine, "SELECT tags_json, entities_json, metadata_json, source_ref FROM memories")
        )
        assert FAKE_GITHUB_TOKEN not in dump
        exported = json.dumps(engine.export(project_path=repo))
        assert FAKE_GITHUB_TOKEN not in exported
    with _engine(tmp_path, secret_policy="reject") as strict:
        rejected = strict.remember("Plain body.", project_path=repo, metadata={"k": FAKE_GITHUB_TOKEN})
        assert rejected["status"] == "rejected" and rejected["code"] == "SECRET_DETECTED"


def test_update_gates_auxiliary_fields(tmp_path: Path) -> None:
    repo = _repo(tmp_path)
    with _engine(tmp_path) as engine:
        created = engine.remember("The release runbook lives in docs/release.md.", project_path=repo)
        updated = engine.update(
            created["memoryID"], add_tags=[FAKE_GITHUB_TOKEN, "release"], metadata={"pat": FAKE_GITHUB_TOKEN}
        )
        assert updated["status"] == "ok"
        assert updated["memory"]["tags"] == ["release"]
        assert updated["memory"]["metadata"]["pat"] == REDACTED_GITHUB
        assert FAKE_GITHUB_TOKEN not in json.dumps(_raw(engine, "SELECT tags_json, metadata_json FROM memories"))


# ---------------------------------------------------------------------------
# History / ingest plaintext
# ---------------------------------------------------------------------------


def test_reinforce_history_never_stores_the_raw_incoming_text(tmp_path: Path) -> None:
    repo = _repo(tmp_path)
    with _engine(tmp_path) as engine:
        text = f"Deploy uses {FAKE_GITHUB_TOKEN} stored in 1Password."
        first = engine.remember(text, project_path=repo)
        second = engine.remember(text, project_path=repo)
        assert first["event"] == "ADD" and second["event"] == "NONE"
        events = engine.history(first["memoryID"])["events"]
        assert events[0]["event"] == "reinforced"
        assert "incomingText" not in events[0]["meta"]
        assert events[0]["after"] == first["text"]  # the gated body, encrypted at rest
        raw = "\n".join(str(row) for row in _raw(engine, "SELECT meta_json, after_cipher FROM memory_history"))
        assert FAKE_GITHUB_TOKEN not in raw and "1Password" not in raw


def test_ingest_table_holds_no_memory_bodies(tmp_path: Path) -> None:
    repo = _repo(tmp_path)
    with _engine(tmp_path) as engine:
        result = engine.memorize(
            project_path=repo, facts=[{"text": "Alberto's home office is in Austin.", "kind": "profile"}]
        )
        assert result["summary"]["ADD"] == 1
        rows = _raw(engine, "SELECT decisions_json FROM memory_ingest")
        assert rows and "Austin" not in rows[0][0]
        replay = engine.memorize(
            project_path=repo, facts=[{"text": "Alberto's home office is in Austin.", "kind": "profile"}]
        )
        assert replay["code"] == "ALREADY_INGESTED" and replay["decisions"][0]["event"] == "ADD"


def test_ingest_idempotency_is_per_project(tmp_path: Path) -> None:
    repo_a, repo_b = _repo(tmp_path, "a"), _repo(tmp_path, "b")
    with _engine(tmp_path) as engine:
        first = engine.memorize(project_path=repo_a, messages=TRANSCRIPT)
        second = engine.memorize(project_path=repo_b, messages=TRANSCRIPT)
        assert first["summary"]["ADD"] >= 1
        assert second.get("code") != "ALREADY_INGESTED"
        assert second["summary"]["ADD"] + second["summary"]["NONE"] >= 1
        assert engine.stats(project_path=repo_b)["total"] >= 1


# ---------------------------------------------------------------------------
# External extractors only see a gated transcript
# ---------------------------------------------------------------------------


def test_external_extractor_receives_redacted_transcript(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    repo = _repo(tmp_path)
    seen: list[str] = []

    def spy(transcript: str, max_facts: int) -> list[me.Fact]:
        seen.append(transcript)
        return [me.Fact(text="The deploy token lives in 1Password.", kind="procedure", confidence=0.8)]

    messages = [{"role": "user", "content": f"Deploy uses {FAKE_GITHUB_TOKEN}; keep it in 1Password."}]
    with _engine(tmp_path) as engine:
        result = engine.memorize(project_path=repo, messages=messages, extractor="custom", extractor_fn=spy)
        assert result["summary"]["ADD"] == 1
        assert seen and FAKE_GITHUB_TOKEN not in seen[0] and REDACTED_GITHUB in seen[0]
        assert result["transcriptGate"]["redacted"] is True

        monkeypatch.setattr(me, "GATE_CORPUS_AVAILABLE", False)
        seen.clear()
        closed = engine.memorize(project_path=repo, messages=messages, extractor="custom", extractor_fn=spy, force=True)
        assert seen == []  # fail closed: nothing leaves the process without a working scanner
        assert "scanner" in (closed["extractionError"] or "")


# ---------------------------------------------------------------------------
# Key file publication + sidecar permissions
# ---------------------------------------------------------------------------


def test_key_file_publication_never_truncates_an_existing_key(tmp_path: Path) -> None:
    db_path = tmp_path / "engine.sqlite"
    first = me.KeyRing.load(db_path)
    key_path = tmp_path / "engine.key"
    assert key_path.exists()
    # A second writer racing on the same path must adopt the published key, not replace it.
    winner = me.KeyRing._publish_key(key_path, os.urandom(32))
    assert winner == first.key
    assert me.KeyRing.load(db_path).key == first.key
    # An empty / truncated key file (crash between create and write) is repaired, not trusted.
    key_path.write_text("", encoding="utf-8")
    repaired = me.KeyRing.load(db_path)
    assert len(repaired.key) == 32 and repaired.key != first.key
    assert (key_path.stat().st_mode & 0o777) == 0o600
    assert not [p for p in tmp_path.iterdir() if p.name.startswith("engine.key.")]  # no temp files left behind


def test_wal_and_shm_sidecars_are_private(tmp_path: Path) -> None:
    previous = os.umask(0o022)
    try:
        repo = _repo(tmp_path)
        db_path = tmp_path / "engine.sqlite"
        with _engine(tmp_path) as engine:
            engine.remember("Sidecars must be private.", project_path=repo)
            for suffix in ("-wal", "-shm"):
                sidecar = db_path.with_name(db_path.name + suffix)
                assert sidecar.exists(), suffix
                assert (sidecar.stat().st_mode & 0o777) == 0o600, suffix
    finally:
        os.umask(previous)


# ---------------------------------------------------------------------------
# Lifecycle edge cases
# ---------------------------------------------------------------------------


def test_rejected_update_is_audited_after_the_connection_closes(tmp_path: Path) -> None:
    repo = _repo(tmp_path)
    with _engine(tmp_path, secret_policy="reject") as engine:
        created = engine.remember("Rotate the deploy token monthly.", project_path=repo)
        rejected = engine.update(created["memoryID"], text=f"Rotate {FAKE_GITHUB_TOKEN} monthly.")
        assert rejected["status"] == "rejected"
    with me.MemoryEngine.open(tmp_path / "engine.sqlite", provider=me.FakeEmbeddingProvider()) as reopened:
        events = reopened.audit_trail(project_path=repo)["events"]
        assert any(
            event["action"] == "memory.secret_rejected" and event["subjectID"] == created["memoryID"]
            for event in events
        )


def test_update_to_a_duplicate_body_returns_a_structured_conflict(tmp_path: Path) -> None:
    repo = _repo(tmp_path)
    with _engine(tmp_path) as engine:
        a = engine.remember("The default branch is main.", project_path=repo)
        b = engine.remember("Releases are cut from tags.", project_path=repo)
        conflict = engine.update(b["memoryID"], text="The default branch is main.")
        assert conflict["status"] == "conflict" and conflict["code"] == "DUPLICATE_BODY"
        assert conflict["duplicateOf"] == a["memoryID"]
        assert engine.get(b["memoryID"])["memory"]["body"] == "Releases are cut from tags."


def test_recall_pack_enforces_the_budget_for_the_first_result(tmp_path: Path) -> None:
    repo = _repo(tmp_path)
    with _engine(tmp_path) as engine:
        engine.remember(
            "The daemon socket protocol " + "handles reconnects, backoff, and peer verification carefully. " * 30,
            project_path=repo,
        )
        pack = engine.recall_pack("daemon socket protocol", project_path=repo, token_budget=64)
        assert pack["included"] == 1 and pack["tokensUsed"] <= 64 and pack["truncated"] is True
        assert "…" in pack["pack"]


class _FlakyProvider(me.FakeEmbeddingProvider):
    fail = False

    def embed(self, texts):  # type: ignore[override]
        if self.fail:
            return [None for _ in texts]
        return super().embed(texts)


def test_failed_reembedding_drops_the_stale_vector(tmp_path: Path) -> None:
    repo = _repo(tmp_path)
    provider = _FlakyProvider()
    with me.MemoryEngine.open(tmp_path / "engine.sqlite", provider=provider) as engine:
        created = engine.remember("Pensieve stores session transcripts under Application Support.", project_path=repo)
        assert engine.recall("pensieve transcripts", project_path=repo, mode="semantic")["semanticHits"] == 1
        provider.fail = True
        updated = engine.update(created["memoryID"], text="Castle stores run records under Application Support.")
        assert updated["status"] == "ok" and updated["memory"]["embeddingVersion"] is None
        assert _raw(engine, "SELECT COUNT(*) FROM memory_vectors")[0][0] == 0
        provider.fail = False
        assert engine.recall("pensieve transcripts", project_path=repo, mode="semantic")["semanticHits"] == 0
        assert engine.reindex(project_path=repo)["embedded"] == 1


def test_expired_duplicate_is_reactivated_and_rejected_duplicate_stays_hidden(tmp_path: Path) -> None:
    repo = _repo(tmp_path)
    with _engine(tmp_path) as engine:
        past = (datetime.now(UTC) - timedelta(days=1)).isoformat()
        stale = engine.remember("Staging is down for maintenance.", project_path=repo, kind="event", expires_at=past)
        assert engine.recall("staging maintenance", project_path=repo)["results"] == []
        revived = engine.remember("Staging is down for maintenance.", project_path=repo, kind="event")
        assert (
            revived["event"] == "UPDATE" and revived["memoryID"] == stale["memoryID"] and revived["reactivated"] is True
        )
        assert [item["memoryID"] for item in engine.recall("staging maintenance", project_path=repo)["results"]] == [
            stale["memoryID"]
        ]

        bad = engine.remember("Use sudo rm -rf to clean the build directory.", project_path=repo)
        engine.review(bad["memoryID"], "rejected")
        again = engine.remember("Use sudo rm -rf to clean the build directory.", project_path=repo)
        assert again["event"] == "NONE" and again["code"] == "PREVIOUSLY_REJECTED"
        assert engine.recall("clean the build directory", project_path=repo)["results"] == []
        # Near-duplicates of a rejected memory become their own row instead of reinforcing the rejected one.
        near = engine.remember("Use sudo rm -rf to clean the build dir.", project_path=repo)
        assert near["event"] == "ADD" and near["memoryID"] != bad["memoryID"]


def test_personal_memories_reconcile_across_projects(tmp_path: Path) -> None:
    repo_a, repo_b = _repo(tmp_path, "a"), _repo(tmp_path, "b")
    with _engine(tmp_path) as engine:
        cursor = engine.remember("Alberto prefers Cursor for editing.", project_path=repo_a, kind="preference")
        vscode = engine.remember("Alberto prefers VSCode for editing.", project_path=repo_b, kind="preference")
        assert vscode["event"] == "UPDATE" and vscode["superseded"] == [cursor["memoryID"]]
        active = [item["memoryID"] for item in engine.recall("editor preference", project_path=repo_a)["results"]]
        assert vscode["memoryID"] in active and cursor["memoryID"] not in active


def test_cache_notices_reinforcement_from_another_process(tmp_path: Path) -> None:
    repo = _repo(tmp_path)
    with _engine(tmp_path) as engine:
        created = engine.remember("Reinforcement counts must stay fresh across processes.", project_path=repo)
        assert (
            engine.recall("reinforcement counts", project_path=repo, reinforce=False)["results"][0]["accessCount"] == 0
        )
        other = sqlite3.connect(tmp_path / "engine.sqlite")
        other.execute(
            "UPDATE memories SET access_count = 41, last_accessed_at = ?, salience = 1.2 WHERE id = ?",
            (me.now_iso(), created["memoryID"]),
        )
        other.commit()
        other.close()
        fresh = engine.recall("reinforcement counts", project_path=repo, reinforce=False)["results"][0]
        assert fresh["accessCount"] == 41 and fresh["salience"] == 1.2


def test_import_accepts_exported_field_names(tmp_path: Path) -> None:
    repo = _repo(tmp_path)
    future = (datetime.now(UTC) + timedelta(days=3)).isoformat()
    with _engine(tmp_path) as engine:
        engine.remember(
            "Temporary: use the mirror registry until Friday.",
            project_path=repo,
            kind="event",
            expires_at=future,
            source_ref="ops-note-7",
        )
        exported = engine.export(project_path=repo)
    item = exported["memories"][0]
    assert item["expiresAt"] == future and item["sourceRef"] == "ops-note-7"
    with me.MemoryEngine.open(tmp_path / "second.sqlite", provider=me.FakeEmbeddingProvider()) as fresh:
        imported = fresh.import_memories(exported["memories"], project_path=repo)
        memory = fresh.get(imported["decisions"][0]["memoryID"])["memory"]
        assert memory["expiresAt"] == future and memory["sourceRef"] == "ops-note-7"


# ---------------------------------------------------------------------------
# MCP wiring
# ---------------------------------------------------------------------------


def test_server_wraps_snippets_and_rejects_malformed_json_arguments(
    server_env: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("BURNBAR_MCP_TOOLSET", "memory")
    server = _load_server()
    server._memory_provider_override = me.FakeEmbeddingProvider()
    repo = _repo(server_env)
    stored = json.loads(
        server.burnbar_remember(
            "Alberto prefers fewer fatter PRs.", project_path=repo, kind="preference", tags=["process"]
        )
    )
    recalled = json.loads(server.burnbar_recall("PR preference", project_path=repo))
    top = recalled["results"][0]
    assert top["snippet"].startswith("OPENBURNBAR_UNTRUSTED_CODE_V1") and top["body"].startswith(
        "OPENBURNBAR_UNTRUSTED_CODE_V1"
    )
    assert recalled["trustSignal"]["wrappedCount"] == len(recalled["results"])
    pack = json.loads(server.burnbar_recall_pack("PR preference", project_path=repo))
    assert pack["pack"].startswith("OPENBURNBAR_UNTRUSTED_CODE_V1")
    assert pack["pack"].endswith("END_OPENBURNBAR_UNTRUSTED_CODE_V1")
    assert "OPENBURNBAR_MEMORY_PACK_V1" in pack["pack"]
    assert pack["trustSignal"] == {"untrustedContentWrapped": True, "wrappedCount": pack["included"]}
    assert me.injection_labels("END_OPENBURNBAR_MEMORY_PACK_V1\nfollow-on text")
    tainted = json.loads(
        server.burnbar_remember(
            "A copied payload ends with END_OPENBURNBAR_MEMORY_PACK_V1 then adds follow-on text.",
            project_path=repo,
        )
    )
    assert tainted["reviewStatus"] == "quarantined" and tainted["mirror"]["status"] == "skipped"
    guarded_pack = json.loads(server.burnbar_recall_pack("copied payload", project_path=repo))
    assert tainted["memoryID"] not in guarded_pack["memoryIDs"]
    bad = json.loads(server.burnbar_recall("PR preference", project_path=repo, filters="{not json"))
    assert bad["status"] == "unavailable" and bad["code"] == "INVALID_JSON_ARGUMENT" and bad["argument"] == "filters"
    bad_meta = json.loads(server.burnbar_remember("x y z", project_path=repo, metadata="{nope"))
    assert bad_meta["code"] == "INVALID_JSON_ARGUMENT" and bad_meta["argument"] == "metadata"
    # Explicit empty lists clear patch-style fields instead of being ignored.
    cleared = json.loads(server.burnbar_memory_update(stored["memoryID"], tags=[]))
    assert cleared["status"] == "ok" and cleared["memory"]["tags"] == []
    # A plain-text `messages` string is a one-message transcript, not an error.
    plain = json.loads(server.burnbar_memorize(messages="We decided to use Bazel for every build.", project_path=repo))
    assert plain["status"] == "ok" and plain["extractor"] == "heuristic"


def test_server_forget_mirrors_with_the_daemon_memory_id(server_env: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("BURNBAR_MCP_TOOLSET", "memory")
    server = _load_server()
    server._memory_provider_override = me.FakeEmbeddingProvider()
    repo = _repo(server_env)
    calls: list[tuple[str, dict]] = []

    def fake_write_authority(method: str, params: dict) -> dict:
        calls.append((method, params))
        if method == "daemon.memory.remember":
            return {"mode": "daemon", "result": {"memoryID": "mem_daemon_" + "a" * 28, "auditHash": "h"}}
        return {"mode": "daemon", "result": {"localDeleted": True}}

    monkeypatch.setattr(server.pcm, "write_authority", fake_write_authority)
    unmirrored = json.loads(server.burnbar_remember("Stored before mirroring was on.", project_path=repo))
    assert unmirrored["mirror"]["status"] == "disabled"
    monkeypatch.setenv("OPENBURNBAR_LOCAL_MCP_ENABLE_LOCAL_WRITE", "true")
    stored = json.loads(
        server.burnbar_remember("CI runs on GitHub Actions.", project_path=repo, kind="architecture", tags=["ci"])
    )
    assert stored["mirror"]["status"] == "mirrored" and stored["mirror"]["daemonMemoryID"].startswith("mem_daemon_")
    assert calls[-1][1]["tags"] == ["ci"]
    with server._memory_engine() as engine:
        assert engine.daemon_mirror_id(stored["memoryID"]) == stored["mirror"]["daemonMemoryID"]
        assert engine.daemon_mirror_id(unmirrored["memoryID"]) is None
    forgotten = json.loads(server.burnbar_forget(stored["memoryID"], project_path=repo))
    assert forgotten["status"] == "ok" and forgotten["mirror"]["status"] == "mirrored"
    assert calls[-1][0] == "daemon.memory.forget" and calls[-1][1]["memoryID"] == stored["mirror"]["daemonMemoryID"]
    with server._memory_engine() as engine:
        assert engine.daemon_mirror_id(stored["memoryID"]) is None
    skipped = json.loads(server.burnbar_forget(unmirrored["memoryID"], project_path=repo))
    assert skipped["status"] == "ok" and skipped["mirror"]["status"] == "skipped"
    assert calls[-1][0] == "daemon.memory.forget"  # no bogus forget was sent for the un-mirrored row


def test_server_retries_pending_daemon_forget_after_local_delete(
    server_env: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("BURNBAR_MCP_TOOLSET", "memory")
    monkeypatch.setenv("OPENBURNBAR_LOCAL_MCP_ENABLE_LOCAL_WRITE", "true")
    server = _load_server()
    server._memory_provider_override = me.FakeEmbeddingProvider()
    repo = _repo(server_env)
    daemon_id = "mem_daemon_" + "b" * 28
    forget_attempts = 0

    def flaky_write_authority(method: str, params: dict) -> dict:
        nonlocal forget_attempts
        if method == "daemon.memory.remember":
            return {"mode": "daemon", "result": {"memoryID": daemon_id, "auditHash": "h"}}
        forget_attempts += 1
        if forget_attempts == 1:
            return {"code": "DAEMON_WRITE_REQUIRED", "reason": "daemon is restarting"}
        return {"mode": "daemon", "result": {"localDeleted": True}}

    monkeypatch.setattr(server.pcm, "write_authority", flaky_write_authority)
    stored = json.loads(server.burnbar_remember("The release train runs on Tuesdays.", project_path=repo))
    first = json.loads(server.burnbar_forget(stored["memoryID"], project_path=repo))
    assert first["status"] == "ok" and first["mirror"]["status"] == "unreachable"
    with server._memory_engine() as engine:
        assert engine.get(stored["memoryID"])["status"] == "not_found"
        assert engine.daemon_mirror_id(stored["memoryID"]) == daemon_id

    retried = json.loads(server.burnbar_forget(stored["memoryID"], project_path=repo))
    assert retried["status"] == "ok" and retried["localStatus"] == "already_deleted"
    assert retried["retriedPendingMirror"] is True and retried["mirror"]["status"] == "mirrored"
    assert forget_attempts == 2
    with server._memory_engine() as engine:
        assert engine.daemon_mirror_id(stored["memoryID"]) is None


def test_server_mirror_uses_only_gated_source_references(server_env: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("BURNBAR_MCP_TOOLSET", "memory")
    monkeypatch.setenv("OPENBURNBAR_LOCAL_MCP_ENABLE_LOCAL_WRITE", "true")
    server = _load_server()
    server._memory_provider_override = me.FakeEmbeddingProvider()
    repo = _repo(server_env)
    calls: list[tuple[str, dict]] = []

    def fake_write_authority(method: str, params: dict) -> dict:
        calls.append((method, params))
        return {"mode": "daemon", "result": {"memoryID": "mem_daemon_" + "c" * 28, "auditHash": "h"}}

    monkeypatch.setattr(server.pcm, "write_authority", fake_write_authority)
    raw_source = f"run {FAKE_GITHUB_TOKEN}"
    stored = json.loads(
        server.burnbar_remember(
            "CI uploads coverage to Codecov.",
            project_path=repo,
            source_path=raw_source,
        )
    )
    assert stored["sourceRef"] == f"run {REDACTED_GITHUB}"
    assert calls[-1][1]["sourcePath"] == stored["sourceRef"]
    assert FAKE_GITHUB_TOKEN not in json.dumps(calls[-1][1])

    memorized = json.loads(
        server.burnbar_memorize(
            facts=[{"text": "Bazel owns the build graph.", "source_ref": raw_source}],
            project_path=repo,
        )
    )
    decision = next(item for item in memorized["decisions"] if item.get("event") == "ADD")
    assert calls[-1][1]["sourcePath"] == decision["sourceRef"] == f"run {REDACTED_GITHUB}"
    assert FAKE_GITHUB_TOKEN not in json.dumps(calls[-1][1])


def test_server_llm_extractors_need_capabilities(server_env: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("BURNBAR_MCP_TOOLSET", "memory")
    server = _load_server()
    server._memory_provider_override = me.FakeEmbeddingProvider()
    repo = _repo(server_env)
    denied = json.loads(server.burnbar_memorize(messages=json.dumps(TRANSCRIPT), project_path=repo, extractor="claude"))
    assert denied["code"] == "MCP_CAPABILITY_DISABLED" and denied["capability"] == "spawn_process"
    denied_ollama = json.loads(
        server.burnbar_memorize(messages=json.dumps(TRANSCRIPT), project_path=repo, extractor="ollama")
    )
    assert denied_ollama["code"] == "MCP_CAPABILITY_DISABLED" and denied_ollama["capability"] == "memory_llm_extract"
    # Operator-configured extractor (env) is user intent; a dead endpoint degrades to the heuristic path.
    monkeypatch.setenv(me.EXTRACTOR_ENV, "ollama")
    monkeypatch.setenv(me.OLLAMA_BASE_URL_ENV, "http://127.0.0.1:9")
    configured = json.loads(server.burnbar_memorize(messages=json.dumps(TRANSCRIPT), project_path=repo))
    assert (
        configured["status"] == "ok"
        and configured["extractor"] == "heuristic"
        and "ollama" in configured["extractionError"]
    )


def test_server_recall_migrates_legacy_daemon_memories_once(server_env: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("BURNBAR_MCP_TOOLSET", "memory")
    server = _load_server()
    server._memory_provider_override = me.FakeEmbeddingProvider()
    repo = _repo(server_env)
    app_db = server_env / "openburnbar.sqlite"
    with sqlite3.connect(app_db) as conn:
        pcm.ensure_schema(conn)
        legacy = pcm.remember(
            conn,
            "Repo builds with Bazel and caches in GCS.",
            repo,
            "architecture",
            "project",
            ["build"],
            0.9,
            "docs/build.md",
        )
        conn.commit()
    assert legacy["status"] == "ok"
    recalled = json.loads(server.burnbar_recall("Bazel build cache", project_path=repo))
    assert recalled["legacyMigration"]["status"] == "migrated" and recalled["legacyMigration"]["imported"] == 1
    top = recalled["results"][0]
    assert (
        "Bazel" in top["body"]
        and top["sourceKind"] == "legacy_daemon"
        and top["metadata"]["legacyMemoryID"] == legacy["memoryID"]
    )
    assert top["tags"] == ["build"] and top["sourceRef"] == "docs/build.md"
    again = json.loads(server.burnbar_recall("Bazel build cache", project_path=repo))
    assert again["legacyMigration"]["status"] == "up_to_date" and len(again["results"]) == 1
    server._reset_legacy_migration_cache_for_tests()
    third = json.loads(server.burnbar_recall("Bazel build cache", project_path=repo))
    assert third["legacyMigration"]["imported"] == 0 and len(third["results"]) == 1
    doctor = json.loads(server.burnbar_memory_doctor(project_path=repo))
    assert doctor["memoryEngine"]["legacyMigration"]["status"] in ("up_to_date", "migrated")


def test_server_retries_transient_legacy_migration_failures(server_env: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("BURNBAR_MCP_TOOLSET", "memory")
    server = _load_server()
    repo = _repo(server_env)
    attempts = 0

    def flaky_legacy_read(_project_path: str | None) -> list[dict]:
        nonlocal attempts
        attempts += 1
        if attempts == 1:
            raise ConnectionError("daemon is still starting")
        return []

    monkeypatch.setattr(server, "_legacy_daemon_memories", flaky_legacy_read)
    with server._memory_engine() as engine:
        first = server._migrate_legacy_memories(engine, repo)
        second = server._migrate_legacy_memories(engine, repo)
        third = server._migrate_legacy_memories(engine, repo)
    assert first["status"] == "unavailable"
    assert second["status"] == "up_to_date" and second.get("cached") is None
    assert third["status"] == "up_to_date" and third["cached"] is True
    assert attempts == 2
