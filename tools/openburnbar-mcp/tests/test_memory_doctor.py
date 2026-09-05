"""Tests for Packet P10 (A7): Doctor sync-ledger pass across both watermarks.

Verifies:
1. All 5 sync-ledger conditions report exactly five distinct codes.
2. --apply leaves a clean re-run.
3. --apply never touches orphan rows referenced by a staged in-flight upload.
4. A stranded transport watermark with a healthy engine watermark is reported.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

import memory_engine as me
from memory_engine._util import _json_dumps, now_iso


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

    # PARKED_SUPERSEDES: aged past the retention window, target never arrived.
    payload = {
        "memoryID": "mem_parked_clean_0000000000000001",
        "supersededBy": "mem_missing_target_clean_0000001",
    }
    engine.conn.execute(
        """
        INSERT INTO agent_memory_inbox (doc_id, user_id, engine_memory_id, payload_json, remote_updated_at, received_at, applied_at)
        VALUES ('doc_parked_clean', 'user_clean', 'mem_parked_clean_0000000000000001', ?, '2026-07-01T10:00:00Z', '2026-07-01T10:00:00Z', NULL)
        """,
        (_json_dumps(payload),),
    )
    engine.conn.commit()

    assert {finding["code"] for finding in engine.doctor(project_path=repo)["findings"]} == {
        "ORPHAN_MEMORY_BODIES",
        "PARKED_SUPERSEDES",
    }

    applied = engine.doctor(project_path=repo, apply=True, grace_period_seconds=86400.0, parked_retention_days=7)
    assert applied["apply"] == {"applied": True, "prunedOrphans": 1, "prunedSupersedes": 1}

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
    engine.conn.commit()

    reported = {finding["code"] for finding in engine.doctor(project_path=repo)["findings"]}
    assert reported == {"STRANDED_TRANSPORT_WATERMARK", "RECEIPT_COVERAGE_GAP", "UNRESOLVED_GAP"}

    applied = engine.doctor(project_path=repo, apply=True, grace_period_seconds=0.0, parked_retention_days=0)
    assert applied["apply"] == {"applied": True, "prunedOrphans": 0, "prunedSupersedes": 0}

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
