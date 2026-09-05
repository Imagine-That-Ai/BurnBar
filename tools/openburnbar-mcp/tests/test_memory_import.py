"""Tests for guarded assistant-export importer (ChatGPT / Claude.ai).

Guarantees:
1. Strict export-schema version gate: unknown versions rejected, not guessed.
2. Parser output lands in quarantine only (review_status = 'quarantined').
3. Entry secret sweep flags secrets and refuses to store them.
4. Convergence key deduplication collapses identical bodies.
5. Oversized exports respect the batch cap and report a complete summary.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

MCP_DIR = Path(__file__).resolve().parents[1]
if str(MCP_DIR) not in sys.path:
    sys.path.insert(0, str(MCP_DIR))

import eval_memory  # noqa: E402
import memory_engine as me  # noqa: E402
from memory_engine._util import _convergence_key  # noqa: E402
from test_memory_engine import _load_server, _repo  # noqa: E402

FIXTURE_PATH = MCP_DIR / "tests" / "fixtures" / "assistant_export.json"


def _server(server_env: Path, monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("OPENBURNBAR_LOCAL_MCP_ENABLE_MEMORY_WRITE", "true")
    monkeypatch.setenv(me.MEMORY_DB_PATH_ENV, str(server_env / "openburnbar-memory.sqlite"))
    return _load_server()


def _expanded_fixture() -> tuple[dict, str]:
    raw = FIXTURE_PATH.read_text(encoding="utf-8")
    expanded = eval_memory._expand_secrets(raw)
    token = eval_memory.SECRET_SHAPES["github_pat"]
    assert token in expanded, "fixture expansion must produce a synthetic github_pat token"
    return json.loads(expanded), token


def test_an_unknown_export_schema_version_is_rejected(server_env: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """Unknown or unsupported schema versions are rejected fail-closed, never guessed."""
    server = _server(server_env, monkeypatch)
    repo = _repo(server_env)
    payload, _ = _expanded_fixture()

    # 1. Bumped major version of a known client
    payload["schema"] = "chatgpt.export.v2"
    result = json.loads(server.burnbar_memory_import(json.dumps(payload), project_path=repo))
    assert result["status"] in ("rejected", "unavailable")
    assert result["code"] == "UNKNOWN_SCHEMA_VERSION"
    assert "unknown" in result["reason"].lower() or "unsupported" in result["reason"].lower()

    # 2. Entirely unknown schema identifier
    payload["schema"] = "random_untrusted_vendor.v1"
    result2 = json.loads(server.burnbar_memory_import(json.dumps(payload), project_path=repo))
    assert result2["status"] in ("rejected", "unavailable")
    assert result2["code"] == "UNKNOWN_SCHEMA_VERSION"

    # 3. Explicit schema argument that is unknown
    result3 = json.loads(
        server.burnbar_memory_import(json.dumps(payload), project_path=repo, schema="claude.export.v99")
    )
    assert result3["status"] in ("rejected", "unavailable")
    assert result3["code"] == "UNKNOWN_SCHEMA_VERSION"

    # Verify zero memories were stored in the database
    with server._memory_engine() as engine:
        count = engine.conn.execute("SELECT count(*) FROM memories").fetchone()[0]
        assert count == 0


def test_every_imported_row_lands_quarantined(server_env: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """Parser output lands strictly in quarantine; human must approve before anything is approved."""
    server = _server(server_env, monkeypatch)
    repo = _repo(server_env)
    payload, _ = _expanded_fixture()

    result = json.loads(server.burnbar_memory_import(json.dumps(payload), project_path=repo))
    assert result["status"] == "ok"
    assert result["summary"]["quarantined"] > 0
    assert result["summary"]["approved"] == 0

    # Inspect each decision that added a row
    add_decisions = [d for d in result.get("decisions", []) if d.get("event") in ("ADD", "UPDATE")]
    assert len(add_decisions) > 0
    for decision in add_decisions:
        assert decision.get("reviewStatus") == "quarantined"

    with server._memory_engine() as engine:
        # SQLite verification
        rows = engine.conn.execute("SELECT review_status FROM memories").fetchall()
        assert len(rows) > 0
        for (status,) in rows:
            assert status == "quarantined", f"expected quarantined row, got {status}"

        # Recall/List behavior: approved list is completely empty
        approved_list = engine.list(project_path=repo, review_status="approved")["results"]
        assert len(approved_list) == 0

        # Quarantined list contains all stored memories
        quarantined_list = engine.list(project_path=repo, review_status="quarantined")["results"]
        assert len(quarantined_list) == len(rows)


def test_secrets_in_an_export_are_flagged_not_stored(server_env: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """Secret sweep on entry flags credentials and refuses to store them in the database."""
    server = _server(server_env, monkeypatch)
    repo = _repo(server_env)
    payload, token = _expanded_fixture()

    result = json.loads(server.burnbar_memory_import(json.dumps(payload), project_path=repo))
    assert result["status"] == "ok"

    # Secrets flagged count in summary
    assert result["summary"]["secretsFlagged"] >= 1

    # Rejected decision recorded for secret
    reject_decisions = [
        d for d in result.get("decisions", []) if d.get("event") == "REJECT" and d.get("code") == "SECRET_DETECTED"
    ]
    assert len(reject_decisions) >= 1
    assert any("github" in str(label).lower() for d in reject_decisions for label in d.get("labels", []))

    # Verify that the secret token is NOT stored anywhere in the database
    with server._memory_engine() as engine:
        memories = engine.list(project_path=repo, review_status="quarantined")["results"]
        assert len(memories) > 0
        for mem in memories:
            assert token not in mem.get("body", ""), "secret token leaked into stored memory body"
            assert token not in str(mem), "secret token leaked into memory record"

        raw_rows = engine.conn.execute("SELECT body_hash FROM memories").fetchall()
        secret_body_hash = me.canonical_body_hash(f"Here is the secret API token: {token} for deployment access.")
        assert not any(row[0] == secret_body_hash for row in raw_rows)


def test_duplicate_bodies_collapse_on_the_convergence_key(server_env: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """Identical message bodies collapse on the convergence key (project, scope, body_hash)."""
    server = _server(server_env, monkeypatch)
    repo = _repo(server_env)
    payload, _ = _expanded_fixture()

    duplicate_text = "The production PostgreSQL database runs on port 5432 with sslmode=verify-full."
    result = json.loads(server.burnbar_memory_import(json.dumps(payload), project_path=repo))
    assert result["status"] == "ok"
    assert result["summary"]["duplicatesCollapsed"] >= 1

    # Check collapse decisions
    collapse_decisions = [
        d
        for d in result.get("decisions", [])
        if d.get("code") == "DUPLICATE_CONVERGENCE_KEY" or d.get("event") in ("COLLAPSE", "NONE")
    ]
    assert len(collapse_decisions) >= 1

    with server._memory_engine() as engine:
        project_id, _ = me.resolve_project(engine.conn, repo)
        body_hash = me.canonical_body_hash(duplicate_text)
        expected_ckey = _convergence_key(project_id, "project", body_hash)

        # Decision recorded matching convergence key
        assert any(d.get("convergenceKey") == expected_ckey for d in collapse_decisions)

        # Database contains exactly ONE copy of the duplicate body
        count = engine.conn.execute("SELECT count(*) FROM memories WHERE body_hash = ?", (body_hash,)).fetchone()[0]
        assert count == 1, f"expected exactly 1 row for duplicate body, found {count}"


def test_an_oversized_export_respects_the_batch_cap_and_reports_a_summary(
    server_env: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Bounded batches respect the batch cap and emit complete summary statistics."""
    server = _server(server_env, monkeypatch)
    repo = _repo(server_env)
    payload, _ = _expanded_fixture()

    # The fixture has 15 candidates total; default batch cap is 10
    batch_cap = 10
    result = json.loads(server.burnbar_memory_import(json.dumps(payload), project_path=repo, batch_cap=batch_cap))
    assert result["status"] == "ok"

    summary = result["summary"]
    assert summary["batchCapped"] is True
    assert summary["batchCap"] == batch_cap
    assert summary["totalCandidates"] == 15
    assert summary.get("imported") <= batch_cap

    with server._memory_engine() as engine:
        total_stored = engine.conn.execute("SELECT count(*) FROM memories").fetchone()[0]
        assert total_stored <= batch_cap
        assert total_stored == summary.get("imported")


