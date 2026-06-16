#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import json
import os
import sqlite3
import sys
import types
from pathlib import Path

import pytest


_HERE = Path(__file__).resolve().parent
_PARENT = _HERE.parent
if str(_PARENT) not in sys.path:
    sys.path.insert(0, str(_PARENT))

import project_code_memory as pcm  # noqa: E402


def _static_parser_helper() -> Path | None:
    candidates = [
        _PARENT.parent.parent / "crates/project-code-static-parser/target/debug/project-code-static-parser",
        _PARENT.parent.parent / "crates/project-code-static-parser/target/release/project-code-static-parser",
        Path.cwd() / "crates/project-code-static-parser/target/debug/project-code-static-parser",
        Path.cwd() / "crates/project-code-static-parser/target/release/project-code-static-parser",
    ]
    return next((path for path in candidates if path.exists() and os.access(path, os.X_OK)), None)


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
        "openburnbar_mcp_server_project_memory_test", str(_PARENT / "server.py")
    )
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules["openburnbar_mcp_server_project_memory_test"] = module
    spec.loader.exec_module(module)  # type: ignore[union-attr]
    return module


def _make_repo(path: Path, body: str) -> Path:
    path.mkdir()
    (path / ".gitignore").write_text("ignored/\n", encoding="utf-8")
    (path / "main.py").write_text(body, encoding="utf-8")
    ignored = path / "ignored"
    ignored.mkdir()
    (ignored / "skip.py").write_text("def should_not_index(): pass\n", encoding="utf-8")
    return path


def test_project_code_index_search_symbols_references_and_bleed(tmp_path: Path, monkeypatch) -> None:
    # When the static parser helper is built, point production at it so symbol
    # resolution is exercised at the earned tree-sitter tier rather than silently lexical.
    helper = _static_parser_helper()
    if helper is not None:
        monkeypatch.setenv("OPENBURNBAR_CODE_STATIC_PARSER_PATH", str(helper))
    repo_a = _make_repo(
        tmp_path / "repo-a",
        """
def alpha_feature():
    return beta_helper()

def beta_helper():
    return "repo-a-only"

alpha_feature()
""",
    )
    repo_b = _make_repo(
        tmp_path / "repo-b",
        """
def foreign_feature():
    return "repo-b-only"
""",
    )
    db_path = tmp_path / "openburnbar.sqlite"
    with sqlite3.connect(db_path) as conn:
        conn.row_factory = sqlite3.Row
        indexed_a = pcm.index_project(conn, str(repo_a), max_files=25)
        indexed_b = pcm.index_project(conn, str(repo_b), max_files=25)

        assert indexed_a["indexedFiles"] == 1
        assert indexed_b["indexedFiles"] == 1
        assert indexed_a["storageByteCount"] > 0
        assert indexed_a["storageBudgetBytes"] == pcm.DEFAULT_PROJECT_STORAGE_BUDGET_BYTES

        search_a = pcm.search_code(conn, "repo-a-only", str(repo_a), limit=10)
        assert search_a["status"] == "ok"
        assert any(hit["filePath"] == "main.py" for hit in search_a["results"])

        bleed = pcm.search_code(conn, "repo-b-only", str(repo_a), limit=10)
        assert bleed["status"] == "ok"
        assert all("repo-b-only" not in json.dumps(hit) for hit in bleed["results"])

        symbol = pcm.get_symbol(conn, "alpha_feature", str(repo_a), limit=10)
        assert symbol["symbols"][0]["filePath"] == "main.py"
        if helper is not None:
            # The helper is built, so the tier MUST be earned at tree-sitter. A
            # tautological `in {lexical_fallback, static_tree_sitter}` would let a
            # silent parser break degrade to lexical and still pass green. shaMatch is
            # now computed (git blob SHA-1), so asserting True proves the parsed text
            # actually corresponds to the indexed blob.
            assert symbol["symbols"][0]["confidenceTier"] == "static_tree_sitter"
            assert symbol["symbols"][0]["tierEvidence"]["parser"] == "tree-sitter"
            assert symbol["symbols"][0]["tierEvidence"]["shaMatch"] is True
        else:
            assert symbol["symbols"][0]["confidenceTier"] == "lexical_fallback"

        refs = pcm.find_references(conn, "beta_helper", str(repo_a), limit=20)
        assert any(ref["filePath"] == "main.py" for ref in refs["references"])

        graph = pcm.call_graph(conn, "beta_helper", str(repo_a), depth=1, limit=20)
        assert any(edge["caller"] == "alpha_feature" and edge["callee"] == "beta_helper" for edge in graph["edges"])
        assert all(edge["hop"] == 1 for edge in graph["edges"])

        pack = pcm.context_pack(conn, "beta_helper", str(repo_a), token_budget=2000, limit=5)
        assert '<file path="main.py"' in pack["contextPack"]


