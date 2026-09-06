#!/usr/bin/env python3
"""Code-memory reads stay reads.

The MCP code tools reach an encrypted store through the daemon's
`daemon.search.sql` surface, which runs `sqlite3_stmt_readonly` over every
statement and refuses anything else. Every code read used to open with
`ensure_schema(conn)` -- `PRAGMA` + `CREATE TABLE` -- and then
`resolve_project_id(conn, root)`, which INSERTs project and alias bookkeeping.
Both are writes, so all eight code tools were dead against a real store.

These tests pin the fix: a read against an initialised store issues SELECTs and
nothing else, a read against an uninitialised store says the index was never
built instead of creating tables behind the caller's back, and the indexer keeps
its own legitimate route to the schema.
"""

from __future__ import annotations

import re
import sqlite3
import subprocess
import sys
from pathlib import Path
from typing import Any

import pytest

_HERE = Path(__file__).resolve().parent
_PARENT = _HERE.parent
if str(_PARENT) not in sys.path:
    sys.path.insert(0, str(_PARENT))

import project_code_memory as pcm  # noqa: E402

# Mirrors what SQLite's `sqlite3_stmt_readonly` rejects, which is what the
# daemon's read surface enforces. PRAGMA is included because the very first
# statement `ensure_schema` issued -- `PRAGMA foreign_keys=ON` -- is the one the
# daemon refused in production.
NON_SELECT = re.compile(
    r"^\s*(PRAGMA|CREATE|ALTER|DROP|INSERT|UPDATE|DELETE|REPLACE|VACUUM|REINDEX|BEGIN|COMMIT)\b",
    re.IGNORECASE,
)


class SelectOnlyRefusal(RuntimeError):
    """What the daemon returns: `Only SELECT (or WITH … SELECT) statements are allowed.`"""


class SelectOnlyConnection:
    """A stand-in for the daemon's SELECT-only read handle.

    Wraps a real connection, records every statement, and refuses non-SELECTs
    the way the daemon does. `executemany` is absent on purpose: the daemon shim
    (`server._DaemonReadConnection`) does not define it either, so a read path
    that reaches for it is broken in production even before the refusal.
    """

    def __init__(self, conn: sqlite3.Connection) -> None:
        self._conn = conn
        self.statements: list[str] = []

    def execute(self, sql: str, params: Any = ()) -> sqlite3.Cursor:
        self.statements.append(" ".join(sql.split()))
        if NON_SELECT.match(sql):
            raise SelectOnlyRefusal("Only SELECT (or WITH … SELECT) statements are allowed.")
        return self._conn.execute(sql, params)

    @property
    def non_select_statements(self) -> list[str]:
        return [statement for statement in self.statements if NON_SELECT.match(statement)]


def _indexed_repo(tmp_path: Path) -> tuple[Path, Path]:
    """A tiny git repo indexed into a fresh store. Returns (repo, db_path)."""
    repo = tmp_path / "repo-readonly"
    repo.mkdir()
    (repo / "main.py").write_text(
        "def alpha_readonly():\n"
        "    return beta_readonly()\n"
        "\n"
        "def beta_readonly():\n"
        "    return gamma_readonly()\n"
        "\n"
        "def gamma_readonly():\n"
        "    return 42\n",
        encoding="utf-8",
    )
    # A committed repo with a remote: the project identity is then derived from
    # git rather than the path, which is what makes a moved checkout resolve back
    # to the same project.
    for args in (
        ("init", "-q"),
        ("config", "user.email", "agent@example.com"),
        ("config", "user.name", "Agent"),
        ("remote", "add", "origin", "https://example.com/openburnbar/readonly-fixture.git"),
        ("add", "."),
        ("commit", "-q", "-m", "Initial fixture"),
    ):
        subprocess.run(["git", *args], cwd=repo, check=True, capture_output=True)
    db_path = tmp_path / "openburnbar.sqlite"
    with sqlite3.connect(db_path) as conn:
        conn.row_factory = sqlite3.Row
        pcm.index_project(conn, str(repo), max_files=25)
    return repo, db_path


