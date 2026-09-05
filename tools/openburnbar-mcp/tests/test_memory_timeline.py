"""Tests for Packet P12 (B8): Memory timeline read API and project-scoped revision history.

Verifies:
1. test_timeline_returns_revisions_in_order
2. test_timeline_reports_the_writing_device_from_meta_json
3. test_timeline_is_scoped_by_project_and_refuses_a_foreign_memory_id
4. test_last_helped_falls_back_to_history_when_no_recall_serve_event_exists
"""

from __future__ import annotations

import json
import subprocess
from pathlib import Path


import memory_engine as me


def _init_git(path: Path) -> str:
    path.mkdir(parents=True, exist_ok=True)
    (path / "README.md").write_text(f"# {path.name}\n")
    subprocess.run(["git", "init", "-q", str(path)], check=True)
    subprocess.run(["git", "-C", str(path), "config", "user.email", "test@burnbar.local"], check=True)
    subprocess.run(["git", "-C", str(path), "config", "user.name", "Test Committer"], check=True)
    subprocess.run(["git", "-C", str(path), "add", "README.md"], check=True)
    subprocess.run(["git", "-C", str(path), "commit", "-m", f"init {path.name}", "-q"], check=True)
    return str(path)


def _engine(tmp_path: Path) -> me.MemoryEngine:
    return me.MemoryEngine.open(
        tmp_path / "engine.sqlite",
        provider=me.FakeEmbeddingProvider(),
        config=me.EngineConfig(actor="test-actor"),
    )


def test_timeline_returns_revisions_in_order(tmp_path: Path) -> None:
    repo = _init_git(tmp_path / "repo")
    engine = _engine(tmp_path)

    # Initial creation
    res1 = engine.remember("Project rule: always run tests before push.", project_path=repo)
    assert res1["status"] == "ok"
    mem_id = res1["memoryID"]

    # Second revision via _history (e.g. edit / update)
    proj_id, _ = engine.resolve_project(repo)
    engine._history(
        mem_id,
        proj_id,
        "updated",
        "Project rule: always run tests before push.",
        "Project rule: always run tests before push with coverage.",
        {"reason": "tightened policy"},
    )
    # Third revision (e.g. retired / folded)
    engine._history(
        mem_id,
        proj_id,
        "retired",
        "Project rule: always run tests before push with coverage.",
        None,
        {"reason": "deprecated"},
    )

    timeline = engine.timeline(mem_id, project_path=repo)
    assert timeline["status"] == "ok"
    revisions = timeline["revisions"]
    assert len(revisions) == 3

    seqs = [r["seq"] for r in revisions]
    assert seqs == sorted(seqs), "Revisions must be returned in ascending seq order"
    assert revisions[0]["event"] == "created"
    assert revisions[0]["after"] == "Project rule: always run tests before push."
    assert revisions[1]["event"] == "updated"
    assert revisions[1]["before"] == "Project rule: always run tests before push."
    assert revisions[1]["after"] == "Project rule: always run tests before push with coverage."
    assert revisions[2]["event"] == "retired"


def test_timeline_reports_the_writing_device_from_meta_json(tmp_path: Path) -> None:
    repo = _init_git(tmp_path / "repo")
    engine = _engine(tmp_path)

    res = engine.remember(
        "Memory with explicit writer device in metadata.",
        project_path=repo,
        metadata={"writerDevice": "macbook-pro-m3"},
    )
    assert res["status"] == "ok"
    mem_id = res["memoryID"]

    # Also add a revision with writer_device snake_case
    proj_id, _ = engine.resolve_project(repo)
    engine._history(
        mem_id,
        proj_id,
        "synced",
        None,
        "Memory with explicit writer device in metadata.",
        {"writer_device": "studio-ultra"},
    )

    timeline = engine.timeline(mem_id, project_path=repo)
    assert timeline["status"] == "ok"
    revisions = timeline["revisions"]
    assert len(revisions) == 2

    assert revisions[0]["writerDevice"] == "macbook-pro-m3"
    assert revisions[0]["writerDevice"] == "macbook-pro-m3"

    assert revisions[1]["writerDevice"] == "studio-ultra"
    assert revisions[1]["writerDevice"] == "studio-ultra"


def test_timeline_is_scoped_by_project_and_refuses_a_foreign_memory_id(tmp_path: Path) -> None:
    repo_a = _init_git(tmp_path / "repo_a")
    repo_b = _init_git(tmp_path / "repo_b")
    engine = _engine(tmp_path)

    res_b = engine.remember(
        "CONFIDENTIAL_CREDENTIAL_XYZ: repo-b secret prompt and sensitive architecture notes",
        project_path=repo_b,
    )
    assert res_b["status"] == "ok"
    mem_b_id = res_b["memoryID"]

    # Requesting repo_b memory from repo_a scope MUST be refused
    timeline = engine.timeline(mem_b_id, project_path=repo_a)
    assert timeline["status"] == "refused"
    assert timeline["code"] == "FOREIGN_PROJECT"

    # CRITICAL: Foreign project refusal must assert NO body, NO meta, NO revisions returned
    assert "body" not in timeline
    assert "meta" not in timeline
    assert "revisions" not in timeline
    assert "events" not in timeline
    assert "CONFIDENTIAL_CREDENTIAL_XYZ" not in str(timeline)


