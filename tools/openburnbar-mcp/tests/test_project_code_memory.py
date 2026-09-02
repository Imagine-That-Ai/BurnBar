#!/usr/bin/env python3
from __future__ import annotations

import base64
import importlib.util
import json
import os
import subprocess
import sqlite3
import sys
import time
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


def _run_git(repo: Path, *args: str) -> None:
    subprocess.run(["git", *args], cwd=repo, check=True, capture_output=True)


def _expected_audit_hash(event: dict[str, object]) -> str:
    core = {
        "schema": "openburnbar.memory_audit.v2",
        "seq": event["seq"],
        "ts": event["ts"],
        "actor": event["actor"],
        "action": event["action"],
        "domain": event["domain"],
        "projectID": event["projectID"],
        "subjectID": event["subjectID"],
        "labels": event["labels"],
        "prevHash": event["prevHash"] or "",
    }
    return pcm.sha256_hex(json.dumps(core, sort_keys=True, separators=(",", ":")))


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
        assert search_a["semanticAvailable"] is False
        assert search_a["trustSignal"]["untrustedContentWrapped"] is True
        assert any(hit["filePath"] == "main.py" for hit in search_a["results"])
        assert all("OPENBURNBAR_UNTRUSTED_CODE" in hit["snippet"] for hit in search_a["results"])
        first_hit = search_a["results"][0]
        assert first_hit["rankFeatures"]["lexicalRank"] >= 1
        assert first_hit["rankFeatures"]["score"] == first_hit["score"]

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
        assert 'contentKind="complete_symbol"' in pack["contextPack"]
        assert "repo-a-only" in pack["contextPack"]
        assert pack["tokenEstimator"] in {"tiktoken:cl100k_base", "heuristic:v2"}
        assert pack["estimatedTokens"] == pcm.estimate_context_tokens(pack["contextPack"])
        assert search_a["embeddingProvider"] == "ollama"
        assert search_a["embeddingModel"]
        assert search_a["semanticFallbackReason"]

        explored = pcm.explore(conn, "beta_helper", str(repo_a), token_budget=2000, limit=5)
        assert explored["repoMap"]["artifactCount"] == 1
        assert explored["repoMap"]["symbolCount"] >= 2
        assert explored["repoMap"]["languages"][0]["lang"] == "python"
        assert explored["repoMap"]["topFiles"][0]["filePath"] == "main.py"


