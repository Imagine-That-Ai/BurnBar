#!/usr/bin/env python3
"""
Code memory over a daemon-backed read connection.

The regression this pins: on a SQLCipher store `_connect_ro` hands the code
tools a `_DaemonReadConnection`, whose only transport is `daemon.search.sql` —
a deliberately SELECT-only surface. Every code-memory read entry point opened
with `ensure_schema(conn)` (PRAGMA + CREATE TABLE + a DROP) and then called
`resolve_project_id`, which INSERTs alias bookkeeping. Both are writes, so the
daemon rejected the first statement and `burnbar_search_code` /
`burnbar_context_pack` failed on every real encrypted install.

The fake daemon here is not a stub that says yes. It mirrors the daemon's own
gate from `OpenBurnBarIndexedSearchService.readOnlySQL`: leading keyword must be
`select` or `with`, exactly one statement, hard row cap — then runs the query on
a real SQLite handle holding a real indexed corpus. A write that reaches it
fails the test the way the daemon fails production.
"""

from __future__ import annotations

import base64
import importlib.util
import json
import os
import sqlite3
import subprocess
import sys
import types
from pathlib import Path

import pytest


_HERE = Path(__file__).resolve().parent
_PARENT = _HERE.parent
if str(_PARENT) not in sys.path:
    sys.path.insert(0, str(_PARENT))

import project_code_memory as pcm  # noqa: E402


def _load_server():
    if "mcp.server.fastmcp" not in sys.modules:
        mcp_mod = types.ModuleType("mcp")
        server_mod = types.ModuleType("mcp.server")
        fastmcp_mod = types.ModuleType("mcp.server.fastmcp")

        class _FastMCP:
            def __init__(self, _name: str):
                pass

            def tool(self):
                def decorator(func):
                    return func

                return decorator

            def run(self):
                raise AssertionError("test stub should not run the MCP server")

        fastmcp_mod.FastMCP = _FastMCP
        sys.modules["mcp"] = mcp_mod
        sys.modules["mcp.server"] = server_mod
        sys.modules["mcp.server.fastmcp"] = fastmcp_mod

    spec = importlib.util.spec_from_file_location(
        "openburnbar_mcp_server_code_daemon_reads_test", str(_PARENT / "server.py")
    )
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules["openburnbar_mcp_server_code_daemon_reads_test"] = module
    spec.loader.exec_module(module)  # type: ignore[union-attr]
    return module


server = _load_server()


# --- the daemon's read-only SQL gate, mirrored ------------------------------


class ReadOnlySQLRejected(RuntimeError):
    """What `daemon.search.sql` raises for a statement that is not a SELECT."""


class FakeDaemonStore:
    """
    `daemon.search.sql` over a real SQLite handle, with the daemon's own
    enforcement: single statement, `select`/`with` leading keyword, row cap.

    Mirrors `OpenBurnBarIndexedSearchService.readOnlySQL`. Only the innermost
    `sqlite3_stmt_readonly` check is absent — Python's sqlite3 does not expose
    it, and the prefix gate is the strictly narrower of the two, so anything
    this accepts the daemon accepts.
    """

    HARD_MAX_ROWS = 2_000
    MAX_STATEMENT_BYTES = 64 << 10

    def __init__(self, db_path: Path) -> None:
        self._conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
        self.statements: list[str] = []
        self.rejections: list[str] = []

    def close(self) -> None:
        self._conn.close()

    def search_sql(self, params: dict) -> dict:
        sql = str(params.get("sql") or "").strip()
        args = [self._from_wire(value) for value in (params.get("args") or [])]
        self.statements.append(sql)
        if not sql:
            raise ReadOnlySQLRejected("SQL statement is empty.")
        if len(sql.encode("utf-8")) > self.MAX_STATEMENT_BYTES:
            raise ReadOnlySQLRejected("SQL statement exceeds the 64KB limit.")
        leading = ""
        for char in sql:
            if not char.isalpha():
                break
            leading += char
        if leading.lower() not in {"select", "with"}:
            self.rejections.append(sql)
            raise ReadOnlySQLRejected("Only SELECT (or WITH ... SELECT) statements are allowed.")
        if sqlite3.complete_statement(sql) and sql.rstrip().rstrip(";").count(";"):
            # Cheap multiple-statement guard; the daemon uses the prepare tail.
            self.rejections.append(sql)
            raise ReadOnlySQLRejected("Exactly one SQL statement is allowed.")

        requested = int(params.get("maxRows") or 200)
        cap = max(1, min(requested, self.HARD_MAX_ROWS))
        cursor = self._conn.execute(sql, args)
        columns = [str(description[0]) for description in (cursor.description or [])]
        rows = cursor.fetchmany(cap + 1)
        truncated = len(rows) > cap
        rows = rows[:cap]
        return {
            "columns": columns,
            "rows": [[self._to_wire(value) for value in row] for row in rows],
            "truncated": truncated,
        }

    @staticmethod
    def _to_wire(value):
        if isinstance(value, (bytes, bytearray, memoryview)):
            return {"$blob": base64.b64encode(bytes(value)).decode("ascii")}
        return value

    @staticmethod
    def _from_wire(value):
        if isinstance(value, dict) and "$blob" in value:
            return base64.b64decode(value["$blob"])
        return value


