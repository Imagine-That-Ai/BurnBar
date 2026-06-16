#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import json
import sqlite3
import sys
import types
from pathlib import Path


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


def test_project_code_index_search_symbols_references_and_bleed(tmp_path: Path) -> None:
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
        assert symbol["symbols"][0]["confidenceTier"] in {"lexical_fallback", "static_tree_sitter"}
        assert symbol["symbols"][0]["filePath"] == "main.py"
        if symbol["symbols"][0]["confidenceTier"] == "static_tree_sitter":
            assert symbol["symbols"][0]["tierEvidence"]["parser"] == "tree-sitter"
            assert symbol["symbols"][0]["tierEvidence"]["shaMatch"] is True

        refs = pcm.find_references(conn, "beta_helper", str(repo_a), limit=20)
        assert any(ref["filePath"] == "main.py" for ref in refs["references"])

        graph = pcm.call_graph(conn, "beta_helper", str(repo_a), depth=1, limit=20)
        assert any(edge["caller"] == "alpha_feature" and edge["callee"] == "beta_helper" for edge in graph["edges"])

        pack = pcm.context_pack(conn, "beta_helper", str(repo_a), token_budget=2000, limit=5)
        assert '<file path="main.py"' in pack["contextPack"]


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
    fake_pat = "ghp_" + "123456789012345678901234567890123456"
    (repo / "secret.py").write_text(f'TOKEN = "{fake_pat}"\n', encoding="utf-8")
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
        fts_rows = conn.execute("SELECT bodyText FROM agent_memories_fts").fetchall()
        snapshots = conn.execute("SELECT snapshotJSON FROM project_memory_snapshots").fetchall()

    assert raw_body not in "\n".join(row[0] for row in agent_rows)
    assert raw_body not in "\n".join(row[0] for row in fts_rows)
    assert raw_body in snapshots[0][0]

    with sqlite3.connect(db_path) as conn:
        conn.row_factory = sqlite3.Row
        forgotten = pcm.forget(conn, remembered["memoryID"], project_path=str(repo))
    assert forgotten["status"] == "ok"

    with sqlite3.connect(db_path) as conn:
        conn.row_factory = sqlite3.Row
        recalled_again = pcm.recall(conn, "helper memory", project_path=str(repo), limit=20)
    assert recalled_again["results"] == []