def test_context_pack_estimates_wrapped_sections(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    repo = _make_repo(
        tmp_path / "repo-context-budget",
        """
def context_budget_target():
    return "count wrappers too"
""",
    )
    observed: list[str] = []

    def fake_estimate(text: str) -> int:
        observed.append(text)
        return 1

    db_path = tmp_path / "openburnbar.sqlite"
    with sqlite3.connect(db_path) as conn:
        conn.row_factory = sqlite3.Row
        pcm.index_project(conn, str(repo), max_files=25)
        monkeypatch.setattr(pcm, "estimate_context_tokens", fake_estimate)
        pack = pcm.context_pack(conn, "context_budget_target", str(repo), token_budget=500, limit=5)

    assert pack["estimatedTokens"] == 1
    assert observed
    assert any("OPENBURNBAR_UNTRUSTED_CODE" in text and "<file path=" in text for text in observed)


def test_ast_aware_chunks_keep_complete_symbols_when_ranges_are_available() -> None:
    text = (
        "def first_symbol():\n"
        "    return 'first'\n\n"
        "def second_symbol():\n"
        "    value = 'needle-complete-symbol'\n"
        "    return value\n"
    )
    symbols = [
        {
            "name": "first_symbol",
            "range": {"byteStart": 0, "byteEnd": text.index("\ndef second_symbol")},
        },
        {
            "name": "second_symbol",
            "range": {
                "byteStart": text.index("def second_symbol"),
                "byteEnd": len(text),
            },
        },
    ]

    chunks = pcm.ast_aware_chunks(text, symbols, max_chars=120, overlap=10)

    assert any(body.startswith("def second_symbol") and "needle-complete-symbol" in body for _, _, body in chunks)
    assert all(body == text[start:end] for start, end, body in chunks)


def test_diagnostics_producer_caches_python_syntax_errors(tmp_path: Path) -> None:
    repo = _make_repo(
        tmp_path / "repo-diagnostics",
        """
def broken_python(
    return "syntax"
""",
    )
    db_path = tmp_path / "openburnbar.sqlite"
    with sqlite3.connect(db_path) as conn:
        conn.row_factory = sqlite3.Row
        pcm.index_project(conn, str(repo), max_files=25)
        payload = pcm.diagnostics(conn, str(repo), tool="python.compile", limit=10)

    assert payload["diagnostics"]
    diagnostic = payload["diagnostics"][0]
    assert diagnostic["filePath"] == "main.py"
    assert diagnostic["tool"] == "python.compile"
    assert diagnostic["payload"]["diagnostics"][0]["severity"] == "error"


def test_indexed_extensions_are_narrowed_to_static_parser_languages(tmp_path: Path) -> None:
    repo = _make_repo(
        tmp_path / "repo-extension-policy",
        """
def supported_python_symbol():
    return 1
""",
    )
    (repo / "Unsupported.java").write_text("class UnsupportedJavaSymbol {}\n", encoding="utf-8")
    db_path = tmp_path / "openburnbar.sqlite"
    with sqlite3.connect(db_path) as conn:
        conn.row_factory = sqlite3.Row
        result = pcm.index_project(conn, str(repo), max_files=25)
        assert result["indexedFiles"] == 1
        assert pcm.get_symbol(conn, "supported_python_symbol", str(repo), limit=5)["symbols"]
        assert not pcm.get_symbol(conn, "UnsupportedJavaSymbol", str(repo), limit=5)["symbols"]


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


def test_scip_json_import_upgrades_typescript_symbols_and_references(tmp_path: Path) -> None:
    repo = tmp_path / "repo-scip"
    repo.mkdir()
    (repo / ".gitignore").write_text("", encoding="utf-8")
    (repo / "app.ts").write_text(
        """
export function scipTarget() {
  return 1
}

export const value = scipTarget()
""",
        encoding="utf-8",
    )
    scip_json = tmp_path / "index.scip.json"
    scip_json.write_text(
        json.dumps(
            {
                "documents": [
                    {
                        "relativePath": "app.ts",
                        "symbols": [
                            {
                                "symbol": "local app.ts scipTarget().",
                                "displayName": "scipTarget",
                                "kind": "function",
                            }
                        ],
                        "occurrences": [
                            {
                                "symbol": "local app.ts scipTarget().",
                                "range": [1, 16, 1, 26],
                                "symbolRoles": ["definition"],
                            },
                            {
                                "symbol": "local app.ts scipTarget().",
                                "range": [5, 21, 5, 31],
                                "symbolRoles": [],
                            },
                        ],
                    }
                ]
            }
        ),
        encoding="utf-8",
    )
    db_path = tmp_path / "openburnbar.sqlite"
    with sqlite3.connect(db_path) as conn:
        conn.row_factory = sqlite3.Row
        pcm.index_project(conn, str(repo), max_files=25)
        imported = pcm.import_scip_json(conn, str(repo), str(scip_json), ecosystem="typescript")
        symbol = pcm.get_symbol(conn, "scipTarget", str(repo), limit=10)["symbols"][0]
        refs = pcm.find_references(conn, "scipTarget", str(repo), limit=10)["references"]

    assert imported["importedSymbols"] == 1
    assert imported["importedReferences"] == 1
    assert symbol["confidenceTier"] == "scip_index"
    assert symbol["tierEvidence"]["parser"] == "scip"
    assert any(ref["confidenceTier"] == "scip_index" for ref in refs)


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
        result = pcm.index_project(conn, str(repo), max_files=25, max_file_bytes=10_000, storage_budget_bytes=4096)

        assert result["indexedFiles"] == 1
        assert result["rejectedFiles"][0]["labels"] == ["Storage budget cap reached"]

        status = pcm.index_status(conn, str(repo))
        assert status["storageByteCount"] > len((repo / "main.py").read_bytes())
        assert status["storageByteCount"] <= status["storageBudgetBytes"]
        assert status["storageBudgetBytes"] == 4096
        assert status["storageWithinBudget"] is True
        assert status["lastVacuumedAt"] is None
        assert status["productionReady"] is False
        assert any("SQLCipher codec not linked" in reason for reason in status["productionReadinessReasons"])


def test_sqlite_compaction_policy_uses_freelist_page_metrics() -> None:
    assert not pcm.should_compact_sqlite(freelist_count=0, page_count=100, page_size=4096)
    assert not pcm.should_compact_sqlite(freelist_count=3, page_count=100, page_size=4096)
    assert pcm.should_compact_sqlite(freelist_count=4, page_count=20, page_size=4096)
    assert pcm.should_compact_sqlite(freelist_count=32, page_count=1_000, page_size=4096)
    assert pcm.should_compact_sqlite(freelist_count=1, page_count=1_000, page_size=1_048_576)


def test_chunker_matches_shared_parity_fixture() -> None:
    fixture_path = _PARENT.parent / "project-code-memory" / "chunker-parity-fixture.json"
    fixture = json.loads(fixture_path.read_text(encoding="utf-8"))
    max_chars = fixture["chunker"]["maxCharacters"]
    overlap = fixture["chunker"]["overlapCharacters"]

    for case in fixture["cases"]:
        text = "".join(part["text"] * int(part.get("count", 1)) for part in case["parts"])
        chunks = pcm.chunk_text(text, max_chars=max_chars, overlap=overlap)
        assert [[start, end] for start, end, _ in chunks] == case["expectedRanges"], case["name"]
        for start, end, body in chunks:
            assert body == text[start:end]


def test_code_index_skips_unchanged_files_and_prunes_removed_files(tmp_path: Path) -> None:
    repo = _make_repo(
        tmp_path / "repo-delta",
        """
def stable_delta_symbol():
    return "stableonlytoken"
""",
    )
    (repo / "removed.py").write_text(
        """
def removed_delta_symbol():
    return "vanishedonlytoken"
""",
        encoding="utf-8",
    )
    db_path = tmp_path / "openburnbar.sqlite"
    with sqlite3.connect(db_path) as conn:
        conn.row_factory = sqlite3.Row
        pcm.index_project(conn, str(repo), max_files=25)
        first_indexed_at = conn.execute("SELECT indexed_at FROM code_artifacts WHERE file_path = 'main.py'").fetchone()[
            0
        ]

        time.sleep(0.02)
        (repo / "removed.py").unlink()
        result = pcm.index_project(conn, str(repo), max_files=25)

        assert result["indexedFiles"] == 1
        assert (
            conn.execute("SELECT indexed_at FROM code_artifacts WHERE file_path = 'main.py'").fetchone()[0]
            == first_indexed_at
        )
        assert conn.execute("SELECT COUNT(*) FROM code_artifacts WHERE file_path = 'removed.py'").fetchone()[0] == 0
        assert conn.execute("SELECT COUNT(*) FROM pcm_file_manifest WHERE file_path = 'main.py'").fetchone()[0] == 1
        assert not pcm.search_code(conn, "vanishedonlytoken", str(repo), limit=10)["results"]


def test_project_identity_v2_keeps_project_id_after_git_checkout_move(tmp_path: Path) -> None:
    repo = _make_repo(
        tmp_path / "repo-identity",
        """
def moved_identity_symbol():
    return "identity-move-token"
""",
    )
    _run_git(repo, "init")
    _run_git(repo, "config", "user.email", "agent@example.com")
    _run_git(repo, "config", "user.name", "Agent")
    _run_git(repo, "remote", "add", "origin", "https://example.com/openburnbar/identity-fixture.git")
    _run_git(repo, "add", ".")
    _run_git(repo, "commit", "-m", "Initial fixture")

    db_path = tmp_path / "openburnbar.sqlite"
    with sqlite3.connect(db_path) as conn:
        conn.row_factory = sqlite3.Row
        indexed = pcm.index_project(conn, str(repo), max_files=25)
        moved = tmp_path / "repo-identity-moved"
        repo.rename(moved)
        searched = pcm.search_code(conn, "identity-move-token", str(moved), limit=10)

        assert searched["projectID"] == indexed["projectID"]
        assert searched["results"][0]["filePath"] == "main.py"
        assert (
            conn.execute(
                "SELECT COUNT(*) FROM pcm_project_aliases WHERE project_id = ?",
                (indexed["projectID"],),
            ).fetchone()[0]
            == 2
        )
        assert (
            conn.execute(
                "SELECT COUNT(*) FROM pcm_projects WHERE project_id = ? AND identity_version = 2",
                (indexed["projectID"],),
            ).fetchone()[0]
            == 1
        )


def test_code_index_uses_git_exclude_standard_for_negation_and_globstar(tmp_path: Path) -> None:
    repo = _make_repo(
        tmp_path / "repo-gitignore",
        """
def clean_symbol():
    return 1
""",
    )
    subprocess.run(["git", "init"], cwd=repo, check=True, capture_output=True)
    (repo / ".gitignore").write_text("**/secrets/*\n!**/secrets/keep.py\n", encoding="utf-8")
    secret_dir = repo / "nested" / "secrets"
    secret_dir.mkdir(parents=True)
    (secret_dir / "drop.py").write_text("def ignored_secret_symbol():\n    return 1\n", encoding="utf-8")
    (secret_dir / "keep.py").write_text("def kept_secret_symbol():\n    return 1\n", encoding="utf-8")

    db_path = tmp_path / "openburnbar.sqlite"
    with sqlite3.connect(db_path) as conn:
        conn.row_factory = sqlite3.Row
        pcm.index_project(conn, str(repo), max_files=25)

        assert not pcm.get_symbol(conn, "ignored_secret_symbol", str(repo), limit=10)["symbols"]
        assert pcm.get_symbol(conn, "kept_secret_symbol", str(repo), limit=10)["symbols"]


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
        assert "GitHub token detected" in result["rejectedFiles"][0]["labels"]

        audit = pcm.audit_trail(conn, str(repo), limit=10)
        event = next(item for item in audit["events"] if item["action"] == "code.secret_rejected")
        assert "GitHub token detected" in event["labels"]
        assert "ghp_" not in json.dumps(event)
        assert event["hash"] == _expected_audit_hash(event)


def test_shared_secret_corpus_rejects_encoded_and_high_entropy_code(tmp_path: Path) -> None:
    repo = _make_repo(
        tmp_path / "repo-secret-corpus",
        """
def clean_symbol():
    return 1
""",
    )
    encoded_github = base64.b64encode(("ghp_" + ("A1B2C3D4E5F6G7H8I9J0K1L2M3N4O5P6Q7R8")).encode("utf-8")).decode(
        "ascii"
    )
    openssh_magic = "-".join(["openssh", "key", "v1"]).encode("ascii")
    encoded_openssh = base64.b64encode(openssh_magic + b"\x00\xff\xfe\x80" + (b"A" * 32)).decode("ascii")
    (repo / "encoded.py").write_text(f'payload = "{encoded_github}"\n', encoding="utf-8")
    (repo / "encoded_openssh.py").write_text(f'payload = "{encoded_openssh}"\n', encoding="utf-8")
    (repo / "terraform.tfvars").write_text(
        'service_api_key = "abcdefghijklmnopqrstuvwxyz1234567890"\n',
        encoding="utf-8",
    )
    (repo / "k8s.yaml").write_text(
        """
apiVersion: v1
kind: Secret
data:
  token: abcdefghijklmnopqrstuvwxyz123456
""",
        encoding="utf-8",
    )
    high_entropy_fixture = "".join(
        ["Az9qLm8Pr2Vx7", "Ns4Tu6Wy1Za3", "Qb5Cd7Ef9Gh2", "Jk4Mn6"],
    )
    (repo / "entropy.py").write_text(f'token = "{high_entropy_fixture}"\n', encoding="utf-8")

    db_path = tmp_path / "openburnbar.sqlite"
    with sqlite3.connect(db_path) as conn:
        conn.row_factory = sqlite3.Row
        result = pcm.index_project(conn, str(repo), max_files=25)

        labels = {label for item in result["rejectedFiles"] for label in item["labels"]}
        assert result["indexedFiles"] == 1
        assert "GitHub token detected" in labels
        assert "OpenSSH private key payload detected" in labels
        assert "Terraform variable secret detected" in labels
        assert "Kubernetes Secret manifest detected" not in labels
        assert "High entropy secret-like token detected" in labels


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

        stale_search = pcm.search_code(conn, "stale-token", str(repo), limit=10)
        assert stale_search["status"] == "degraded"
        assert stale_search["code"] == "STALE_INDEX"
        assert stale_search["results"] == []
        assert stale_search["degradation"]["staleCandidateCount"] >= 1
        assert pcm.get_symbol(conn, "stale_helper", str(repo), limit=10)["symbols"] == []

        pcm.index_project(conn, str(repo), max_files=25)
        assert pcm.search_code(conn, "fresh-token", str(repo), limit=10)["results"]
        assert pcm.get_symbol(conn, "fresh_helper", str(repo), limit=10)["symbols"]


def test_remember_succeeds_locally_and_reports_daemon_mirror_unreachable(tmp_path: Path, monkeypatch) -> None:
    # Contract change (memory MCP v2): `burnbar_remember` commits to the MCP-owned,
    # gated, audited memory store and *mirrors* to the daemon ledger. A missing
    # daemon degrades the mirror, never the local write — and the app database
    # is never touched by the engine.
    db_path = tmp_path / "openburnbar.sqlite"
    sqlite3.connect(db_path).close()
    repo = _make_repo(tmp_path / "repo-memory", "def durable_fact(): return 1\n")
    monkeypatch.setenv("BURNBAR_DB_PATH", str(db_path))
    monkeypatch.setenv("OPENBURNBAR_LOCAL_MCP_ENABLE_LOCAL_WRITE", "true")
    monkeypatch.setenv("OPENBURNBAR_DAEMON_SOCKET_PATH", str(tmp_path / "missing.sock"))

    server = _load_server()
    payload = json.loads(server.burnbar_remember("Remember the durable test fact.", project_path=str(repo)))

    assert payload["status"] == "ok"
    assert payload["event"] == "ADD"
    assert payload["mirror"]["status"] == "unreachable"
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
    monkeypatch.setattr(server, "_signed_cli_path", lambda: None)
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


def test_server_code_read_tools_open_sqlite_read_only(monkeypatch) -> None:
    server = _load_server()
    calls: list[str] = []

    class FakeConnection:
        row_factory = None

        def __enter__(self):
            return self

        def __exit__(self, *_args):
            return False

    def fake_connect_ro(_path: Path) -> FakeConnection:
        calls.append("ro")
        return FakeConnection()

    def fail_connect_rw(_path: Path):
        raise AssertionError("code read tools must not open read-write SQLite handles")

    monkeypatch.setattr(server, "_default_db_path", lambda: Path("/tmp/openburnbar.sqlite"))
    monkeypatch.setattr(server, "_connect_ro", fake_connect_ro)
    monkeypatch.setattr(server, "_connect_rw", fail_connect_rw)
    monkeypatch.setattr(server.pcm, "search_code", lambda *_args, **_kwargs: {"status": "ok"})
    monkeypatch.setattr(server.pcm, "context_pack", lambda *_args, **_kwargs: {"status": "ok"})
    monkeypatch.setattr(server.pcm, "get_symbol", lambda *_args, **_kwargs: {"status": "ok"})
    monkeypatch.setattr(server.pcm, "find_references", lambda *_args, **_kwargs: {"status": "ok"})
    monkeypatch.setattr(server.pcm, "call_graph", lambda *_args, **_kwargs: {"status": "ok"})
    monkeypatch.setattr(server.pcm, "diagnostics", lambda *_args, **_kwargs: {"status": "ok"})
    monkeypatch.setattr(server.pcm, "index_status", lambda *_args, **_kwargs: {"status": "ok"})
    monkeypatch.setattr(server.pcm, "table_names", lambda *_args, **_kwargs: set())

    json.loads(server.burnbar_search_code("target"))
    json.loads(server.burnbar_context_pack("target"))
    json.loads(server.burnbar_get_symbol("target"))
    json.loads(server.burnbar_find_references("target"))
    json.loads(server.burnbar_call_graph("target"))
    json.loads(server.burnbar_diagnostics())
    json.loads(server.burnbar_index_status())
    json.loads(server.burnbar_memory_doctor())

    assert calls == ["ro"] * 8


def test_local_mcp_rate_limiter_bounds_code_and_memory_tools(monkeypatch) -> None:
    server = _load_server()
    server._reset_local_mcp_rate_limiter_for_tests()
    monkeypatch.setenv("OPENBURNBAR_LOCAL_MCP_CODE_RATE_LIMIT_PER_MINUTE", "2")
    monkeypatch.setenv("OPENBURNBAR_LOCAL_MCP_MEMORY_RATE_LIMIT_PER_MINUTE", "1")

    assert server._local_mcp_rate_limit("burnbar_search_code", "code") is None
    assert server._local_mcp_rate_limit("burnbar_search_code", "code") is None
    limited_code = json.loads(server._local_mcp_rate_limit("burnbar_search_code", "code"))
    assert limited_code["code"] == "LOCAL_MCP_RATE_LIMITED"
    assert limited_code["family"] == "code"

    assert server._local_mcp_rate_limit("burnbar_recall", "memory") is None
    limited_memory = json.loads(server._local_mcp_rate_limit("burnbar_recall", "memory"))
    assert limited_memory["code"] == "LOCAL_MCP_RATE_LIMITED"
    assert limited_memory["family"] == "memory"

    server._reset_local_mcp_rate_limiter_for_tests()


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

    # Memory writes land in the MCP-owned engine store (never the app database);
    # the legacy direct-write override must not resurrect direct SQLite writes.
    assert remembered["status"] == "ok"
    assert remembered["mirror"]["status"] == "unreachable"
    assert indexed["code"] == "DAEMON_WRITE_REQUIRED"
    assert explored["code"] == "DAEMON_WRITE_REQUIRED"

    with sqlite3.connect(db_path) as conn:
        assert "agent_memories" not in pcm.table_names(conn)
        assert "memories" not in pcm.table_names(conn)


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


def test_remember_rejects_key_material_fragments_with_label_only_audit(tmp_path: Path) -> None:
    repo = _make_repo(tmp_path / "repo-key-material-mem", "def durable_fact(): return 1\n")
    db_path = tmp_path / "openburnbar.sqlite"
    private_marker = " ".join(["-----BEGIN", "OPENSSH", "PRIVATE", "KEY-----"])
    openssh_magic = "-".join(["openssh", "key", "v1"])
    encoded_openssh = base64.b64encode(openssh_magic.encode("ascii") + b"\x00\xff\xfe\x80" + (b"A" * 32)).decode(
        "ascii"
    )

    with sqlite3.connect(db_path) as conn:
        conn.row_factory = sqlite3.Row
        marker_result = pcm.remember(
            conn,
            f"Remember this key marker: {private_marker}",
            project_path=str(repo),
            kind="fact",
            scope="personal",
            tags=["secret"],
            confidence=1.0,
            source_path=None,
        )
        payload_result = pcm.remember(
            conn,
            f"Remember this encoded payload: {encoded_openssh}",
            project_path=str(repo),
            kind="fact",
            scope="personal",
            tags=["secret"],
            confidence=1.0,
            source_path=None,
        )

        assert marker_result["status"] == "rejected"
        assert payload_result["status"] == "rejected"
        assert "Private key marker detected" in marker_result["labels"]
        assert "OpenSSH private key payload detected" in payload_result["labels"]
        assert "OpenSSH private key payload detected" not in pcm.scan_secrets(openssh_magic)
        assert conn.execute("SELECT COUNT(*) FROM agent_memories").fetchone()[0] == 0

        audit = pcm.audit_trail(conn, str(repo), limit=10)
        audit_json = json.dumps(audit)
        assert "Private key marker detected" in audit_json
        assert "OpenSSH private key payload detected" in audit_json
        assert private_marker not in audit_json
        assert encoded_openssh not in audit_json


def test_index_project_evicts_oldest_files_first_under_budget(tmp_path: Path) -> None:
    # Age-aware eviction: when a project exceeds its storage budget, the NEWEST
    # (most relevant) files are kept and the OLDEST are evicted — deterministic,
    # not whatever order the filesystem walk yields.
    repo = tmp_path / "repo-evict"
    repo.mkdir()
    (repo / ".gitignore").write_text("ignored/\n", encoding="utf-8")
    older = repo / "older.py"
    newer = repo / "newer.py"
    older_body = "def older_symbol():\n    return 1\n"
    newer_body = "def newer_symbol():\n    return 1\n"
    older.write_text(older_body, encoding="utf-8")
    newer.write_text(newer_body, encoding="utf-8")
    os.utime(older, (1_000, 1_000))
    os.utime(newer, (2_000, 2_000))
    db_path = tmp_path / "openburnbar.sqlite"
    with sqlite3.connect(db_path) as conn:
        conn.row_factory = sqlite3.Row
        project_id = pcm.resolve_project_id(conn, repo)
        newer_budget = pcm.estimated_code_storage_byte_count(
            source_bytes=len(newer_body.encode("utf-8")),
            chunks=pcm.chunk_text(newer_body),
            file_path="newer.py",
            project_id=project_id,
        )
        older_budget = pcm.estimated_code_storage_byte_count(
            source_bytes=len(older_body.encode("utf-8")),
            chunks=pcm.chunk_text(older_body),
            file_path="older.py",
            project_id=project_id,
        )
        budget = max(newer_budget, older_budget)

        # Budget fits exactly one file, forcing one eviction.
        result = pcm.index_project(conn, str(repo), max_files=25, storage_budget_bytes=budget)
        assert result["indexedFiles"] == 1
        assert [r["filePath"] for r in result["rejectedFiles"]] == ["older.py"]
        assert result["rejectedFiles"][0]["labels"] == ["Storage budget cap reached"]
