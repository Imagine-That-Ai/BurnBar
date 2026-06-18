#!/usr/bin/env python3
from __future__ import annotations

import json
import sqlite3
import statistics
import sys
import tempfile
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
MCP_ROOT = REPO_ROOT / "tools" / "openburnbar-mcp"
if str(MCP_ROOT) not in sys.path:
    sys.path.insert(0, str(MCP_ROOT))

import project_code_memory as pcm  # noqa: E402


def percentile(values: list[float], pct: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, round((pct / 100.0) * (len(ordered) - 1))))
    return ordered[index]


def semantic_gate_report(status: dict[str, object] | None) -> dict[str, object]:
    if status is None:
        return {"semanticAvailable": None, "fallbackCategory": "missing"}
    fallback = str(status.get("semanticFallbackReason") or "")
    if "fingerprints" in fallback:
        fallback_category = "deterministic-fingerprints"
    elif "OPENBURNBAR_CODE_EMBEDDING_PROVIDER" in fallback:
        fallback_category = "provider-not-configured"
    else:
        fallback_category = "other"
    return {
        "semanticAvailable": bool(status.get("semanticAvailable")),
        "fallbackCategory": fallback_category,
    }


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="pcm-vector-benchmark-") as raw_tmp:
        tmp = Path(raw_tmp)
        repo = tmp / "repo"
        repo.mkdir()
        (repo / ".gitignore").write_text("", encoding="utf-8")
        for index in range(120):
            (repo / f"module_{index:03}.py").write_text(
                f"""
def benchmark_symbol_{index:03}():
    return "benchmark-token-{index:03}"

def caller_{index:03}():
    return benchmark_symbol_{index:03}()
""",
                encoding="utf-8",
            )
        db_path = tmp / "openburnbar.sqlite"
        with sqlite3.connect(db_path) as conn:
            conn.row_factory = sqlite3.Row
            start = time.perf_counter()
            indexed = pcm.index_project(conn, str(repo), max_files=250)
            index_seconds = time.perf_counter() - start
            latencies_ms: list[float] = []
            semantic_status = None
            for index in range(40):
                query = f"benchmark-token-{index:03}"
                query_start = time.perf_counter()
                result = pcm.search_code(conn, query, str(repo), limit=10)
                latencies_ms.append((time.perf_counter() - query_start) * 1000.0)
                semantic_status = {
                    "semanticAvailable": result["semanticAvailable"],
                    "embeddingProvider": result["embeddingProvider"],
                    "embeddingModel": result["embeddingModel"],
                    "embeddingVersion": result["embeddingVersion"],
                    "semanticFallbackReason": result["semanticFallbackReason"],
                }
        report = {
            "status": "ok",
            "fixture": {
                "files": 120,
                "indexedFiles": indexed["indexedFiles"],
                "chunks": indexed["chunkCount"],
                "storageByteCount": indexed["storageByteCount"],
            },
            "indexSeconds": index_seconds,
            "searchLatencyMs": {
                "p50": statistics.median(latencies_ms),
                "p95": percentile(latencies_ms, 95),
                "p99": percentile(latencies_ms, 99),
                "max": max(latencies_ms),
            },
            "denseRetrievalGate": semantic_gate_report(semantic_status),
            "vectorBackend": "disabled-no-real-current-embeddings",
        }
        sys.stdout.write(json.dumps(report, indent=2, sort_keys=True) + "\n")
        if indexed["indexedFiles"] != 120:
            return 1
        if semantic_status is None or semantic_status["semanticAvailable"] is not False:
            return 1
        fallback = str(semantic_status["semanticFallbackReason"])
        if "fingerprints" not in fallback and "OPENBURNBAR_CODE_EMBEDDING_PROVIDER" not in fallback:
            return 1
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