def test_call_graph_depth_traverses_multi_hop_chain(tmp_path: Path) -> None:
    repo = _make_repo(
        tmp_path / "repo-chain",
        """
def alpha_chain():
    return beta_chain()

def beta_chain():
    return gamma_chain()

def gamma_chain():
    return 42
""",
    )
    db_path = tmp_path / "openburnbar.sqlite"
    with sqlite3.connect(db_path) as conn:
        conn.row_factory = sqlite3.Row
        pcm.index_project(conn, str(repo), max_files=25)

        shallow = pcm.call_graph(conn, "alpha_chain", str(repo), depth=1, limit=50)
        deep = pcm.call_graph(conn, "alpha_chain", str(repo), depth=3, limit=50)

        # depth=1 returns only the direct edge alpha_chain -> beta_chain.
        shallow_pairs = {(e["caller"], e["callee"]) for e in shallow["edges"]}
        assert shallow_pairs == {("alpha_chain", "beta_chain")}

        # depth=3 follows the chain alpha_chain -> beta_chain -> gamma_chain.
        deep_pairs = {(e["caller"], e["callee"]) for e in deep["edges"]}
        assert ("alpha_chain", "beta_chain") in deep_pairs
        assert ("beta_chain", "gamma_chain") in deep_pairs
        assert len(deep["edges"]) > len(shallow["edges"])
        assert deep["depth"] == 3
        assert shallow["depth"] == 1
        assert any(e["hop"] == 2 for e in deep["edges"])


