#!/usr/bin/env python3
from __future__ import annotations

import json
import sqlite3
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
MCP_ROOT = REPO_ROOT / "tools" / "openburnbar-mcp"
if str(MCP_ROOT) not in sys.path:
    sys.path.insert(0, str(MCP_ROOT))

import project_code_memory as pcm  # noqa: E402


def write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def precision_at(hits: list[dict], expected_file: str, k: int) -> float:
    return 1.0 if any(hit.get("filePath") == expected_file for hit in hits[:k]) else 0.0


def reciprocal_rank(hits: list[dict], expected_file: str) -> float:
    for index, hit in enumerate(hits, start=1):
        if hit.get("filePath") == expected_file:
            return 1.0 / float(index)
    return 0.0


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="pcm-retrieval-eval-") as raw_tmp:
        tmp = Path(raw_tmp)
        repo = tmp / "repo"
        repo.mkdir()
        write(repo / ".gitignore", "ignored/\n")
        write(
            repo / "src" / "quota.py",
            """
def compute_quota_window():
    return "quota-window-token"

def quota_alert_message():
    return compute_quota_window()
""",
        )
        write(
            repo / "src" / "sync.py",
            """
def sync_checkpoint_writer():
    return "sync-checkpoint-token"
""",
        )
        write(
            repo / "src" / "ui.py",
            """
def render_status_panel():
    return "status-panel-token"
""",
        )

        db_path = tmp / "openburnbar.sqlite"
        with sqlite3.connect(db_path) as conn:
            conn.row_factory = sqlite3.Row
            pcm.index_project(conn, str(repo), max_files=25)
            cases = [
                ("quota window token", "src/quota.py"),
                ("sync checkpoint writer", "src/sync.py"),
                ("status panel token", "src/ui.py"),
            ]
            scored = []
            context_token_waste = []
            for query, expected_file in cases:
                search = pcm.search_code(conn, query, str(repo), limit=5)
                hits = search["results"]
                pack = pcm.context_pack(conn, query, str(repo), token_budget=1200, limit=5)
                useful_tokens = max(1, pcm.estimate_context_tokens(expected_file + query))
                estimated_tokens = max(1, int(pack["estimatedTokens"]))
                context_token_waste.append(max(0.0, 1.0 - (useful_tokens / float(estimated_tokens))))
                scored.append(
                    {
                        "query": query,
                        "expectedFile": expected_file,
                        "precisionAt1": precision_at(hits, expected_file, 1),
                        "precisionAt5": precision_at(hits, expected_file, 5),
                        "reciprocalRank": reciprocal_rank(hits, expected_file),
                        "contextPackHasCompleteSymbol": 'contentKind="complete_symbol"' in pack["contextPack"],
                    }
                )

            stale_before = pcm.search_code(conn, "quota-window-token", str(repo), limit=5)["results"]
            write(repo / "src" / "quota.py", 'def new_quota_window():\n    return "fresh-quota-token"\n')
            stale_after = pcm.search_code(conn, "quota-window-token", str(repo), limit=5)

        precision_at_1 = sum(item["precisionAt1"] for item in scored) / len(scored)
        precision_at_5 = sum(item["precisionAt5"] for item in scored) / len(scored)
        mrr = sum(item["reciprocalRank"] for item in scored) / len(scored)
        stale_false_positive_rate = 0.0 if stale_before and not stale_after["results"] else 1.0
        avg_context_token_waste = sum(context_token_waste) / len(context_token_waste)
        report = {
            "status": "ok",
            "caseCount": len(scored),
            "precisionAt1": precision_at_1,
            "precisionAt5": precision_at_5,
            "mrr": mrr,
            "staleFalsePositiveRate": stale_false_positive_rate,
            "avgContextTokenWaste": avg_context_token_waste,
            "cases": scored,
        }
        print(json.dumps(report, indent=2, sort_keys=True))
        if precision_at_1 < 1.0 or precision_at_5 < 1.0 or mrr < 1.0:
            return 1
        if stale_false_positive_rate > 0.0:
            return 1
        if not all(item["contextPackHasCompleteSymbol"] for item in scored):
            return 1
        if avg_context_token_waste > 0.98:
            return 1
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