def test_claude_export_schema_and_messages_imported_quarantined(
    server_env: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Claude.ai exports with chat_messages land quarantined and adhere to the schema gate."""
    server = _server(server_env, monkeypatch)
    repo = _repo(server_env)

    claude_payload = {
        "schema": "claude.export.v1",
        "conversations": [
            {
                "uuid": "claude-conv-101",
                "name": "Frontend Architecture",
                "created_at": "2026-08-01T10:00:00Z",
                "chat_messages": [
                    {
                        "uuid": "msg-c1",
                        "sender": "human",
                        "text": "React 19 Server Components are preferred for data fetching.",
                        "created_at": "2026-08-01T10:00:00Z",
                    },
                    {
                        "uuid": "msg-c2",
                        "sender": "assistant",
                        "text": "Understood, will use Server Components with Suspense boundaries.",
                        "created_at": "2026-08-01T10:00:05Z",
                    },
                ],
            }
        ],
    }

    result = json.loads(server.burnbar_memory_import(json.dumps(claude_payload), project_path=repo))
    assert result["status"] == "ok"
    assert result["summary"]["quarantined"] == 2
    assert result["summary"]["approved"] == 0

    with server._memory_engine() as engine:
        rows = engine.conn.execute("SELECT review_status, source_ref FROM memories").fetchall()
        assert len(rows) == 2
        for status, ref in rows:
            assert status == "quarantined"
            assert ref.startswith("claude:claude-conv-101#")


def test_a_near_duplicate_import_does_not_report_a_quarantine_that_did_not_happen(
    server_env: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """I10: the summary is a claim about member data, so it says what actually landed.

    `reviewStatus` was stamped `"quarantined"` on every decision unconditionally,
    after `_commit_fact` had already returned. The exact-body dedupe above it
    only catches `body_hash` equality; a NEAR-duplicate takes the reinforce path
    and reinforces an existing **approved** row — and the response then told the
    caller that row was quarantined.
    """
    server = _server(server_env, monkeypatch)
    repo = _repo(server_env)

    approved_body = "The deployment pipeline runs the migration step before the smoke tests."
    with server._memory_engine() as engine:
        stored = engine.remember(approved_body, project_path=repo, kind="fact")
        memory_id = str(stored["memoryID"])
        assert engine.get(memory_id)["memory"]["reviewStatus"] == "approved"

    payload = {
        "schema": "chatgpt.export.v1",
        "conversations": [
            {
                "id": "conv-near-dup",
                "title": "Deploys",
                "create_time": 1756000000,
                "mapping": {
                    "m1": {
                        "message": {
                            "id": "m1",
                            "author": {"role": "user"},
                            "create_time": 1756000001,
                            "content": {
                                "content_type": "text",
                                "parts": [
                                    "The deployment pipeline runs the migration step before the smoke tests, always."
                                ],
                            },
                        }
                    }
                },
            }
        ],
    }
    result = json.loads(server.burnbar_memory_import(json.dumps(payload), project_path=repo))
    assert result["status"] == "ok"

    with server._memory_engine() as engine:
        for decision in result.get("decisions", []):
            landed = decision.get("memoryID")
            if not landed:
                continue
            row = engine.conn.execute("SELECT review_status FROM memories WHERE id = ?", (landed,)).fetchone()
            assert row is not None
            assert decision.get("reviewStatus") == str(row["review_status"]), (
                f"the importer reported {decision.get('reviewStatus')!r} for a row that is "
                f"{str(row['review_status'])!r}"
            )
        # The approved row it reinforced is still approved.
        assert engine.get(memory_id)["memory"]["reviewStatus"] == "approved"


def test_a_caller_supplied_batch_cap_cannot_remove_the_bound(server_env: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """I10/C14: the cap is the bound, so the caller may lower it and never lift it away.

    `burnbar_memory_import(batch_cap=10**9)` removed the very thing the packet
    asked for — an unbounded import of unreviewed, model-authored text in one
    call.
    """
    import assistant_export

    server = _server(server_env, monkeypatch)
    repo = _repo(server_env)
    payload, _ = _expanded_fixture()

    result = json.loads(server.burnbar_memory_import(json.dumps(payload), project_path=repo, batch_cap=10**9))
    assert result["summary"]["batchCap"] == assistant_export.MAX_IMPORT_BATCH_CAP
    assert result["summary"]["batchCap"] < 10**9
    # A cap below the ceiling is still the caller's to choose.
    result_small = json.loads(server.burnbar_memory_import(json.dumps(payload), project_path=repo, batch_cap=2))
    assert result_small["summary"]["batchCap"] == 2


def test_a_capped_import_resumes_from_the_cursor_it_returned(server_env: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """Nothing past the cap is silently dropped: the caller gets an offset back.

    Every invocation used to select the same first `cap` candidates, so after the
    first call the rest merely collapsed as duplicates and the entries past the
    cap were never considered at all. With the default cap of 10 an ordinary
    export could not be imported in full without editing the payload by hand.
    """
    server = _server(server_env, monkeypatch)
    repo = _repo(server_env)
    payload, _ = _expanded_fixture()

    first = json.loads(server.burnbar_memory_import(json.dumps(payload), project_path=repo, batch_cap=10))
    assert first["status"] == "ok"
    assert first["summary"]["totalCandidates"] == 15
    assert first["summary"]["batchCapped"] is True
    assert first["summary"]["cursor"] == 0
    assert first["summary"]["nextCursor"] == 10
    assert first["summary"]["remaining"] == 5

    second = json.loads(
        server.burnbar_memory_import(
            json.dumps(payload),
            project_path=repo,
            batch_cap=10,
            cursor=first["summary"]["nextCursor"],
        )
    )
    assert second["status"] == "ok"
    assert second["summary"]["cursor"] == 10
    assert second["summary"]["nextCursor"] is None
    assert second["summary"]["remaining"] == 0
    assert second["summary"]["batchCapped"] is False

    # The second batch reached candidates the first never saw: the last entry of
    # the export is in the store, and it is not a collapsed duplicate.
    with server._memory_engine() as engine:
        bodies = [
            row["body"]
            for row in engine.list(project_path=repo, scope="all", review_status="quarantined", page_size=200)[
                "results"
            ]
        ]
    assert any("blue-green" in body for body in bodies), bodies


def test_an_out_of_range_import_cursor_is_refused(server_env: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """A cursor the caller made up must not silently import batch one again."""
    server = _server(server_env, monkeypatch)
    repo = _repo(server_env)
    payload, _ = _expanded_fixture()

    result = json.loads(server.burnbar_memory_import(json.dumps(payload), project_path=repo, cursor=-3))
    assert result["status"] == "rejected"
    assert result["code"] == "INVALID_CURSOR"


def _branched_chatgpt_export() -> dict:
    """A ChatGPT mapping with a regenerated reply, as the real export writes one.

    `mapping` is a tree; a regenerated reply and an edited prompt create sibling
    branches, and `current_node` names the leaf of the branch the user kept.
    """
    return {
        "schema": "chatgpt.conversations.v1",
        "conversations": [
            {
                "id": "conv-branched",
                "title": "Deploy target",
                "current_node": "node-kept",
                "mapping": {
                    "root": {"id": "root", "parent": None, "children": ["node-q"], "message": None},
                    "node-q": {
                        "id": "node-q",
                        "parent": "root",
                        "children": ["node-abandoned", "node-kept"],
                        "message": {
                            "id": "m-q",
                            "create_time": 1.0,
                            "author": {"role": "user"},
                            "content": {"parts": ["Which region does the cluster run in?"]},
                        },
                    },
                    "node-abandoned": {
                        "id": "node-abandoned",
                        "parent": "node-q",
                        "children": [],
                        "message": {
                            "id": "m-abandoned",
                            "create_time": 2.0,
                            "author": {"role": "assistant"},
                            "content": {"parts": ["The cluster runs in eu-west-3."]},
                        },
                    },
                    "node-kept": {
                        "id": "node-kept",
                        "parent": "node-q",
                        "children": [],
                        "message": {
                            "id": "m-kept",
                            "create_time": 3.0,
                            "author": {"role": "assistant"},
                            "content": {"parts": ["Correction: the cluster runs in us-east-1."]},
                        },
                    },
                },
            }
        ],
    }


def test_only_the_active_chatgpt_branch_is_imported(server_env: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """A superseded reply the user regenerated away is not a memory candidate.

    Flattening `mapping.values()` imported abandoned user edits and superseded
    assistant replies alongside the conversation the user actually kept, so
    content the member explicitly rejected became a quarantined candidate that
    contradicts the content they did keep.
    """
    server = _server(server_env, monkeypatch)
    repo = _repo(server_env)
    payload = _branched_chatgpt_export()

    result = json.loads(server.burnbar_memory_import(json.dumps(payload), project_path=repo))
    assert result["status"] == "ok", result
    assert result["summary"]["totalCandidates"] == 2, result["summary"]

    with server._memory_engine() as engine:
        bodies = [
            row["body"]
            for row in engine.list(project_path=repo, scope="all", review_status="quarantined", page_size=200)[
                "results"
            ]
        ]
    assert any("us-east-1" in body for body in bodies), bodies
    assert not any("eu-west-3" in body for body in bodies), bodies


def test_a_mapping_without_a_current_node_still_imports_every_message(
    server_env: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """No branch pointer means no branch to choose: the flat read stays the fallback."""
    server = _server(server_env, monkeypatch)
    repo = _repo(server_env)
    payload = _branched_chatgpt_export()
    payload["conversations"][0].pop("current_node")

    result = json.loads(server.burnbar_memory_import(json.dumps(payload), project_path=repo))
    assert result["summary"]["totalCandidates"] == 3, result["summary"]


def test_every_rejected_import_row_is_counted(server_env: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """`REJECT: 0` for an import that did reject rows makes the metrics unusable.

    The summary counted only the preliminary secret sweep, so a candidate
    `_commit_fact` refused for any other reason — a `reject` PII policy, an
    auxiliary field over its bound — was invisible in the totals.
    """
    monkeypatch.setenv(me.PII_POLICY_ENV, "reject")
    server = _server(server_env, monkeypatch)
    repo = _repo(server_env)
    payload = {
        "schema": "chatgpt.conversations.v1",
        "conversations": [
            {
                "id": "conv-pii",
                "title": "Contact",
                "messages": [
                    {"id": "m1", "role": "user", "text": "Escalations go to alberto@example.com every Friday."},
                    {"id": "m2", "role": "user", "text": "The cluster runs in us-east-1."},
                ],
            }
        ],
    }

    result = json.loads(server.burnbar_memory_import(json.dumps(payload), project_path=repo))
    assert result["status"] == "ok", result
    events = [decision["event"] for decision in result["decisions"]]
    assert events.count("REJECT") >= 1, result["decisions"]
    assert result["summary"]["REJECT"] == events.count("REJECT"), result["summary"]
    assert result["summary"]["ADD"] == events.count("ADD"), result["summary"]