def _write_ciphertext_fixture(path: Path) -> None:
    """A SQLCipher-shaped file: never the plaintext SQLite magic."""
    payload = os.urandom(16) + os.urandom(4096 - 16)
    assert not payload.startswith(b"SQLite format 3\x00")
    path.write_bytes(payload)


def _make_repo(path: Path) -> Path:
    path.mkdir()
    (path / "main.py").write_text(
        "def daemon_read_target():\n"
        "    \"\"\"Unique needle indexed for the daemon-read tests.\"\"\"\n"
        "    return 'daemon_read_payload'\n"
        "\n"
        "def caller():\n"
        "    return daemon_read_target()\n",
        encoding="utf-8",
    )
    subprocess.run(["git", "init", "-q"], cwd=path, check=True, capture_output=True)
    subprocess.run(["git", "add", "-A"], cwd=path, check=True, capture_output=True)
    subprocess.run(
        ["git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "seed"],
        cwd=path,
        check=True,
        capture_output=True,
    )
    return path


@pytest.fixture()
def indexed_store(tmp_path: Path):
    """A real indexed plaintext corpus, plus a ciphertext file at the tool path."""
    repo = _make_repo(tmp_path / "repo")
    plaintext = tmp_path / "plaintext.sqlite"
    with sqlite3.connect(plaintext) as conn:
        conn.row_factory = sqlite3.Row
        indexed = pcm.index_project(conn, str(repo), max_files=25)
        assert indexed["indexedFiles"] == 1
    encrypted = tmp_path / "openburnbar.sqlite"
    _write_ciphertext_fixture(encrypted)
    return types.SimpleNamespace(repo=repo, plaintext=plaintext, encrypted=encrypted)


@pytest.fixture()
def daemon_backed(indexed_store, monkeypatch):
    """`server` wired so `_connect_ro` yields a real `_DaemonReadConnection`."""
    store = FakeDaemonStore(indexed_store.plaintext)

    def fake_call_daemon(method, params, timeout_seconds=1.5):
        assert method == "daemon.search.sql"
        return store.search_sql(params)

    monkeypatch.setattr(server.pcm, "call_daemon", fake_call_daemon)
    # No courier in the test bed: exercise the direct-socket branch of the shim.
    monkeypatch.setattr(server, "_signed_cli_path", lambda: None)
    monkeypatch.setenv("BURNBAR_DB_PATH", str(indexed_store.encrypted))
    try:
        yield types.SimpleNamespace(store=store, **vars(indexed_store))
    finally:
        store.close()


def test_connect_ro_on_encrypted_store_is_the_daemon_shim(daemon_backed):
    conn = server._connect_ro(daemon_backed.encrypted)
    assert isinstance(conn, server._DaemonReadConnection)
    assert conn.burnbar_read_only is True


def test_search_code_returns_real_results_over_the_daemon(daemon_backed):
    payload = json.loads(server.burnbar_search_code(query="daemon_read_target", project_path=str(daemon_backed.repo)))

    assert payload.get("status") in {"ok", "degraded"}, payload
    assert payload["results"], payload
    assert any(result["filePath"] == "main.py" for result in payload["results"])
    assert any("daemon_read_target" in result["snippet"] for result in payload["results"])
    assert not daemon_backed.store.rejections, daemon_backed.store.rejections


def test_context_pack_returns_real_results_over_the_daemon(daemon_backed):
    payload = json.loads(
        server.burnbar_context_pack(query="daemon_read_target", project_path=str(daemon_backed.repo))
    )

    assert payload["contextPack"], payload
    assert '<file path="main.py"' in payload["contextPack"]
    assert "daemon_read_target" in payload["contextPack"]
    assert payload["estimatedTokens"] > 0
    assert payload["tokenBudget"] >= 500
    assert not daemon_backed.store.rejections, daemon_backed.store.rejections


def test_code_context_pack_alias_returns_real_results_over_the_daemon(daemon_backed):
    payload = json.loads(
        server.burnbar_code_context_pack(query="daemon_read_target", project_path=str(daemon_backed.repo))
    )

    assert payload["contextPack"], payload
    assert "daemon_read_target" in payload["contextPack"]
    assert not daemon_backed.store.rejections, daemon_backed.store.rejections


def test_daemon_backed_reads_never_attempt_a_write(daemon_backed):
    server.burnbar_search_code(query="daemon_read_target", project_path=str(daemon_backed.repo))
    server.burnbar_context_pack(query="daemon_read_target", project_path=str(daemon_backed.repo))

    for statement in daemon_backed.store.statements:
        leading = statement.strip().split(None, 1)[0].lower() if statement.strip() else ""
        assert leading in {"select", "with"}, statement


# --- the rest of the code-memory read surface -------------------------------
#
# `ensure_schema` + `resolve_project_id` head every one of these, so the daemon
# rejected all of them for the same reason `burnbar_search_code` was rejected.
# The two the report named were the two someone happened to call.


def test_get_symbol_returns_real_results_over_the_daemon(daemon_backed):
    payload = json.loads(
        server.burnbar_get_symbol(name="daemon_read_target", project_path=str(daemon_backed.repo))
    )

    assert payload["symbols"], payload
    assert any(symbol["name"] == "daemon_read_target" for symbol in payload["symbols"])
    assert not daemon_backed.store.rejections, daemon_backed.store.rejections


def test_find_references_answers_over_the_daemon(daemon_backed):
    payload = json.loads(
        server.burnbar_find_references(symbol_name="daemon_read_target", project_path=str(daemon_backed.repo))
    )

    assert "references" in payload, payload
    assert not daemon_backed.store.rejections, daemon_backed.store.rejections


def test_call_graph_answers_over_the_daemon(daemon_backed):
    payload = json.loads(
        server.burnbar_call_graph(symbol_name="daemon_read_target", project_path=str(daemon_backed.repo))
    )

    assert "callers" in payload or "edges" in payload or "nodes" in payload, payload
    assert not daemon_backed.store.rejections, daemon_backed.store.rejections


def test_diagnostics_answers_over_the_daemon(daemon_backed):
    payload = json.loads(server.burnbar_code_diagnostics(project_path=str(daemon_backed.repo)))

    assert "diagnostics" in payload, payload
    assert not daemon_backed.store.rejections, daemon_backed.store.rejections


def test_index_status_reports_the_real_index_over_the_daemon(daemon_backed):
    payload = json.loads(server.burnbar_index_status(project_path=str(daemon_backed.repo)))

    assert payload.get("indexedFiles", 0) >= 1, payload
    assert not daemon_backed.store.rejections, daemon_backed.store.rejections


# --- honesty when the store really has no code-memory schema ----------------


def test_read_only_schema_gap_names_the_missing_tables(tmp_path, monkeypatch):
    """
    Skipping the bootstrap must not turn into pretending. A store without the
    migration should say which tables are absent, not surface `no such table`
    from the middle of a five-way join.
    """
    bare = tmp_path / "bare.sqlite"
    with sqlite3.connect(bare) as conn:
        conn.execute("CREATE TABLE conversations (id TEXT)")
    store = FakeDaemonStore(bare)
    encrypted = tmp_path / "openburnbar.sqlite"
    _write_ciphertext_fixture(encrypted)

    monkeypatch.setattr(server.pcm, "call_daemon", lambda method, params, timeout_seconds=1.5: store.search_sql(params))
    monkeypatch.setattr(server, "_signed_cli_path", lambda: None)
    monkeypatch.setenv("BURNBAR_DB_PATH", str(encrypted))
    try:
        with pytest.raises(pcm.ReadOnlySchemaError) as excinfo:
            server.burnbar_search_code(query="anything", project_path=str(tmp_path))
    finally:
        store.close()

    message = str(excinfo.value)
    assert "code_artifacts" in message
    assert "pcm_projects" in message
    assert not store.rejections, store.rejections


def test_read_only_verification_is_cached_per_connection(daemon_backed):
    """One schema SELECT per connection, not one per `ensure_schema` call."""
    server.burnbar_search_code(query="daemon_read_target", project_path=str(daemon_backed.repo))

    schema_probes = [
        statement
        for statement in daemon_backed.store.statements
        if "sqlite_master" in statement and "type IN ('table'" in statement
    ]
    assert len(schema_probes) == 1, schema_probes


# --- the writer path is untouched -------------------------------------------


def test_plaintext_connection_still_bootstraps_the_schema(tmp_path):
    """A real read-write handle keeps creating and migrating the schema."""
    db_path = tmp_path / "plain.sqlite"
    with sqlite3.connect(db_path) as conn:
        assert pcm.connection_is_read_only(conn) is False
        pcm.ensure_schema(conn)
        assert pcm.REQUIRED_READ_TABLES <= pcm.table_names(conn)


def test_read_only_connection_never_bootstraps(monkeypatch):
    """`ensure_schema` on a read-only handle must not reach the DDL at all."""

    class _Reader:
        burnbar_read_only = True

        def execute(self, sql, params=()):
            assert sql.strip().lower().startswith("select"), sql
            return _Rows([(name,) for name in sorted(pcm.REQUIRED_READ_TABLES)])

    class _Rows:
        def __init__(self, rows):
            self._rows = rows

        def fetchall(self):
            return self._rows

    def explode(_conn):
        raise AssertionError("_bootstrap_schema must not run on a read-only handle")

    monkeypatch.setattr(pcm, "_bootstrap_schema", explode)
    pcm.ensure_schema(_Reader())
