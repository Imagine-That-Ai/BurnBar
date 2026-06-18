#!/usr/bin/env python3
"""Synthetic Project Code Memory load proof.

Generates a temporary Python repo with 100k symbols, indexes it through the
local Project Code Memory implementation, and checks storage/query invariants.
This is intentionally outside the default fast unit suite.
"""

from __future__ import annotations

import os
import shutil
import sqlite3
import sys
import tempfile
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
MCP_DIR = ROOT / "tools" / "openburnbar-mcp"
if str(MCP_DIR) not in sys.path:
    sys.path.insert(0, str(MCP_DIR))

import project_code_memory as pcm  # noqa: E402


FILE_COUNT = int(os.environ.get("OPENBURNBAR_CODE_MEMORY_LOAD_FILES", "100"))
SYMBOLS_PER_FILE = int(os.environ.get("OPENBURNBAR_CODE_MEMORY_LOAD_SYMBOLS_PER_FILE", "1000"))
MIN_SYMBOLS = int(os.environ.get("OPENBURNBAR_CODE_MEMORY_LOAD_MIN_SYMBOLS", "100000"))
QUERY_LATENCY_SECONDS = float(os.environ.get("OPENBURNBAR_CODE_MEMORY_LOAD_QUERY_LATENCY_SECONDS", "2.0"))
ALLOWED_FAILURE_CODES = {
    "indexed-files",
    "symbol-count",
    "storage-budget",
    "query-empty",
    "query-latency",
    "non-code-row-drift",
}


def write_repo(repo: Path) -> None:
    repo.mkdir(parents=True)
    for file_index in range(FILE_COUNT):
        lines = ["# generated Project Code Memory load fixture\n"]
        for symbol_index in range(SYMBOLS_PER_FILE):
            name = f"load_symbol_{file_index:03d}_{symbol_index:04d}"
            lines.append(f"def {name}():\n    return '{name}'\n\n")
        (repo / f"module_{file_index:03d}.py").write_text("".join(lines), encoding="utf-8")


def seed_non_code_row(conn: sqlite3.Connection) -> None:
    ts = "2026-06-16T00:00:00Z"
    conn.execute(
        """
        INSERT INTO search_documents
            (id, sourceKind, sourceID, sourceVersionID, provider, projectName, title, bodyPreview, indexedAt, contentHash, createdAt, updatedAt)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            "conversation-sentinel",
            "conversation",
            "conversation-sentinel",
            "",
            "test",
            "sentinel",
            "Conversation sentinel",
            "untouched",
            ts,
            "sentinel",
            ts,
            ts,
        ),
    )


def emit_summary(
    *,
    failed: bool,
    indexed_files: int,
    symbol_count: int,
    storage_byte_count: int,
    storage_budget_bytes: int,
    index_seconds: float,
    query_seconds: float,
    non_code_rows_before: int,
    non_code_rows_after: int,
    failure_codes: list[str],
) -> None:
    safe_codes = [code for code in failure_codes if code in ALLOWED_FAILURE_CODES]
    codes_json = "[" + ",".join(f'"{code}"' for code in safe_codes) + "]"
    sys.stdout.write(
        "{"
        f'"failureCodes":{codes_json},'
        f'"failureCount":{len(safe_codes)},'
        f'"indexSeconds":{index_seconds:.3f},'
        f'"indexedFiles":{indexed_files},'
        f'"nonCodeRowsAfter":{non_code_rows_after},'
        f'"nonCodeRowsBefore":{non_code_rows_before},'
        f'"querySeconds":{query_seconds:.6f},'
        f'"result":"{"failed" if failed else "passed"}",'
        f'"storageBudgetBytes":{storage_budget_bytes},'
        f'"storageByteCount":{storage_byte_count},'
        f'"symbolCount":{symbol_count}'
        "}\n"
    )


def main() -> int:
    temp = Path(tempfile.mkdtemp(prefix="openburnbar-code-memory-load-"))
    try:
        repo = temp / "repo"
        db_path = temp / "openburnbar.sqlite"
        write_repo(repo)
        with sqlite3.connect(db_path) as conn:
            conn.row_factory = sqlite3.Row
            pcm.ensure_schema(conn)
            seed_non_code_row(conn)
            before_non_code = conn.execute(
                "SELECT COUNT(*) FROM search_documents WHERE sourceKind != 'code'"
            ).fetchone()[0]

            started = time.perf_counter()
            result = pcm.index_project(
                conn,
                str(repo),
                max_files=FILE_COUNT + 10,
                max_file_bytes=2_000_000,
                storage_budget_bytes=512 * 1024 * 1024,
            )
            index_seconds = time.perf_counter() - started

            symbol_count = conn.execute("SELECT COUNT(*) FROM code_symbols").fetchone()[0]
            storage_status = pcm.index_status(conn, str(repo))
            after_non_code = conn.execute(
                "SELECT COUNT(*) FROM search_documents WHERE sourceKind != 'code'"
            ).fetchone()[0]

            query_name = f"load_symbol_{FILE_COUNT - 1:03d}_{SYMBOLS_PER_FILE - 1:04d}"
            query_started = time.perf_counter()
            query = pcm.get_symbol(conn, query_name, str(repo), limit=5)
            query_seconds = time.perf_counter() - query_started

        failures: list[str] = []
        failure_codes: list[str] = []
        if result["indexedFiles"] != FILE_COUNT:
            failures.append(f"indexedFiles={result['indexedFiles']} expected {FILE_COUNT}")
            failure_codes.append("indexed-files")
        if symbol_count < MIN_SYMBOLS:
            failures.append(f"symbolCount={symbol_count} expected >= {MIN_SYMBOLS}")
            failure_codes.append("symbol-count")
        if not storage_status["storageWithinBudget"]:
            failures.append("storageWithinBudget=false")
            failure_codes.append("storage-budget")
        if not query["symbols"]:
            failures.append(f"query returned no symbols for {query_name}")
            failure_codes.append("query-empty")
        if query_seconds > QUERY_LATENCY_SECONDS:
            failures.append(f"queryLatency={query_seconds:.3f}s expected <= {QUERY_LATENCY_SECONDS:.3f}s")
            failure_codes.append("query-latency")
        if before_non_code != after_non_code:
            failures.append(f"nonCodeRows changed from {before_non_code} to {after_non_code}")
            failure_codes.append("non-code-row-drift")

        emit_summary(
            failed=bool(failures),
            indexed_files=int(result["indexedFiles"]),
            symbol_count=int(symbol_count),
            storage_byte_count=int(storage_status["storageByteCount"]),
            storage_budget_bytes=int(storage_status["storageBudgetBytes"]),
            index_seconds=float(index_seconds),
            query_seconds=float(query_seconds),
            non_code_rows_before=int(before_non_code),
            non_code_rows_after=int(after_non_code),
            failure_codes=failure_codes,
        )
        return 1 if failures else 0
    finally:
        shutil.rmtree(temp, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