def test_exact_lsp_tier_and_references_when_configured(tmp_path: Path, monkeypatch) -> None:
    helper = _static_parser_helper()
    if helper is None:
        pytest.skip("project-code-static-parser helper has not been built")
    fake_lsp = tmp_path / "fake_lsp.py"
    fake_lsp.write_text(
        r"""
import json
import sys

def read_message():
    headers = {}
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            return None
        if line in (b"\r\n", b"\n"):
            break
        key, value = line.decode("ascii").split(":", 1)
        headers[key.lower()] = value.strip()
    body = sys.stdin.buffer.read(int(headers["content-length"]))
    return json.loads(body)

def write_message(payload):
    body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    sys.stdout.buffer.write(f"Content-Length: {len(body)}\r\n\r\n".encode("ascii") + body)
    sys.stdout.buffer.flush()

while True:
    msg = read_message()
    if msg is None:
        break
    method = msg.get("method")
    if "id" in msg and method == "initialize":
        write_message({"jsonrpc": "2.0", "id": msg["id"], "result": {"capabilities": {"documentSymbolProvider": True, "referencesProvider": True}}})
    elif "id" in msg and method == "textDocument/documentSymbol":
        write_message({"jsonrpc": "2.0", "id": msg["id"], "result": [
            {"name": "exact_target", "kind": 12, "range": {"start": {"line": 0, "character": 4}, "end": {"line": 0, "character": 16}}, "selectionRange": {"start": {"line": 0, "character": 4}, "end": {"line": 0, "character": 16}}}
        ]})
    elif "id" in msg and method == "textDocument/references":
        uri = msg["params"]["textDocument"]["uri"]
        write_message({"jsonrpc": "2.0", "id": msg["id"], "result": [
            {"uri": uri, "range": {"start": {"line": 0, "character": 4}, "end": {"line": 0, "character": 16}}},
            {"uri": uri, "range": {"start": {"line": 2, "character": 11}, "end": {"line": 2, "character": 23}}}
        ]})
    elif "id" in msg and method == "shutdown":
        write_message({"jsonrpc": "2.0", "id": msg["id"], "result": None})
    elif method == "exit":
        break
""",
        encoding="utf-8",
    )
    repo = _make_repo(
        tmp_path / "repo-lsp",
        """
def exact_target():
    return 1

value = exact_target()
""",
    )
    monkeypatch.setenv("OPENBURNBAR_CODE_STATIC_PARSER_PATH", str(helper))
    monkeypatch.setenv("OPENBURNBAR_CODE_LSP_COMMANDS", json.dumps({"python": [sys.executable, str(fake_lsp)]}))
    monkeypatch.setenv("OPENBURNBAR_CODE_LSP_TIMEOUT_MS", "1500")

    db_path = tmp_path / "openburnbar.sqlite"
    with sqlite3.connect(db_path) as conn:
        conn.row_factory = sqlite3.Row
        pcm.index_project(conn, str(repo), max_files=25)
        symbol = pcm.get_symbol(conn, "exact_target", str(repo), limit=10)["symbols"][0]
        assert symbol["confidenceTier"] == "exact_lsp"
        assert symbol["tierEvidence"]["parser"] == "lsp"
        assert symbol["tierEvidence"]["lspResponded"] is True

        refs = pcm.find_references(conn, "exact_target", str(repo), limit=10)["references"]
        assert len(refs) == 2
        assert {ref["confidenceTier"] for ref in refs} == {"exact_lsp"}
        assert all(ref["tierEvidence"]["lspResponded"] is True for ref in refs)


def test_code_index_enforces_storage_budget_and_reports_status(tmp_path: Path) -> None:
    repo = _make_repo(
        tmp_path / "repo-budget",
        """
def kept_symbol():
    return "kept"
""",
    )
    (repo / "large.py").write_text("def large_symbol():\n    return 'large'\n" * 40, encoding="utf-8")
    db_path = tmp_path / "openburnbar.sqlite"
    with sqlite3.connect(db_path) as conn:
        conn.row_factory = sqlite3.Row
        result = pcm.index_project(conn, str(repo), max_files=25, max_file_bytes=10_000, storage_budget_bytes=128)

        assert result["indexedFiles"] == 1
        assert result["rejectedFiles"][0]["labels"] == ["Storage budget cap reached"]

        status = pcm.index_status(conn, str(repo))
        assert status["storageByteCount"] <= status["storageBudgetBytes"]
        assert status["storageBudgetBytes"] == 128
        assert status["storageWithinBudget"] is True
        assert status["lastVacuumedAt"] is not None


def test_code_index_rejects_secret_bearing_files_with_label_only_audit(tmp_path: Path) -> None:
    repo = _make_repo(
        tmp_path / "repo-secret",
        """
def clean_symbol():
    return 1
""",
    )
    fake_github_token = "ghp_" + ("1" * 36)
    (repo / "secret.py").write_text(f'TOKEN = "{fake_github_token}"\n', encoding="utf-8")
    db_path = tmp_path / "openburnbar.sqlite"
    with sqlite3.connect(db_path) as conn:
        conn.row_factory = sqlite3.Row
        result = pcm.index_project(conn, str(repo), max_files=25)
        assert result["indexedFiles"] == 1
        assert result["rejectedFiles"][0]["filePath"] == "secret.py"
        assert "GitHub token" in result["rejectedFiles"][0]["labels"]

        audit = pcm.audit_trail(conn, str(repo), limit=10)
        event = next(item for item in audit["events"] if item["action"] == "code.secret_rejected")
        assert "GitHub token" in event["labels"]
        assert "ghp_" not in json.dumps(event)