def test_last_helped_falls_back_to_history_when_no_recall_serve_event_exists(tmp_path: Path) -> None:
    repo = _init_git(tmp_path / "repo")
    engine = _engine(tmp_path)

    res = engine.remember("Helpful memory for testing last-helped fallback.", project_path=repo)
    assert res["status"] == "ok"
    mem_id = res["memoryID"]

    # 1. No recall-serve event exists yet -> last-helped must fall back to history
    timeline1 = engine.timeline(mem_id, project_path=repo)
    assert timeline1["status"] == "ok"
    assert timeline1["lastHelpedSource"] == "history"
    assert timeline1["lastHelpedAt"] is not None

    history_last_helped = timeline1["lastHelpedAt"]

    # 2. Recall serves the memory -> logs memory.recall_serve audit event
    recall_res = engine.recall("Helpful memory", project_path=repo)
    assert len(recall_res["results"]) >= 1
    recalled_ids = [m["memoryID"] for m in recall_res["results"]]
    assert mem_id in recalled_ids

    # 3. Timeline now reflects the recall-serve event
    timeline2 = engine.timeline(mem_id, project_path=repo)
    assert timeline2["status"] == "ok"
    assert timeline2["lastHelpedSource"] == "recall_serve"
    assert timeline2["lastHelpedAt"] is not None
    assert timeline2["lastHelpedAt"] >= history_last_helped


def _seed_distinct(engine: me.MemoryEngine, repo: str, count: int = 25) -> list[str]:
    """Bodies that share the query terms but are not near-duplicates of each other."""
    subjects = [
        "staging deploy",
        "release runbook",
        "rollback drill",
        "canary window",
        "migration order",
    ]
    ids = []
    for index in range(count):
        subject = subjects[index % len(subjects)]
        stored = engine.remember(
            f"The {subject} for service number {index} is owned by team {index} and reviewed quarterly.",
            project_path=repo,
        )
        if stored.get("memoryID"):
            ids.append(str(stored["memoryID"]))
    return ids


def test_a_recall_appends_exactly_one_audit_row(tmp_path: Path) -> None:
    """I6: recall writes, so what it writes has to be one row, not one per hit.

    `memory.recall_serve` is what makes "last helped" answerable, and the packet
    sanctions adding it. One row per returned hit does not: a single
    `recall(limit=20)` then consumes twenty rows of an append-only, never-swept
    table that `verify_audit_chain` re-hashes end to end on every `audit_trail`
    and every `doctor`. One event per recall carries the same information — the
    ids ride in `labels`, bounded by the recall limit — at one twentieth of the
    cost.
    """
    repo = _init_git(tmp_path / "repo")
    engine = _engine(tmp_path)
    _seed_distinct(engine, repo)

    before = int(engine.conn.execute("SELECT COUNT(*) FROM memory_audit").fetchone()[0])
    result = engine.recall("release runbook deploy", project_path=repo, limit=20)
    served = [str(item["memoryID"]) for item in result["results"]]
    assert len(served) > 1, "the fixture has to return several hits for this to mean anything"
    after = int(engine.conn.execute("SELECT COUNT(*) FROM memory_audit").fetchone()[0])
    assert after - before == 1, f"one recall wrote {after - before} audit rows"

    row = engine.conn.execute(
        "SELECT subject_id, labels_json, project_id FROM memory_audit "
        "WHERE action = 'memory.recall_serve' ORDER BY seq DESC LIMIT 1"
    ).fetchone()
    # The event is about the recall, not about any one memory.
    assert row["subject_id"] is None
    assert str(row["project_id"]) == engine.resolve_project(repo)[0]
    labels = set(json.loads(row["labels_json"]))
    assert {f"served:{memory_id}" for memory_id in served} <= labels
    # Bounded by the recall limit, whatever the store holds.
    assert len([label for label in labels if label.startswith("served:")]) <= 20

    # And the ids in the labels are still what "last helped" reads.
    timeline = engine.timeline(served[0], project_path=repo)
    assert timeline["lastHelpedSource"] == "recall_serve"
    # A memory the recall did NOT serve is not claimed to have helped.
    unserved = [
        str(unrelated["id"])
        for unrelated in engine.conn.execute("SELECT id FROM memories").fetchall()
        if str(unrelated["id"]) not in served
    ]
    if unserved:
        assert engine.timeline(unserved[0], project_path=repo)["lastHelpedSource"] == "history"
    engine.close()


def test_the_audit_trail_default_window_still_shows_writes_after_recalls(tmp_path: Path) -> None:
    """I6: the audit trail is a record of what happened TO memories, not a request log.

    `burnbar_audit_trail`'s default window is 50 rows. At one row per hit, three
    recalls evicted every `memory.add`, `memory.forget`,
    `memory.secret_redacted` and `memory.injection_quarantined` event from the
    default view — the whole thing the tool exists to show.
    """
    repo = _init_git(tmp_path / "repo")
    engine = _engine(tmp_path)
    _seed_distinct(engine, repo)
    for _ in range(3):
        engine.recall("release runbook deploy", project_path=repo, limit=20)

    actions = [str(event["action"]) for event in engine.audit_trail(project_path=repo)["events"]]
    assert actions.count("memory.recall_serve") == 3
    writes = [action for action in actions if action != "memory.recall_serve"]
    assert len(writes) >= 20, actions[:12]
    engine.close()
