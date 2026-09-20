#!/usr/bin/env python3
"""Resume reads travel through the daemon, not through `sqlite3` on ciphertext.

`burnbar_list_resumable_conversations` and `burnbar_resume_conversation` were the
last two conversation tools still opening the store themselves: `resume_core`
called `sqlite3.connect(f"file:{path}?mode=ro")` on `openburnbar.sqlite`, which is
SQLCipher-encrypted at rest. Against a real install both tools were dead:

    {"kind": "error", "code": "resume_list_failed", "recovery": "file is not a database"}
    {"kind": "error", "code": "resume_failed",      "recovery": "file is not a database"}

Same fix class as #2548 (`fix(mcp): make code-memory reads genuinely read-only`),
which moved the eight code tools onto the daemon's `daemon.search.sql` surface.
Resume was simply not in that sweep.

These tests pin the fix at the statement level, the way #2548's do: it is not
enough that a read *succeeds* against a permissive local connection — every
statement the read issues has to be one the daemon's `sqlite3_stmt_readonly`
gate would accept, and no read may reach `sqlite3.connect` on the store at all.
"""

from __future__ import annotations

import json
import re
import sqlite3
import sys
from pathlib import Path
from typing import Any

import pytest

_HERE = Path(__file__).resolve().parent
_PARENT = _HERE.parent
if str(_PARENT) not in sys.path:
    sys.path.insert(0, str(_PARENT))
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

import resume_core  # noqa: E402
from test_burnbar_resume import _insert_conv, _load_server, _make_claude_handle, _schema  # noqa: E402

server = _load_server()

# What SQLite's `sqlite3_stmt_readonly` rejects, which is what the daemon's read
# surface enforces. PRAGMA is included on purpose: `PRAGMA table_info(...)` was a
# statement resume issued on every list and every briefing.
NON_SELECT = re.compile(
    r"^\s*(PRAGMA|CREATE|ALTER|DROP|INSERT|UPDATE|DELETE|REPLACE|VACUUM|REINDEX|BEGIN|COMMIT)\b",
    re.IGNORECASE,
)

SQLCIPHER_HEADER_NOTE = "a SQLCipher-shaped file: never the plaintext SQLite magic"


def _write_ciphertext_store(path: Path) -> None:
    """A file `sqlite3` must refuse exactly the way it refuses a real encrypted store."""
    payload = b"\x9a\x1f" + bytes(range(0, 254)) * 16
    assert not payload.startswith(b"SQLite format 3\x00"), SQLCIPHER_HEADER_NOTE
    path.write_bytes(payload)


class _DaemonSurface:
    """The daemon's SELECT-only handle, backed by a real plaintext fixture.

    Records every statement it is handed and refuses non-SELECTs the way the
    daemon does, so a read that smuggles a PRAGMA past a permissive connection
    still fails here.
    """

    def __init__(self, backing: Path) -> None:
        self._backing = backing
        self.statements: list[str] = []

    def __call__(self, method: str, params: dict[str, Any], timeout_seconds: float = 1.5) -> dict[str, Any]:
        assert method == "daemon.search.sql", method
        sql = str(params["sql"])
        self.statements.append(" ".join(sql.split()))
        if NON_SELECT.match(sql):
            raise RuntimeError(
                f"daemon rejected daemon.search.sql: code=-32602 message="
                f"'Only SELECT (or WITH … SELECT) statements are allowed.' ({sql.split()[0]})"
            )
        conn = sqlite3.connect(self._backing)
        try:
            cursor = conn.execute(sql, list(params.get("args") or []))
            columns = [str(description[0]) for description in (cursor.description or [])]
            rows = [list(row) for row in cursor.fetchall()]
        finally:
            conn.close()
        return {"columns": columns, "rows": rows, "truncated": False}

    @property
    def non_select_statements(self) -> list[str]:
        return [statement for statement in self.statements if NON_SELECT.match(statement)]


