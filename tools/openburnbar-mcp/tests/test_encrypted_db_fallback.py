#!/usr/bin/env python3
"""
Encrypted-store fallback coverage for `_connect_ro`.

The regression this pins: the app keys openburnbar.sqlite with SQLCipher, stdlib
sqlite3 has no codec, and every prior fixture here was plaintext — so CI never
saw the "file is not a database" failure that broke all corpus/memory tools on
every real install. These tests keep a ciphertext fixture in the loop and assert
the daemon-socket fallback engages, keeps sqlite3.Row semantics, and reports
honestly through burnbar_resolve_db_path.
"""

from __future__ import annotations

import importlib.util
import json
import os
import sqlite3
import sys
import types
from pathlib import Path


_HERE = Path(__file__).resolve().parent
_PARENT = _HERE.parent
if str(_PARENT) not in sys.path:
    sys.path.insert(0, str(_PARENT))


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

    spec = importlib.util.spec_from_file_location("openburnbar_mcp_server_under_test", str(_PARENT / "server.py"))
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules["openburnbar_mcp_server_under_test"] = module
    spec.loader.exec_module(module)  # type: ignore[union-attr]
    return module


server = _load_server()


def _write_ciphertext_fixture(path: Path) -> None:
    """A SQLCipher-shaped file: 16-byte salt header (never the plaintext SQLite
    magic) followed by page-sized noise. sqlite3 must refuse it exactly the way
    it refuses a real encrypted store."""
    payload = os.urandom(16) + os.urandom(4096 - 16)
    assert not payload.startswith(b"SQLite format 3\x00")
    path.write_bytes(payload)


def _daemon_stub(monkeypatch, responses=None, calls=None):
    def fake_call_daemon(method, params, timeout_seconds=1.5):
        if calls is not None:
            calls.append((method, params))
        assert method == "daemon.search.sql"
        if responses is None:
            return {"columns": [], "rows": [], "truncated": False}
        return responses(params)

    monkeypatch.setattr(server.pcm, "call_daemon", fake_call_daemon)


def test_connect_ro_plaintext_returns_real_sqlite(tmp_path):
    db_path = tmp_path / "openburnbar.sqlite"
    conn = sqlite3.connect(db_path)
    conn.execute("CREATE TABLE conversations (id TEXT, provider TEXT)")
    conn.commit()
    conn.close()

    opened = server._connect_ro(db_path)
    try:
        assert isinstance(opened, sqlite3.Connection)
    finally:
        opened.close()


def test_connect_ro_ciphertext_falls_back_to_daemon(tmp_path, monkeypatch):
    db_path = tmp_path / "openburnbar.sqlite"
    _write_ciphertext_fixture(db_path)
    _daemon_stub(monkeypatch)

    opened = server._connect_ro(db_path)
    assert isinstance(opened, server._DaemonReadConnection)


def test_daemon_shim_preserves_row_semantics(tmp_path, monkeypatch):
    db_path = tmp_path / "openburnbar.sqlite"
    _write_ciphertext_fixture(db_path)
    calls: list = []

    def respond(params):
        return {
            "columns": ["provider", "sessions", "payload"],
            "rows": [["Codex", 7, {"$blob": "aGk="}]],
            "truncated": True,
        }

    _daemon_stub(monkeypatch, responses=respond, calls=calls)

    conn = server._connect_ro(db_path)
    conn.row_factory = sqlite3.Row  # accepted and ignored, like the real tools do
    with conn:
        cursor = conn.execute("SELECT provider, COUNT(*) FROM conversations WHERE provider = ?", ("Codex",))
        rows = cursor.fetchall()

    assert calls and calls[0][1]["args"] == ["Codex"]
    assert len(rows) == 1
    row = rows[0]
    # index access, name access, dict() — the three shapes the 24 read tools use
    assert row[0] == "Codex"
    assert row["sessions"] == 7
    assert dict(row) == {"provider": "Codex", "sessions": 7, "payload": b"hi"}
    assert cursor.truncated is True
    assert cursor.description[0][0] == "provider"


def test_connect_ro_ciphertext_without_daemon_raises_actionable_error(tmp_path, monkeypatch):
    db_path = tmp_path / "openburnbar.sqlite"
    _write_ciphertext_fixture(db_path)

    def unreachable(method, params, timeout_seconds=1.5):
        raise RuntimeError("daemon socket not reachable at /tmp/nope.sock")

    # The shim itself is constructed lazily-cheap; reachability failures surface
    # on first execute. resolve_db_path (below) probes and reports it. Here we
    # assert the execute-time error is the daemon's, not a bare sqlite one.
    monkeypatch.setattr(server.pcm, "call_daemon", unreachable)
    conn = server._connect_ro(db_path)
    try:
        conn.execute("SELECT 1")
        raise AssertionError("expected the daemon transport error to surface")
    except RuntimeError as exc:
        assert "daemon socket not reachable" in str(exc)


