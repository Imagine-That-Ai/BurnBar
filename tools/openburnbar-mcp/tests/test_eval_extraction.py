"""The heuristic extractor's quality is a measured, ratcheting number."""

from __future__ import annotations

import sys
from pathlib import Path

MCP_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(MCP_DIR))

import eval_memory  # noqa: E402

GOLD = MCP_DIR / "eval" / "extraction_gold.json"
RECALL_FLOOR = 0.65  # measured 0.667 on 2026-09-02, rounded down to a multiple of 0.05; never lower it


def test_gold_set_is_large_enough_to_mean_something():
    report = eval_memory.run_extraction(GOLD)
    assert report["cases"] >= 25
    assert report["expected"] >= 20


def test_heuristic_extraction_meets_the_floor_and_leaks_nothing():
    report = eval_memory.run_extraction(GOLD)
    assert report["recall"] >= RECALL_FLOOR, report
    assert report["leaks"] == 0, report
    assert report["emptyCaseFacts"] <= 2, report


def test_gate_matrix_detects_every_raw_shape():
    matrix = eval_memory.run_gate_matrix()
    assert len(matrix) >= 12
    assert all(row["raw"] for row in matrix), [row["shape"] for row in matrix if not row["raw"]]