READS = (
    ("search_code", lambda conn, repo: pcm.search_code(conn, "readonly", str(repo), 5)),
    ("context_pack", lambda conn, repo: pcm.context_pack(conn, "readonly", str(repo), 4000, 3)),
    ("get_symbol", lambda conn, repo: pcm.get_symbol(conn, "alpha_readonly", str(repo), 5)),
    ("find_references", lambda conn, repo: pcm.find_references(conn, "beta_readonly", str(repo), 5)),
    ("call_graph", lambda conn, repo: pcm.call_graph(conn, "alpha_readonly", str(repo), 3, 50)),
    ("diagnostics", lambda conn, repo: pcm.diagnostics(conn, str(repo), None, 5)),
    ("index_status", lambda conn, repo: pcm.index_status(conn, str(repo))),
    ("repo_map", lambda conn, repo: pcm.repo_map(conn, str(repo), 10)),
)


@pytest.mark.parametrize("name,read", READS, ids=[name for name, _ in READS])
def test_reads_against_an_initialised_store_issue_no_write_statements(tmp_path: Path, name: str, read: Any) -> None:
    """The regression itself: every code read is SELECT-only over the daemon surface.

    Asserting on the statements the surface receives, not merely on success --
    a read that "works" while smuggling a CREATE TABLE past a permissive local
    connection is still the bug.
    """
    repo, db_path = _indexed_repo(tmp_path)
    with sqlite3.connect(db_path) as backing:
        backing.row_factory = sqlite3.Row
        conn = SelectOnlyConnection(backing)
        payload = read(conn, repo)

    assert conn.non_select_statements == [], (
        f"{name} issued write statements through the daemon's SELECT-only read surface"
    )
    assert conn.statements, f"{name} issued no statements at all"
    # `repo_map` returns a bare summary with no status field; the rest report one.
    assert payload.get("status", "ok") in {"ok", "degraded"}, payload
    assert payload["projectRoot"] == str(repo.resolve()), payload


@pytest.mark.parametrize("name,read", READS, ids=[name for name, _ in READS])
def test_reads_against_an_uninitialised_store_say_so_instead_of_creating_tables(
    tmp_path: Path, name: str, read: Any
) -> None:
    """No index yet is a fact to report, not a schema to create behind the caller."""
    repo = tmp_path / "repo-unbuilt"
    repo.mkdir()
    (repo / "main.py").write_text("def unbuilt():\n    return 1\n", encoding="utf-8")
    subprocess.run(["git", "init", "-q"], cwd=repo, check=True, capture_output=True)

    with sqlite3.connect(tmp_path / "empty.sqlite") as backing:
        conn = SelectOnlyConnection(backing)
        payload = read(conn, repo)

    assert conn.non_select_statements == [], f"{name} attempted DDL against an uninitialised store"
    assert payload["status"] == "unavailable"
    assert payload["code"] == "INDEX_NOT_BUILT"
    # Actionable: it names the tool that builds the index.
    assert "burnbar_index_project" in payload["reindexHint"]
    assert payload["missingTables"], "the payload should name what is missing"
    assert payload["projectRoot"] == str(repo.resolve())


def test_the_indexer_still_creates_the_schema_through_its_own_route(tmp_path: Path) -> None:
    """Fixing the read path must not cost the write path its legitimate DDL."""
    repo = tmp_path / "repo-indexes"
    repo.mkdir()
    (repo / "main.py").write_text("def created_by_indexer():\n    return 1\n", encoding="utf-8")
    subprocess.run(["git", "init", "-q"], cwd=repo, check=True, capture_output=True)

    db_path = tmp_path / "fresh.sqlite"
    with sqlite3.connect(db_path) as conn:
        conn.row_factory = sqlite3.Row
        # An unbuilt store reports itself unbuilt...
        assert pcm.search_code(conn, "created", str(repo), 5)["code"] == "INDEX_NOT_BUILT"
        # ...until the indexer, which is a write path, builds it.
        assert pcm.index_project(conn, str(repo), max_files=25)["status"] == "ok"
        assert pcm.code_memory_missing_tables(conn) == []
        assert pcm.search_code(conn, "created", str(repo), 5)["status"] in {"ok", "degraded"}


