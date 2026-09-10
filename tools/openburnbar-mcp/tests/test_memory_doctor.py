"""Tests for Packet P10 (A7): Doctor sync-ledger pass across both watermarks.

Verifies:
1. All 5 sync-ledger conditions report exactly five distinct codes.
2. --apply leaves a clean re-run.
3. --apply never touches orphan rows referenced by a staged in-flight upload.
4. A stranded transport watermark with a healthy engine watermark is reported.
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

_HERE = Path(__file__).resolve().parent
if str(_HERE.parent) not in sys.path:
    sys.path.insert(0, str(_HERE.parent))

import memory_engine as me  # noqa: E402
from memory_engine._util import _json_dumps, now_iso  # noqa: E402


class _NoopContext:
    """Hand the tools an engine the test owns, without closing it on exit."""

    def __init__(self, engine: me.MemoryEngine) -> None:
        self._engine = engine

    def __enter__(self) -> me.MemoryEngine:
        return self._engine

    def __exit__(self, *_exc: object) -> bool:
        return False


def _init_git(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)
    subprocess.run(["git", "init", "-q", str(path)], check=True)
    subprocess.run(["git", "-C", str(path), "config", "user.email", "test@burnbar.local"], check=True)
    subprocess.run(["git", "-C", str(path), "config", "user.name", "Test Committer"], check=True)
    subprocess.run(["git", "-C", str(path), "commit", "--allow-empty", "-m", "init", "-q"], check=True)


def _setup_tables(engine: me.MemoryEngine) -> None:
    engine.conn.execute(
        """
        CREATE TABLE IF NOT EXISTS remote_sync_watermarks (
            accountUid TEXT NOT NULL,
            collectionKind TEXT NOT NULL,
            lastSyncedAt DATETIME NOT NULL,
            lastProcessedRemoteUpdateAt DATETIME,
            version INTEGER NOT NULL DEFAULT 1,
            PRIMARY KEY (accountUid, collectionKind)
        )
        """
    )
    engine.conn.execute(
        """
        CREATE TABLE IF NOT EXISTS agent_memory_bodies (
            memory_id TEXT NOT NULL PRIMARY KEY,
            project_id TEXT NOT NULL,
            engine_memory_id TEXT NOT NULL,
            body TEXT NOT NULL,
            body_hash TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        )
        """
    )
    engine.conn.execute(
        """
        CREATE TABLE IF NOT EXISTS agent_memory_inbox (
            doc_id TEXT PRIMARY KEY,
            user_id TEXT NOT NULL,
            engine_memory_id TEXT NOT NULL,
            payload_json TEXT NOT NULL,
            remote_updated_at TEXT NOT NULL,
            received_at TEXT NOT NULL,
            applied_at TEXT
        )
        """
    )


def test_a_fixture_with_all_five_conditions_reports_exactly_five_codes(tmp_path: Path) -> None:
    """A store with all five sync-ledger conditions reports exactly five finding codes."""
    repo = str(tmp_path / "repo")
    _init_git(Path(repo))
    engine = me.MemoryEngine.open(tmp_path / "doctor_five.sqlite", provider=me.FakeEmbeddingProvider())
    project_id, _ = me.resolve_project(engine.conn, repo)
    _setup_tables(engine)

    # 1. STRANDED_TRANSPORT_WATERMARK
    engine.conn.execute(
        """
        INSERT INTO sync_state (user_id, applied_updated_at, applied_memory_id, applied_count, merged_at)
        VALUES ('user_1', '2026-08-01T10:00:00Z', 'mem_00000000000000000000000000000001', 1, '2026-08-01T10:00:00Z')
        """
    )
    engine.conn.execute(
        """
        INSERT INTO remote_sync_watermarks (accountUid, collectionKind, lastSyncedAt, lastProcessedRemoteUpdateAt, version)
        VALUES ('user_1', 'memory_facts', '2026-08-10T10:00:00Z', '2026-08-10T10:00:00Z', 1)
        """
    )

    # 2. ORPHAN_MEMORY_BODIES
    engine.conn.execute(
        """
        INSERT INTO agent_memory_bodies (memory_id, project_id, engine_memory_id, body, body_hash, created_at, updated_at)
        VALUES ('daemon_orphan_1', ?, 'mem_orphan_000000000000000000000001', 'Orphan body text', 'hash_orphan_1',
                '2026-08-01T10:00:00Z', '2026-08-01T10:00:00Z')
        """,
        (project_id,),
    )

    # 3. PARKED_SUPERSEDES
    payload = {
        "memoryID": "mem_parked_000000000000000000000001",
        "supersededBy": "mem_missing_target_000000000000001",
    }
    engine.conn.execute(
        """
        INSERT INTO agent_memory_inbox (doc_id, user_id, engine_memory_id, payload_json, remote_updated_at, received_at, applied_at)
        VALUES ('doc_parked_1', 'user_1', 'mem_parked_000000000000000000000001', ?, '2026-08-01T10:00:00Z', '2026-08-01T10:00:00Z', NULL)
        """,
        (_json_dumps(payload),),
    )

    # 4. RECEIPT_COVERAGE_GAP
    receipt = {
        "projectID": project_id,
        "scope": "project",
        "bodyHash": "bhash_forgotten_1",
        "ts": "2026-08-01T10:00:00Z",
    }
    engine.conn.execute(
        "INSERT INTO engine_meta (key, value) VALUES ('forget_receipt:mem_rcpt_000000000000000000000001', ?)",
        (_json_dumps(receipt),),
    )
    # Deliberately do NOT insert forget_identity key

    # 5. UNRESOLVED_GAP
    gap_data = {
        "memoryID": "mem_gap_000000000000000000000001",
        "expectedHash": "exphash12345678",
        "reportedAt": "2026-08-01T10:00:00Z",
    }
    engine.conn.execute(
        "INSERT INTO engine_meta (key, value) VALUES ('unresolved_gap:mem_gap_000000000000000000000001', ?)",
        (_json_dumps(gap_data),),
    )
    engine.conn.commit()

    report = engine.doctor(project_path=repo, apply=False)
    findings = report.get("findings", [])
    codes = [f.get("code") for f in findings]

    assert len(codes) == 5
    assert set(codes) == {
        "STRANDED_TRANSPORT_WATERMARK",
        "ORPHAN_MEMORY_BODIES",
        "PARKED_SUPERSEDES",
        "RECEIPT_COVERAGE_GAP",
        "UNRESOLVED_GAP",
    }
    engine.close()


def test_apply_leaves_a_clean_re_run(tmp_path: Path) -> None:
    """`apply` clears the two conditions it is allowed to clear, and the re-run says so."""
    repo = str(tmp_path / "repo")
    _init_git(Path(repo))
    engine = me.MemoryEngine.open(tmp_path / "doctor_apply.sqlite", provider=me.FakeEmbeddingProvider())
    project_id, _ = me.resolve_project(engine.conn, repo)
    _setup_tables(engine)

    # ORPHAN_MEMORY_BODIES: aged well past the grace period, referenced by nothing.
    engine.conn.execute(
        """
        INSERT INTO agent_memory_bodies (memory_id, project_id, engine_memory_id, body, body_hash, created_at, updated_at)
        VALUES ('daemon_orphan_clean', ?, 'mem_orphan_clean_0000000000000001', 'Orphan body text', 'hash_orphan_clean',
                '2026-07-01T10:00:00Z', '2026-07-01T10:00:00Z')
        """,
        (project_id,),
    )

    # PARKED_SUPERSEDES: the engine's own note, aged past the retention window
    # with a timestamp the doctor can actually read. The inbox is the daemon's
    # table and is never pruned from here — see
    # `test_apply_never_deletes_an_unapplied_inbox_row`.
    engine.conn.execute(
        "INSERT INTO engine_meta (key, value) VALUES ('parked_supersede:mem_parked_clean_0000000000000001', ?)",
        (
            _json_dumps(
                {
                    "memoryID": "mem_parked_clean_0000000000000001",
                    "targetID": "mem_missing_target_clean_0000001",
                    "reportedAt": "2026-07-01T10:00:00Z",
                }
            ),
        ),
    )
    engine.conn.commit()

    assert {finding["code"] for finding in engine.doctor(project_path=repo)["findings"]} == {
        "ORPHAN_MEMORY_BODIES",
        "PARKED_SUPERSEDES",
    }

    applied = engine.doctor(project_path=repo, apply=True, grace_period_seconds=86400.0, parked_retention_days=7)
    assert applied["apply"] == {
        "applied": True,
        "prunedOrphans": 1,
        "prunedSupersedes": 1,
        "unstampedTeamProvenance": 0,
    }

    assert engine.doctor(project_path=repo)["findings"] == []
    engine.close()


def test_apply_never_deletes_a_finding_it_cannot_repair(tmp_path: Path) -> None:
    """A7's bound: `apply` prunes two things. Watermarks, receipts and gaps stay reported.

    `--apply` is not a mute button. A doctor that rewound `remote_sync_watermarks`
    would silently re-drain or skip a member's inbox, and one that deleted
    `unresolved_gap:*` rows would report a store as healthy on its next run purely
    because it had erased its own evidence. All three conditions below survive.
    """
    repo = str(tmp_path / "repo")
    _init_git(Path(repo))
    engine = me.MemoryEngine.open(tmp_path / "doctor_apply_bound.sqlite", provider=me.FakeEmbeddingProvider())
    project_id, _ = me.resolve_project(engine.conn, repo)
    _setup_tables(engine)

    engine.conn.execute(
        """
        INSERT INTO sync_state (user_id, applied_updated_at, applied_memory_id, applied_count, merged_at)
        VALUES ('user_bound', '2026-08-01T10:00:00Z', 'mem_00000000000000000000000000000001', 1, '2026-08-01T10:00:00Z')
        """
    )
    engine.conn.execute(
        """
        INSERT INTO remote_sync_watermarks (accountUid, collectionKind, lastSyncedAt, lastProcessedRemoteUpdateAt, version)
        VALUES ('user_bound', 'memory_facts', '2026-08-10T10:00:00Z', '2026-08-10T10:00:00Z', 1)
        """
    )
    engine.conn.execute(
        "INSERT INTO engine_meta (key, value) VALUES ('forget_receipt:mem_rcpt_bound_0000000000000001', ?)",
        (
            _json_dumps(
                {
                    "projectID": project_id,
                    "scope": "project",
                    "bodyHash": "bhash_forgotten_bound",
                    "ts": "2026-08-01T10:00:00Z",
                }
            ),
        ),
    )
    engine.conn.execute(
        "INSERT INTO engine_meta (key, value) VALUES ('unresolved_gap:mem_gap_bound_0000000000000001', ?)",
        (_json_dumps({"memoryID": "mem_gap_bound_0000000000000001", "expectedHash": "exphashbound1234"}),),
    )
    # A parked supersede with NO usable timestamp — the shape `parked_supersedes()`
    # produces routinely, because it builds `reportedAt` as
    # `str(val.get("reportedAt") or val.get("ts") or "")` and `_parse_iso("")` is
    # None. Nothing here proves the row cleared the retention window, so it is
    # reported, exactly as the orphan loop already does.
    engine.conn.execute(
        "INSERT INTO engine_meta (key, value) VALUES ('parked_supersede:mem_parked_undated_00000001', ?)",
        (_json_dumps({"memoryID": "mem_parked_undated_00000001", "targetID": "mem_absent_target_0000000001"}),),
    )
    # An orphan body with no usable timestamp either.
    engine.conn.execute(
        """
        INSERT INTO agent_memory_bodies (memory_id, project_id, engine_memory_id, body, body_hash, created_at, updated_at)
        VALUES ('daemon_orphan_undated', ?, 'mem_orphan_undated_0000000000001', 'Orphan body text', 'hash_undated', '', '')
        """,
        (project_id,),
    )
    # An UNAPPLIED, app-owned inbox document. Deleting it loses the document
    # permanently and without acknowledgement — the same class of harm as
    # rewinding `remote_sync_watermarks`. The daemon owns this table.
    engine.conn.execute(
        """
        INSERT INTO agent_memory_inbox (doc_id, user_id, engine_memory_id, payload_json, remote_updated_at, received_at, applied_at)
        VALUES ('doc_live_bound', 'user_bound', 'mem_live_bound_00000000000000001', ?, '', '', NULL)
        """,
        (
            _json_dumps(
                {"memoryID": "mem_live_bound_00000000000000001", "supersededBy": "mem_absent_target_0000000001"}
            ),
        ),
    )
    engine.conn.commit()

    reported = {finding["code"] for finding in engine.doctor(project_path=repo)["findings"]}
    assert reported == {
        "STRANDED_TRANSPORT_WATERMARK",
        "RECEIPT_COVERAGE_GAP",
        "UNRESOLVED_GAP",
        "PARKED_SUPERSEDES",
        "ORPHAN_MEMORY_BODIES",
    }

    applied = engine.doctor(project_path=repo, apply=True, grace_period_seconds=0.0, parked_retention_days=0)
    assert applied["apply"] == {
        "applied": True,
        "prunedOrphans": 0,
        "prunedSupersedes": 0,
        "unstampedTeamProvenance": 0,
    }

    # Every report-only condition is still reported, and its underlying row is intact.
    assert {finding["code"] for finding in engine.doctor(project_path=repo)["findings"]} == reported
    watermark = engine.conn.execute(
        "SELECT lastSyncedAt, lastProcessedRemoteUpdateAt FROM remote_sync_watermarks WHERE accountUid = 'user_bound'"
    ).fetchone()
    assert (watermark["lastSyncedAt"], watermark["lastProcessedRemoteUpdateAt"]) == (
        "2026-08-10T10:00:00Z",
        "2026-08-10T10:00:00Z",
    )
    assert len(engine.unresolved_gaps()) == 1
    assert (
        engine.conn.execute(
            "SELECT COUNT(*) FROM engine_meta WHERE key = 'parked_supersede:mem_parked_undated_00000001'"
        ).fetchone()[0]
        == 1
    )
    assert engine.conn.execute("SELECT COUNT(*) FROM agent_memory_bodies").fetchone()[0] == 1
    engine.close()


def test_apply_never_deletes_an_unapplied_inbox_row(tmp_path: Path) -> None:
    """C3 / A7: `agent_memory_inbox` is the daemon's table, and the doctor never writes it.

    An unapplied inbox document is a document the engine has not yet been told
    to acknowledge — a lineage-held revision sits exactly like this by design.
    Deleting it loses a member's memory permanently and without acknowledgement.
    The doctor reports it; the daemon drains it.
    """
    repo = str(tmp_path / "repo")
    _init_git(Path(repo))
    engine = me.MemoryEngine.open(tmp_path / "doctor_inbox_bound.sqlite", provider=me.FakeEmbeddingProvider())
    me.resolve_project(engine.conn, repo)
    _setup_tables(engine)

    # Aged well past any retention window, and with a real timestamp: the only
    # thing keeping it alive is that the doctor does not own this table.
    engine.conn.execute(
        """
        INSERT INTO agent_memory_inbox (doc_id, user_id, engine_memory_id, payload_json, remote_updated_at, received_at, applied_at)
        VALUES ('doc_inbox_aged', 'user_inbox', 'mem_inbox_aged_00000000000000001', ?, '2020-01-01T00:00:00Z', '2020-01-01T00:00:00Z', NULL)
        """,
        (_json_dumps({"memoryID": "mem_inbox_aged_00000000000000001", "supersededBy": "mem_never_arrives_000000001"}),),
    )
    engine.conn.commit()

    applied = engine.doctor(project_path=repo, apply=True, grace_period_seconds=0.0, parked_retention_days=0)
    assert applied["apply"]["prunedSupersedes"] == 0
    assert engine.conn.execute("SELECT COUNT(*) FROM agent_memory_inbox").fetchone()[0] == 1
    assert {finding["code"] for finding in engine.doctor(project_path=repo)["findings"]} == {"PARKED_SUPERSEDES"}
    engine.close()


def test_a_parked_supersede_with_no_timestamp_is_reported_not_pruned(tmp_path: Path) -> None:
    """C3 / A7: no provable age, no delete — the rule the orphan loop already followed.

    `parked_supersedes()` builds its timestamps as `str(x or y or "")`, so a
    missing one is `""` and `_parse_iso("")` is None. Falling through on that
    means the retention window is not enforced at all on this path: the row is
    pruned at zero age under the DEFAULT 30-day retention.
    """
    repo = str(tmp_path / "repo")
    _init_git(Path(repo))
    engine = me.MemoryEngine.open(tmp_path / "doctor_undated.sqlite", provider=me.FakeEmbeddingProvider())
    me.resolve_project(engine.conn, repo)
    _setup_tables(engine)
    engine.conn.execute(
        "INSERT INTO engine_meta (key, value) VALUES ('parked_supersede:mem_undated_00000000000000001', ?)",
        (_json_dumps({"memoryID": "mem_undated_00000000000000001", "targetID": "mem_never_arrives_000000001"}),),
    )
    engine.conn.commit()

    # The default retention window, untouched: the row is zero seconds old.
    applied = engine.doctor(project_path=repo, apply=True)
    assert applied["apply"] == {
        "applied": True,
        "prunedOrphans": 0,
        "prunedSupersedes": 0,
        "unstampedTeamProvenance": 0,
    }
    assert len(engine.parked_supersedes()) == 1
    assert {finding["code"] for finding in engine.doctor(project_path=repo)["findings"]} == {"PARKED_SUPERSEDES"}
    engine.close()


def test_apply_never_touches_rows_referenced_by_a_staged_in_flight_upload(tmp_path: Path) -> None:
    """Under KD5 safety bounds, apply never deletes orphan rows referenced by in-flight/staged uploads."""
    repo = str(tmp_path / "repo")
    _init_git(Path(repo))
    engine = me.MemoryEngine.open(tmp_path / "doctor_staged.sqlite", provider=me.FakeEmbeddingProvider())
    project_id, _ = me.resolve_project(engine.conn, repo)
    _setup_tables(engine)

    # Aged orphan in agent_memory_bodies (60 days old)
    emid = "mem_staged_000000000000000000000001"
    dmid = "daemon_staged_1"
    engine.conn.execute(
        """
        INSERT INTO agent_memory_bodies (memory_id, project_id, engine_memory_id, body, body_hash, created_at, updated_at)
        VALUES (?, ?, ?, 'Important in-flight memory', 'hash_staged_1', '2026-06-01T10:00:00Z', '2026-06-01T10:00:00Z')
        """,
        (dmid, project_id, emid),
    )

    # Record staged in-flight upload in engine_meta
    engine.conn.execute(
        "INSERT INTO engine_meta (key, value) VALUES (?, ?)",
        (f"staged_upload:{emid}", _json_dumps({"docID": "cloud_doc_1", "stagedAt": now_iso()})),
    )
    engine.conn.commit()

    # Pre-condition: doctor reports the orphan
    initial = engine.doctor(project_path=repo, apply=False)
    orphan_findings = [f for f in initial.get("findings", []) if f.get("code") == "ORPHAN_MEMORY_BODIES"]
    assert len(orphan_findings) == 1

    # Apply with grace period = 1 day (60-day old row is older than grace period)
    apply_result = engine.doctor(project_path=repo, apply=True, grace_period_seconds=86400.0)
    assert apply_result.get("apply", {}).get("prunedOrphans") == 0

    # Assert row is untouched: 0 rows deleted
    count = engine.conn.execute("SELECT COUNT(*) FROM agent_memory_bodies WHERE memory_id = ?", (dmid,)).fetchone()[0]
    assert count == 1
    engine.close()


def test_a_stranded_transport_watermark_with_a_healthy_engine_watermark_is_reported(tmp_path: Path) -> None:
    """A stranded transport watermark ahead of a healthy engine watermark is reported, never silently passed."""
    repo = str(tmp_path / "repo")
    _init_git(Path(repo))
    engine = me.MemoryEngine.open(tmp_path / "doctor_stranded.sqlite", provider=me.FakeEmbeddingProvider())
    _setup_tables(engine)

    # Healthy engine watermark
    engine.conn.execute(
        """
        INSERT INTO sync_state (user_id, applied_updated_at, applied_memory_id, applied_count, merged_at)
        VALUES ('user_stranded', '2026-09-01T12:00:00Z', 'mem_00000000000000000000000000000099', 10, '2026-09-01T12:00:00Z')
        """
    )
    # Stranded transport watermark ahead of engine applied watermark
    engine.conn.execute(
        """
        INSERT INTO remote_sync_watermarks (accountUid, collectionKind, lastSyncedAt, lastProcessedRemoteUpdateAt, version)
        VALUES ('user_stranded', 'memory_facts', '2026-09-05T12:00:00Z', '2026-09-05T12:00:00Z', 2)
        """
    )
    engine.conn.commit()

    report = engine.doctor(project_path=repo, apply=False)
    stranded_findings = [f for f in report.get("findings", []) if f.get("code") == "STRANDED_TRANSPORT_WATERMARK"]
    assert len(stranded_findings) == 1
    detail = stranded_findings[0].get("detail", "")
    assert "user_stranded" in detail
    assert "ahead of engine applied watermark" in detail
    engine.close()


def test_doctor_apply_is_refused_without_memory_write(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """C2 / A7: `apply=True` deletes rows, so it is gated like every other mutating tool.

    `LOCAL_MCP_DEFAULT_PROFILE` is `read_only`. Without a gate, an agent that
    has been granted nothing at all could destroy store rows by passing one
    boolean — while `burnbar_memory_review`, `burnbar_memory_import`,
    `burnbar_memory_reindex` and `burnbar_project_adopt` all demand
    `memory_write` first. The report-only half stays readable, because reading
    the doctor is how a member finds out something is wrong.
    """
    import server

    repo = str(tmp_path / "repo")
    _init_git(Path(repo))
    engine = me.MemoryEngine.open(tmp_path / "doctor_gate.sqlite", provider=me.FakeEmbeddingProvider())
    project_id, _ = me.resolve_project(engine.conn, repo)
    _setup_tables(engine)
    monkeypatch.setattr(server, "_memory_engine", lambda: _NoopContext(engine))
    monkeypatch.setenv("OPENBURNBAR_ACTIVE_PROJECT_PATH", repo)

    # An aged orphan `apply` would otherwise be free to prune.
    engine.conn.execute(
        """
        INSERT INTO agent_memory_bodies (memory_id, project_id, engine_memory_id, body, body_hash, created_at, updated_at)
        VALUES ('daemon_orphan_gate', ?, 'mem_orphan_gate_00000000000000001', 'Orphan body text', 'hash_orphan_gate',
                '2026-07-01T10:00:00Z', '2026-07-01T10:00:00Z')
        """,
        (project_id,),
    )
    engine.conn.commit()

    monkeypatch.delenv("OPENBURNBAR_LOCAL_MCP_ENABLE_MEMORY_WRITE", raising=False)
    monkeypatch.setenv("OPENBURNBAR_LOCAL_MCP_PROFILE", "read_only")

    denied = json.loads(server.burnbar_memory_doctor(project_path=repo, apply=True))
    assert denied["status"] == "denied"
    assert denied["code"] == "MCP_CAPABILITY_DISABLED"
    assert denied["capability"] == "memory_write"
    assert denied["tool"] == "burnbar_memory_doctor"
    # Refused means refused: the orphan is still there.
    assert engine.conn.execute("SELECT COUNT(*) FROM agent_memory_bodies").fetchone()[0] == 1

    # The report-only path is readable under the same profile.
    report = json.loads(server.burnbar_memory_doctor(project_path=repo))
    assert report["memoryEngine"]["status"] in ("ok", "degraded")
    assert "apply" not in report["memoryEngine"]
    assert engine.conn.execute("SELECT COUNT(*) FROM agent_memory_bodies").fetchone()[0] == 1

    # With the capability granted, `apply` runs.
    monkeypatch.setenv("OPENBURNBAR_LOCAL_MCP_ENABLE_MEMORY_WRITE", "true")
    granted = json.loads(server.burnbar_memory_doctor(project_path=repo, apply=True))
    assert granted["memoryEngine"]["apply"]["applied"] is True
    engine.close()


def test_no_tool_docstring_names_the_capability_that_does_not_exist() -> None:
    """M13: a docstring that names a gate the server does not have is worse than none.

    `memory_read` is not a member of `LOCAL_MCP_CAPABILITY_ENV`; two docstrings
    claimed it, one of them on a tool that mutates. A caller reading them would
    conclude the tool was gated on something, and be wrong in both directions.
    """
    import server

    assert "memory_read" not in server.LOCAL_MCP_CAPABILITY_ENV
    offenders = [
        name
        for name in dir(server)
        if name.startswith("burnbar_") and "`memory_read`" in (getattr(getattr(server, name), "__doc__", "") or "")
    ]
    assert offenders == [], f"docstrings name a capability that does not exist: {offenders}"
    assert "`memory_write`" in (server.burnbar_memory_doctor.__doc__ or "")


def test_an_occupied_lineage_hold_queue_is_visible_in_the_doctor_report(tmp_path: Path) -> None:
    """R2: the hold queue is bounded and its only clearer is the next re-offer of
    the document that filled it, so a note whose peer went away occupies a slot
    for good — and `lineage_holds()` was surfaced nowhere. A member whose queue
    is full sees lineage advice quietly stop working with nothing to look at.
    Report-only: the doctor names the count and the oldest note, and `apply`
    still does not touch a slot that only the sync path may release.
    """
    repo = str(tmp_path / "repo")
    _init_git(Path(repo))
    engine = me.MemoryEngine.open(tmp_path / "doctor_holds.sqlite", provider=me.FakeEmbeddingProvider())
    _setup_tables(engine)

    clean = engine.doctor(project_path=repo)
    assert not [item for item in clean["findings"] if item["code"] == "OPEN_LINEAGE_HOLDS"]

    for index, first_seen in (("mem_" + "a" * 32, "2026-08-01T09:00:00Z"), ("mem_" + "b" * 32, "2026-08-02T09:00:00Z")):
        engine.conn.execute(
            "INSERT OR REPLACE INTO engine_meta (key, value) VALUES (?, ?)",
            (
                f"lineage_hold:{index}",
                _json_dumps(
                    {
                        "memoryID": index,
                        "docID": "doc-" + index[-4:],
                        "previousBodyHash": "0" * 64,
                        "expectedHash": "0" * 64,
                        "actualHash": None,
                        "firstSeen": first_seen,
                        "firstSeenEpoch": 1.0 if first_seen.startswith("2026-08-01") else 2.0,
                    }
                ),
            ),
        )
    engine.conn.commit()

    report = engine.doctor(project_path=repo, apply=True)
    holds = [item for item in report["findings"] if item["code"] == "OPEN_LINEAGE_HOLDS"]
    assert len(holds) == 1
    assert holds[0]["severity"] == "warn"
    assert holds[0]["count"] == 2
    assert holds[0]["oldestFirstSeen"] == "2026-08-01T09:00:00Z"
    assert "2" in holds[0]["detail"]
    # Report-only: `apply` releases nothing, because only the next re-offer of
    # the document a note describes may release its slot.
    assert len(engine.lineage_holds()) == 2
    engine.close()


def test_a_consent_watermark_with_no_processed_cursor_is_not_stranded(tmp_path: Path) -> None:
    """A freshly opted-in device is healthy, and the doctor must say so.

    The app creates the `memory_facts` watermark row on opt-in with a current
    `lastSyncedAt` and `lastProcessedRemoteUpdateAt = NULL`. That row is the
    consent marker, not evidence that any remote fact was processed. Falling back
    to `lastSyncedAt` reported `STRANDED_TRANSPORT_WATERMARK` on every healthy
    device that had simply never received a remote fact.
    """
    repo = str(tmp_path / "repo")
    _init_git(Path(repo))
    engine = me.MemoryEngine.open(tmp_path / "doctor_consent.sqlite", provider=me.FakeEmbeddingProvider())
    me.resolve_project(engine.conn, repo)
    _setup_tables(engine)
    engine.conn.execute(
        """
        INSERT INTO remote_sync_watermarks (accountUid, collectionKind, lastSyncedAt, lastProcessedRemoteUpdateAt, version)
        VALUES ('user_consent', 'memory_facts', '2026-08-10T10:00:00Z', NULL, 1)
        """
    )
    engine.conn.commit()

    codes = [finding["code"] for finding in engine.doctor(project_path=repo)["findings"]]
    assert "STRANDED_TRANSPORT_WATERMARK" not in codes, codes

    # A real processed cursor ahead of the engine's applied watermark still is.
    engine.conn.execute(
        "UPDATE remote_sync_watermarks SET lastProcessedRemoteUpdateAt = '2026-08-11T10:00:00Z' "
        "WHERE accountUid = 'user_consent'"
    )
    engine.conn.commit()
    codes = [finding["code"] for finding in engine.doctor(project_path=repo)["findings"]]
    assert "STRANDED_TRANSPORT_WATERMARK" in codes, codes
    engine.close()