def test_code_reads_suppress_stale_artifacts_until_reindexed(tmp_path: Path) -> None:
    repo = _make_repo(
        tmp_path / "repo-stale",
        """
def stale_helper():
    return "stale-token"
""",
    )
    db_path = tmp_path / "openburnbar.sqlite"
    with sqlite3.connect(db_path) as conn:
        conn.row_factory = sqlite3.Row
        pcm.index_project(conn, str(repo), max_files=25)

        assert pcm.search_code(conn, "stale-token", str(repo), limit=10)["results"]
        assert pcm.get_symbol(conn, "stale_helper", str(repo), limit=10)["symbols"]

        (repo / "main.py").write_text(
            """
def fresh_helper():
    return "fresh-token"
""",
            encoding="utf-8",
        )

        assert pcm.search_code(conn, "stale-token", str(repo), limit=10)["results"] == []
        assert pcm.get_symbol(conn, "stale_helper", str(repo), limit=10)["symbols"] == []

        pcm.index_project(conn, str(repo), max_files=25)
        assert pcm.search_code(conn, "fresh-token", str(repo), limit=10)["results"]
        assert pcm.get_symbol(conn, "fresh_helper", str(repo), limit=10)["symbols"]


def test_remember_fails_closed_without_direct_write_override(tmp_path: Path, monkeypatch) -> None:
    db_path = tmp_path / "openburnbar.sqlite"
    sqlite3.connect(db_path).close()
    repo = _make_repo(tmp_path / "repo-memory", "def durable_fact(): return 1\n")
    monkeypatch.setenv("BURNBAR_DB_PATH", str(db_path))
    monkeypatch.setenv("OPENBURNBAR_LOCAL_MCP_ENABLE_LOCAL_WRITE", "true")
    monkeypatch.setenv("OPENBURNBAR_DAEMON_SOCKET_PATH", str(tmp_path / "missing.sock"))

    server = _load_server()
    payload = json.loads(server.burnbar_remember("Remember the durable test fact.", project_path=str(repo)))

    assert payload["code"] == "DAEMON_WRITE_REQUIRED"
    with sqlite3.connect(db_path) as conn:
        tables = pcm.table_names(conn)
    assert "agent_memories" not in tables


def test_server_write_tools_use_daemon_rpc_method_names(tmp_path: Path, monkeypatch) -> None:
    db_path = tmp_path / "openburnbar.sqlite"
    sqlite3.connect(db_path).close()
    repo = _make_repo(tmp_path / "repo-methods", "def method_names(): return 1\n")
    monkeypatch.setenv("BURNBAR_DB_PATH", str(db_path))
    monkeypatch.setenv("OPENBURNBAR_LOCAL_MCP_ENABLE_LOCAL_WRITE", "true")

    server = _load_server()
    calls: list[tuple[str, dict]] = []

    def fake_write_authority(method: str, params: dict) -> dict:
        calls.append((method, params))
        return {"mode": "daemon", "result": {"status": "ok", "method": method}}

    monkeypatch.setattr(server.pcm, "write_authority", fake_write_authority)

    json.loads(server.burnbar_remember("Remember method names.", project_path=str(repo)))
    json.loads(server.burnbar_forget("mem_fixture", project_path=str(repo)))
    json.loads(server.burnbar_index_project(project_path=str(repo), storage_budget_bytes=4096))
    json.loads(
        server.burnbar_watch_project(project_path=str(repo), storage_budget_bytes=4096, poll_interval_seconds=0.5)
    )
    json.loads(server.burnbar_explore("method", project_path=str(repo)))

    assert [method for method, _ in calls] == [
        "daemon.memory.remember",
        "daemon.memory.forget",
        "daemon.code.index_project",
        "daemon.code.watch_project",
        "daemon.code.explore",
    ]
    assert calls[2][1]["storageBudgetBytes"] == 4096
    assert calls[3][1]["pollIntervalSeconds"] == 0.5
    assert calls[4][1]["maxBytes"] == 6000


