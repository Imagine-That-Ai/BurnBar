"""The heuristic extractor's quality is a measured, ratcheting number."""

from __future__ import annotations

import json
import sys

import pytest
from pathlib import Path

MCP_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(MCP_DIR))

import eval_memory  # noqa: E402

GOLD = MCP_DIR / "eval" / "extraction_gold.json"
RECALL_FLOOR = 0.65  # measured 0.667 on 2026-09-02, rounded down to a multiple of 0.05; never lower it

import eval_memory as ev  # noqa: E402


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


JUDGE_GOLD = MCP_DIR / "eval" / "judge_gold.json"


def test_judge_gold_set_is_large_enough():
    cases = json.loads(JUDGE_GOLD.read_text(encoding="utf-8"))["cases"]
    assert len(cases) >= 60
    for event in ("ADD", "UPDATE", "NONE", "DELETE"):
        assert sum(1 for case in cases if case["expected"]["event"] == event) >= 8, event


def test_rules_baseline_on_judge_gold_is_recorded():
    report = eval_memory.run_judge(JUDGE_GOLD)
    assert report["cases"] >= 60
    assert 0.35 <= report["rulesAgreement"] <= 1.0, report
    assert set(report["confusion"]) == {"ADD", "UPDATE", "NONE", "DELETE"}


def test_extractor_model_hint_composes_the_pro_extractor_name():
    """`--extractor pro --extractor-model openrouter/x` must run the `pro:openrouter/x` path and report it."""
    assert ev.compose_extractor("heuristic", None) == "heuristic"
    assert ev.compose_extractor("pro", None) == "pro"
    assert ev.compose_extractor("pro", "openrouter/anthropic/claude-opus-5") == "pro:openrouter/anthropic/claude-opus-5"
    assert ev.compose_extractor("claude", "ignored-for-non-pro") == "claude"


def test_pro_extractor_without_a_policy_exits_with_the_denial_code(monkeypatch):
    """Without the daemon the eval must stop with the gateway code, not a traceback."""
    monkeypatch.delenv(eval_memory.me.MODEL_POLICY_JSON_ENV, raising=False)
    eval_memory.me.reset_provider_cache_for_tests()
    run = eval_memory._extraction_fn("pro")
    with pytest.raises(SystemExit) as stop:
        run([{"role": "user", "content": "We deploy on Fridays."}])
    assert "CLOUD_CONSENT_REQUIRED" in str(stop.value)