def _encrypted_install(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> _DaemonSurface:
    """An encrypted store at BURNBAR_DB_PATH, served by a daemon over a plaintext twin."""
    backing = tmp_path / "backing.sqlite"
    conn = sqlite3.connect(backing)
    conn.executescript(_schema())
    handle = "8e1d3a26-0b17-4c55-9f0e-3b2c5d7a91ff"
    _insert_conv(conn, provider="Claude Code", session_id=handle)
    _insert_conv(conn, provider="Goose", session_id="goose-fixture-1")
    conn.commit()
    conn.close()

    store = tmp_path / "openburnbar.sqlite"
    _write_ciphertext_store(store)
    monkeypatch.setenv("BURNBAR_DB_PATH", str(store))
    monkeypatch.setenv("OPENBURNBAR_LOCAL_MCP_DISABLE_AUDIT", "true")
    monkeypatch.delenv("OPENBURNBAR_CLI_PATH", raising=False)
    monkeypatch.setattr(server.shutil, "which", lambda _name: None)

    home = tmp_path / "home"
    home.mkdir()
    _make_claude_handle(home, handle)
    monkeypatch.setattr(Path, "home", classmethod(lambda _cls: home))

    surface = _DaemonSurface(backing)
    monkeypatch.setattr(server.pcm, "call_daemon", surface)
    return surface


def _forbid_resume_direct_open(monkeypatch: pytest.MonkeyPatch) -> None:
    """resume_core's own opener must never be reached on a tool read path.

    Patching `sqlite3.connect` itself cannot express this: `server._connect_ro`
    legitimately opens the file to *probe* whether it is ciphertext before
    routing, and `validate_native_handle` legitimately opens Codex's own
    unencrypted `state_5.sqlite`. What must not happen is resume opening the
    OpenBurnBar store for itself, which is exactly `resume_core.connect_ro`.
    """

    def forbidden(path: Path) -> sqlite3.Connection:
        raise AssertionError(f"resume opened the store through resume_core.connect_ro: {path}")

    monkeypatch.setattr(resume_core, "connect_ro", forbidden)


# ---------------------------------------------------------------------------
# The regression, at the statement level
# ---------------------------------------------------------------------------


def test_list_resumable_reads_through_the_daemon_and_issues_only_selects(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    surface = _encrypted_install(tmp_path, monkeypatch)
    _forbid_resume_direct_open(monkeypatch)

    payload = json.loads(server.burnbar_list_resumable_conversations(limit=10))

    assert payload.get("code") is None, payload
    assert len(payload["items"]) == 2, payload
    assert {item["provider"] for item in payload["items"]} == {"Claude Code", "Goose"}
    assert surface.statements, "the list never reached the daemon read surface"
    assert surface.non_select_statements == [], surface.non_select_statements
    assert not any("PRAGMA table_info" in statement for statement in surface.statements), surface.statements
    # The column probe has to be the table-valued SELECT form to pass the gate.
    assert any("pragma_table_info" in statement for statement in surface.statements), surface.statements


def test_resume_conversation_reads_through_the_daemon_and_issues_only_selects(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    surface = _encrypted_install(tmp_path, monkeypatch)
    _forbid_resume_direct_open(monkeypatch)
    monkeypatch.setenv("OPENBURNBAR_LOCAL_MCP_ENABLE_SENSITIVE_READ", "1")

    payload = json.loads(server.burnbar_resume_conversation("goose-fixture-1", target_harness="claude_code"))

    assert payload.get("code") is None, payload
    assert payload["kind"] == "ported", payload
    assert payload["briefing_md"], "the ported briefing came back empty"
    assert surface.statements, "the resume never reached the daemon read surface"
    assert surface.non_select_statements == [], surface.non_select_statements
    assert not any("PRAGMA table_info" in statement for statement in surface.statements), surface.statements
    # The briefing materialises the trail and the token summary; both are reads.
    assert any("FROM search_chunks" in statement for statement in surface.statements), surface.statements
    assert any("FROM token_usage" in statement for statement in surface.statements), surface.statements


def test_native_resume_reads_through_the_daemon(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    surface = _encrypted_install(tmp_path, monkeypatch)
    _forbid_resume_direct_open(monkeypatch)
    monkeypatch.setenv("OPENBURNBAR_LOCAL_MCP_ENABLE_SENSITIVE_READ", "1")

    payload = json.loads(server.burnbar_resume_conversation("8e1d3a26-0b17-4c55-9f0e-3b2c5d7a91ff"))

    assert payload["kind"] == "native", payload
    assert payload["argv"][0] == "claude", payload
    assert surface.non_select_statements == [], surface.non_select_statements


# ---------------------------------------------------------------------------
# An unreachable daemon says what to start
# ---------------------------------------------------------------------------


def _unreachable_daemon(monkeypatch: pytest.MonkeyPatch) -> None:
    def unreachable(method: str, params: dict[str, Any], timeout_seconds: float = 1.5) -> dict[str, Any]:
        raise RuntimeError("daemon socket not reachable at /tmp/nope.sock")

    monkeypatch.setattr(server.pcm, "call_daemon", unreachable)


def test_list_resumable_without_a_daemon_names_what_to_start(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    _encrypted_install(tmp_path, monkeypatch)
    _unreachable_daemon(monkeypatch)

    payload = json.loads(server.burnbar_list_resumable_conversations(limit=10))

    assert payload["code"] == "resume_list_failed", payload
    # Not a false empty result, and not a bare transport error.
    assert "items" not in payload, payload
    assert "Start OpenBurnBar" in payload["recovery"], payload
    assert "daemon socket not reachable" in payload["recovery"], payload


def test_resume_conversation_without_a_daemon_names_what_to_start(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _encrypted_install(tmp_path, monkeypatch)
    _unreachable_daemon(monkeypatch)
    monkeypatch.setenv("OPENBURNBAR_LOCAL_MCP_ENABLE_SENSITIVE_READ", "1")

    payload = json.loads(server.burnbar_resume_conversation("goose-fixture-1", target_harness="claude_code"))

    assert payload["code"] == "resume_failed", payload
    assert "Start OpenBurnBar" in payload["recovery"], payload


def test_a_plaintext_store_still_reports_the_bare_error(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """The daemon hint is for ciphertext only; a plaintext store gets the real error."""
    store = tmp_path / "openburnbar.sqlite"
    sqlite3.connect(store).close()  # plaintext, and with no conversations table
    monkeypatch.setenv("BURNBAR_DB_PATH", str(store))
    monkeypatch.setenv("OPENBURNBAR_LOCAL_MCP_DISABLE_AUDIT", "true")

    payload = json.loads(server.burnbar_list_resumable_conversations(limit=10))

    assert payload["code"] == "resume_list_failed", payload
    assert "Start OpenBurnBar" not in payload["recovery"], payload


# ---------------------------------------------------------------------------
# No direct open survives anywhere on the resume read path
# ---------------------------------------------------------------------------


def test_resume_core_refuses_to_open_an_encrypted_store_directly(tmp_path: Path) -> None:
    """`connect_ro` says what to start instead of surfacing sqlite's 'file is not a database'."""
    store = tmp_path / "openburnbar.sqlite"
    _write_ciphertext_store(store)

    with pytest.raises(sqlite3.DatabaseError) as caught:
        resume_core.connect_ro(store)

    message = str(caught.value)
    assert "file is not a database" not in message, message
    assert "Start OpenBurnBar" in message, message
    assert "SQLCipher-encrypted" in message, message


def test_resume_core_still_opens_a_plaintext_store_directly(tmp_path: Path) -> None:
    store = tmp_path / "openburnbar.sqlite"
    conn = sqlite3.connect(store)
    conn.executescript(_schema())
    conn.commit()
    conn.close()

    opened = resume_core.connect_ro(store)
    try:
        assert isinstance(opened, sqlite3.Connection)
    finally:
        opened.close()


def test_the_server_injects_the_daemon_capable_opener() -> None:
    """The tools' environment carries `server._connect_ro`, not resume_core's direct open."""
    env = server._resume_environment()
    assert env.connect is server._connect_ro
    assert env.connect is not resume_core.connect_ro


def test_resume_environment_defaults_to_the_direct_opener() -> None:
    """Unset — the standalone CLI and the plaintext fixtures — still opens directly."""
    assert resume_core.ResumeEnvironment().connect is None