def test_resolve_db_path_reports_encryption_and_route(tmp_path, monkeypatch):
    db_path = tmp_path / "openburnbar.sqlite"
    _write_ciphertext_fixture(db_path)
    monkeypatch.setenv("BURNBAR_DB_PATH", str(db_path))
    _daemon_stub(monkeypatch)

    payload = json.loads(server.burnbar_resolve_db_path())

    assert payload["exists"] is True
    assert payload["encrypted"] is True
    assert payload["readable"] is True
    assert payload["readPath"] == "daemon-socket"


def test_resolve_db_path_plaintext_reports_direct(tmp_path, monkeypatch):
    db_path = tmp_path / "openburnbar.sqlite"
    sqlite3.connect(db_path).close()
    # An empty file has no header yet; give it a real table so the magic exists.
    conn = sqlite3.connect(db_path)
    conn.execute("CREATE TABLE t (x)")
    conn.commit()
    conn.close()
    monkeypatch.setenv("BURNBAR_DB_PATH", str(db_path))

    payload = json.loads(server.burnbar_resolve_db_path())

    assert payload["encrypted"] is False
    assert payload["readable"] is True
    assert payload["readPath"] == "direct-sqlite"


def test_table_columns_probe_is_daemon_compatible_select(tmp_path, monkeypatch):
    db_path = tmp_path / "openburnbar.sqlite"
    _write_ciphertext_fixture(db_path)
    calls: list = []

    def respond(params):
        return {"columns": ["name"], "rows": [["id"], ["provider"]], "truncated": False}

    _daemon_stub(monkeypatch, responses=respond, calls=calls)
    conn = server._connect_ro(db_path)

    columns = server._table_columns(conn, "conversations")

    assert columns == {"id", "provider"}
    sent_sql = calls[0][1]["sql"].lstrip().lower()
    assert sent_sql.startswith("select"), "schema probes must pass the daemon's SELECT-only gate"


# ---------------------------------------------------------------------------
# Toolset narrowing
# ---------------------------------------------------------------------------


class _FakeToolManager:
    def __init__(self, names):
        self._tools = {name: object() for name in names}


class _FakeServer:
    def __init__(self, names):
        self._tool_manager = _FakeToolManager(names)


def test_toolset_filter_memory_keeps_only_the_memory_surface():
    names = ["burnbar_recall", "burnbar_query_spend", "burnbar_search_conversations", "burnbar_inbox_list"]
    fake = _FakeServer(names)
    effective = server._apply_toolset_filter(fake, "memory")
    assert effective == "memory"
    assert set(fake._tool_manager._tools) == {"burnbar_recall", "burnbar_search_conversations"}


def test_toolset_filter_ops_is_the_complement():
    names = ["burnbar_recall", "burnbar_query_spend", "burnbar_inbox_list"]
    fake = _FakeServer(names)
    effective = server._apply_toolset_filter(fake, "ops")
    assert effective == "ops"
    assert set(fake._tool_manager._tools) == {"burnbar_query_spend", "burnbar_inbox_list"}


def test_toolset_filter_fails_open_to_all():
    fake = _FakeServer(["burnbar_recall"])
    assert server._apply_toolset_filter(fake, "") == "all"
    assert server._apply_toolset_filter(fake, None) == "all"
    assert server._apply_toolset_filter(fake, "bogus") == "all"
    assert set(fake._tool_manager._tools) == {"burnbar_recall"}

    class _NoRegistry:
        pass

    assert server._apply_toolset_filter(_NoRegistry(), "memory") == "all"


def test_memory_toolset_names_exist_as_real_tools():
    # Guard against drift: every name in the memory toolset must be a real
    # function on the server module (a rename would silently empty the set).
    for name in server.MEMORY_TOOLSET:
        assert callable(getattr(server, name, None)), f"MEMORY_TOOLSET names a missing tool: {name}"


def test_recent_usage_surfaces_daemon_truncation(tmp_path, monkeypatch):
    db_path = tmp_path / "openburnbar.sqlite"
    _write_ciphertext_fixture(db_path)
    monkeypatch.setenv("BURNBAR_DB_PATH", str(db_path))

    def respond(params):
        return {
            "columns": ["provider", "cost"],
            "rows": [["Codex", 1.25]],
            "truncated": True,
        }

    _daemon_stub(monkeypatch, responses=respond)

    payload = json.loads(server.burnbar_recent_usage())

    assert payload["usage"] == [{"provider": "Codex", "cost": 1.25}]
    assert payload["truncated"] is True
    assert "capped" in payload["truncationNote"]