def test_read_only_and_recording_project_resolution_agree(tmp_path: Path) -> None:
    """The read-only resolver must not drift from the one that records the mapping."""
    repo, db_path = _indexed_repo(tmp_path)
    with sqlite3.connect(db_path) as conn:
        conn.row_factory = sqlite3.Row
        recorded = pcm.resolve_project_id(conn, repo)
        read_only = pcm.resolve_project_id_readonly(conn, repo)
    assert read_only == recorded


def test_call_graph_multi_hop_needs_no_temp_table(tmp_path: Path) -> None:
    """The BFS frontier binds inline.

    A TEMP TABLE is DDL the daemon refuses, and every statement there is its own
    RPC on its own handle, so the table would not survive to the next hop even
    if it were allowed. Depth>1 is the case that used to reach for it.
    """
    repo, db_path = _indexed_repo(tmp_path)
    with sqlite3.connect(db_path) as backing:
        backing.row_factory = sqlite3.Row
        conn = SelectOnlyConnection(backing)
        deep = pcm.call_graph(conn, "alpha_readonly", str(repo), 3, 50)

    assert conn.non_select_statements == []
    assert not any("temp_code_call_frontier" in statement for statement in conn.statements)
    pairs = {(edge["caller"], edge["callee"]) for edge in deep["edges"]}
    assert ("alpha_readonly", "beta_readonly") in pairs
    assert ("beta_readonly", "gamma_readonly") in pairs
    assert any(edge["hop"] == 2 for edge in deep["edges"])


def test_frontier_batching_keeps_every_name_when_it_exceeds_one_statement(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A frontier larger than one statement's binding batch loses no edges."""
    repo, db_path = _indexed_repo(tmp_path)
    with sqlite3.connect(db_path) as backing:
        backing.row_factory = sqlite3.Row
        whole = pcm.call_graph(SelectOnlyConnection(backing), "alpha_readonly", str(repo), 3, 50)
        # One name per statement: the same answer must survive the batching.
        monkeypatch.setattr(pcm, "CALL_GRAPH_FRONTIER_BATCH", 1)
        batched = pcm.call_graph(SelectOnlyConnection(backing), "alpha_readonly", str(repo), 3, 50)
    assert batched["edges"] == whole["edges"]


def test_a_moved_checkout_reads_without_repointing_the_stored_root(tmp_path: Path) -> None:
    """Freshness resolves under the root the caller named, not the stored one.

    `resolve_project_id` used to UPDATE `code_index_checkpoints.project_root` on
    the way past, so a read of a moved checkout silently repaired itself. Without
    that write every hit resolved to a path that no longer exists, looked stale,
    and was dropped -- an empty result set rather than an error.
    """
    repo, db_path = _indexed_repo(tmp_path)
    moved = tmp_path / "repo-readonly-moved"
    repo.rename(moved)

    with sqlite3.connect(db_path) as backing:
        backing.row_factory = sqlite3.Row
        conn = SelectOnlyConnection(backing)
        payload = pcm.search_code(conn, "readonly", str(moved), 5)

    assert conn.non_select_statements == []
    assert payload["status"] in {"ok", "degraded"}
    assert payload["results"], "a moved checkout should still return its indexed files"
    assert payload["results"][0]["filePath"] == "main.py"

    # The stored checkpoint still points at the old path: the read left it alone.
    with sqlite3.connect(db_path) as backing:
        stored = backing.execute("SELECT project_root FROM code_index_checkpoints LIMIT 1").fetchone()[0]
    assert stored == str(repo.resolve())