def test_write_tools_do_not_fall_back_to_direct_sqlite_even_with_legacy_override_env(
    tmp_path: Path, monkeypatch
) -> None:
    db_path = tmp_path / "openburnbar.sqlite"
    sqlite3.connect(db_path).close()
    repo = _make_repo(tmp_path / "repo-no-direct", "def durable_fact(): return 1\n")
    monkeypatch.setenv("BURNBAR_DB_PATH", str(db_path))
    monkeypatch.setenv("OPENBURNBAR_LOCAL_MCP_ENABLE_LOCAL_WRITE", "true")
    monkeypatch.setenv("OPENBURNBAR_DAEMON_SOCKET_PATH", str(tmp_path / "missing.sock"))
    monkeypatch.setenv("OPENBURNBAR_LOCAL_MCP_ALLOW_DIRECT_MEMORY_WRITE", "true")

    server = _load_server()
    remembered = json.loads(server.burnbar_remember("Remember must not bypass daemon.", project_path=str(repo)))
    indexed = json.loads(server.burnbar_index_project(project_path=str(repo)))
    explored = json.loads(server.burnbar_explore("durable_fact", project_path=str(repo)))

    assert remembered["code"] == "DAEMON_WRITE_REQUIRED"
    assert indexed["code"] == "DAEMON_WRITE_REQUIRED"
    assert explored["code"] == "DAEMON_WRITE_REQUIRED"

    with sqlite3.connect(db_path) as conn:
        assert "agent_memories" not in pcm.table_names(conn)


def test_direct_memory_helpers_keep_plaintext_out_of_agent_index(tmp_path: Path) -> None:
    db_path = tmp_path / "openburnbar.sqlite"
    repo = _make_repo(tmp_path / "repo-memory-direct", "def durable_fact(): return 1\n")
    raw_body = "Remember the direct helper memory for this project."

    with sqlite3.connect(db_path) as conn:
        conn.row_factory = sqlite3.Row
        remembered = pcm.remember(
            conn,
            raw_body,
            project_path=str(repo),
            kind="fact",
            scope="personal",
            tags=["operator", "memory"],
            confidence=1.0,
            source_path=None,
        )
        recalled = pcm.recall(conn, "helper memory", project_path=str(repo), limit=20)
        assert recalled["results"][0]["memoryID"] == remembered["memoryID"]

        agent_rows = conn.execute("SELECT body_redacted FROM agent_memories").fetchall()
        snapshots = conn.execute("SELECT snapshotJSON FROM project_memory_snapshots").fetchall()
        # The vestigial body-search index is dropped, not left dead.
        assert "agent_memories_fts" not in pcm.table_names(conn)

    # Redacted-index invariant: the plaintext body lives ONLY in the snapshot, never
    # in the agent index.
    assert raw_body not in "\n".join(row[0] for row in agent_rows)
    assert raw_body in snapshots[0][0]

    with sqlite3.connect(db_path) as conn:
        conn.row_factory = sqlite3.Row
        forgotten = pcm.forget(conn, remembered["memoryID"], project_path=str(repo))
    assert forgotten["status"] == "ok"

    with sqlite3.connect(db_path) as conn:
        conn.row_factory = sqlite3.Row
        recalled_again = pcm.recall(conn, "helper memory", project_path=str(repo), limit=20)
        snapshots_after = conn.execute("SELECT snapshotJSON FROM project_memory_snapshots").fetchall()
    assert recalled_again["results"] == []
    # forget must purge the canonical plaintext body from the snapshot, not merely drop
    # the index row (which would leave recall empty while the body survived on disk).
    assert all(raw_body not in row[0] for row in snapshots_after)


def test_get_symbol_tier_is_lexical_fallback_when_no_helper_or_lsp(tmp_path: Path, monkeypatch) -> None:
    # Negative tier proof: with neither the static parser helper nor an LSP available,
    # the tier MUST be exactly lexical_fallback. A tier is only assigned when earned —
    # nothing may falsely elevate to static_tree_sitter / exact_lsp on the lexical path.
    monkeypatch.setattr(pcm, "static_parser_path", lambda: None)
    monkeypatch.delenv("OPENBURNBAR_CODE_LSP_COMMANDS", raising=False)
    repo = _make_repo(tmp_path / "repo-lexical", "def lonely_symbol():\n    return 1\n")
    db_path = tmp_path / "openburnbar.sqlite"
    with sqlite3.connect(db_path) as conn:
        conn.row_factory = sqlite3.Row
        pcm.index_project(conn, str(repo), max_files=25)
        symbol = pcm.get_symbol(conn, "lonely_symbol", str(repo), limit=10)["symbols"][0]
        assert symbol["confidenceTier"] == "lexical_fallback"
        assert symbol["tierEvidence"]["parser"] == "regex"
        assert symbol["tierEvidence"]["shaMatch"] is False
        assert symbol["tierEvidence"]["lspResponded"] is False


def test_remember_rejects_secret_bearing_memory_with_label_only_audit(tmp_path: Path) -> None:
    # The memory-write secret gate (pcm.remember) must reject a secret-bearing body
    # before any persistence, with label-only audit evidence (no raw secret material).
    repo = _make_repo(tmp_path / "repo-secret-mem", "def durable_fact(): return 1\n")
    db_path = tmp_path / "openburnbar.sqlite"
    fake_token = "ghp_" + ("9" * 36)
    with sqlite3.connect(db_path) as conn:
        conn.row_factory = sqlite3.Row
        result = pcm.remember(
            conn,
            f"Use the deploy token {fake_token} for releases.",
            project_path=str(repo),
            kind="fact",
            scope="personal",
            tags=["secret"],
            confidence=1.0,
            source_path=None,
        )
        assert result["status"] == "rejected"
        assert result["code"] == "SECRET_DETECTED"
        assert any("GitHub" in label for label in result["labels"])
        # Nothing was persisted by the rejected write.
        assert conn.execute("SELECT COUNT(*) FROM agent_memories").fetchone()[0] == 0
        # The rejection is audited with label-only evidence — never the raw secret.
        audit = pcm.audit_trail(conn, str(repo), limit=10)
        event = next(item for item in audit["events"] if item["action"] == "memory.secret_rejected")
        assert any("GitHub" in label for label in event["labels"])
        assert "ghp_" not in json.dumps(event)


def test_index_project_evicts_oldest_files_first_under_budget(tmp_path: Path) -> None:
    # Age-aware eviction: when a project exceeds its storage budget, the NEWEST
    # (most relevant) files are kept and the OLDEST are evicted — deterministic,
    # not whatever order the filesystem walk yields.
    repo = tmp_path / "repo-evict"
    repo.mkdir()
    (repo / ".gitignore").write_text("ignored/\n", encoding="utf-8")
    older = repo / "older.py"
    newer = repo / "newer.py"
    older.write_text("def older_symbol():\n    return 1\n", encoding="utf-8")
    newer.write_text("def newer_symbol():\n    return 1\n", encoding="utf-8")
    os.utime(older, (1_000, 1_000))
    os.utime(newer, (2_000, 2_000))
    db_path = tmp_path / "openburnbar.sqlite"
    with sqlite3.connect(db_path) as conn:
        conn.row_factory = sqlite3.Row
        # Budget fits exactly one ~33-byte file, forcing one eviction.
        result = pcm.index_project(conn, str(repo), max_files=25, storage_budget_bytes=40)
        assert result["indexedFiles"] == 1
        assert [r["filePath"] for r in result["rejectedFiles"]] == ["older.py"]
        assert result["rejectedFiles"][0]["labels"] == ["Storage budget cap reached"]
