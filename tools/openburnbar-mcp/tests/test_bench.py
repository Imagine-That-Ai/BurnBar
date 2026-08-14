#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import json
import sys
import types
from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest


_HERE = Path(__file__).resolve().parent
_PARENT = _HERE.parent
if str(_PARENT) not in sys.path:
    sys.path.insert(0, str(_PARENT))

import bench  # noqa: E402
import ministry  # noqa: E402


def _iso(days_ago: float = 0.0) -> str:
    return (datetime.now(UTC) - timedelta(days=days_ago)).isoformat().replace("+00:00", "Z")


def _stack(
    harness: str,
    model: str,
    family: str,
    n: int,
    solution_rate: float,
    *,
    language: str = "python",
    platform: str = "cli",
    strict_rate: float | None = None,
    ci95: list[float] | None = None,
    cost: float = 2.0,
    wall: float = 600.0,
    confidence: str = "high",
    evidence: str = "measured",
) -> dict:
    return {
        "harness": harness,
        "model": model,
        "config": "default",
        "scope": {"family": family, "language": language, "platform": platform},
        "n": n,
        "strict_rate": strict_rate if strict_rate is not None else round(solution_rate - 0.1, 3),
        "solution_rate": solution_rate,
        "ci95": ci95 or [max(0.0, solution_rate - 0.15), min(1.0, solution_rate + 0.15)],
        "cost_usd_median": cost,
        "wall_seconds_median": wall,
        "tokens_median": 80000,
        "arena_bt": None,
        "confidence": confidence,
        "evidence": evidence,
    }


def _bench_payload(generated_at: str) -> dict:
    return {
        "schema_version": 1,
        "generated_at_utc": generated_at,
        "source": {"trees": ["test-fixture"], "cells_measured": 190, "cells_excluded": 2, "runs_sha256": "ab" * 32},
        "models": [
            {"id": "model-alpha", "display": "Model Alpha", "provider": "p1"},
            {"id": "model-beta", "display": "Model Beta", "provider": "p2"},
            {"id": "model-gamma", "display": "Model Gamma", "provider": "p3"},
        ],
        "harnesses": [{"id": "droid", "display": "Droid"}, {"id": "codex", "display": "Codex"}],
        "stacks": [
            _stack("droid", "model-alpha", "refactor", 40, 0.40, ci95=[0.24, 0.54], cost=2.0),
            _stack("droid", "model-beta", "refactor", 40, 0.70, ci95=[0.56, 0.82], cost=3.0),
            # n < 10 with the highest raw rate: must be disclosed low and never ranked first.
            _stack("droid", "model-gamma", "refactor", 5, 0.95, cost=1.0, wall=300.0),
            _stack("codex", "model-alpha", "refactor", 8, 0.50, confidence="medium"),
            _stack("droid", "model-alpha", "overall", 30, 0.45),
            _stack("droid", "model-beta", "overall", 30, 0.55),
            _stack("droid", "model-beta", "bugfix", 20, 0.60, confidence="medium", evidence="inferred"),
            _stack(
                "codex",
                "model-beta",
                "feature",
                25,
                0.50,
                language="typescript",
                platform="browser",
                confidence="medium",
            ),
        ],
        "frontier": [
            {
                "harness": "droid",
                "model": "model-beta",
                "scope": {"family": "overall"},
                "solution_rate": 0.55,
                "cost_usd_median": 3.0,
                "wall_seconds_median": 700.0,
            }
        ],
        "arena": {
            "votes": 3,
            "ratings": [{"harness": "droid", "model": "model-beta", "bt": 1.2, "ci95": [0.8, 1.6], "votes": 3}],
        },
    }


def _write_bench(tmp_path: Path, payload: dict) -> Path:
    path = tmp_path / "bench.json"
    path.write_text(json.dumps(payload), encoding="utf-8")
    return path


@pytest.fixture(autouse=True)
def _fresh_bench_state(monkeypatch: pytest.MonkeyPatch) -> None:
    bench.reset_cache()
    monkeypatch.delenv(bench.BENCH_JSON_ENV, raising=False)


# ---------------------------------------------------------------------------
# load_bench: missing / invalid / stale / fresh paths
# ---------------------------------------------------------------------------


def test_load_bench_missing_file_returns_guidance(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    missing = tmp_path / "absent.json"
    monkeypatch.setenv(bench.BENCH_JSON_ENV, str(missing))

    loaded = bench.load_bench()

    assert loaded["ok"] is False
    assert loaded["error"] == "bench_json_missing"
    assert loaded["guidance"]
    assert bench.BENCH_JSON_ENV in loaded["guidance"]


def test_load_bench_invalid_json(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    path = tmp_path / "bench.json"
    path.write_text("{not json", encoding="utf-8")
    monkeypatch.setenv(bench.BENCH_JSON_ENV, str(path))

    loaded = bench.load_bench()

    assert loaded["ok"] is False
    assert loaded["error"] == "bench_json_invalid"


def test_load_bench_stale_when_older_than_14_days(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    path = _write_bench(tmp_path, _bench_payload(_iso(days_ago=30)))
    monkeypatch.setenv(bench.BENCH_JSON_ENV, str(path))

    loaded = bench.load_bench()

    assert loaded["ok"] is True
    assert loaded["stale"] is True
    assert loaded["ageDays"] > 14
    assert any("stale" in warning for warning in loaded["warnings"])


def test_load_bench_fresh_and_cached_by_mtime(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    path = _write_bench(tmp_path, _bench_payload(_iso()))
    monkeypatch.setenv(bench.BENCH_JSON_ENV, str(path))

    first = bench.load_bench()
    second = bench.load_bench()

    assert first["ok"] is True
    assert first["stale"] is False
    assert first["cacheHit"] is False
    assert second["cacheHit"] is True


def test_load_bench_missing_timestamp_is_stale(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    payload = _bench_payload(_iso())
    payload["generated_at_utc"] = None
    path = _write_bench(tmp_path, payload)
    monkeypatch.setenv(bench.BENCH_JSON_ENV, str(path))

    loaded = bench.load_bench()

    assert loaded["ok"] is True
    assert loaded["stale"] is True


# ---------------------------------------------------------------------------
# recommend: disclosure rules and constraints
# ---------------------------------------------------------------------------


def _recommend(tmp_path: Path, monkeypatch: pytest.MonkeyPatch, intent: dict, constraints: dict | None = None) -> dict:
    path = _write_bench(tmp_path, _bench_payload(_iso()))
    monkeypatch.setenv(bench.BENCH_JSON_ENV, str(path))
    return bench.recommend(intent, constraints)


def test_recommend_low_n_never_ranked_first(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    result = _recommend(tmp_path, monkeypatch, {"family": "refactor", "language": "python"})

    assert result["ok"] is True
    recs = result["data"]["recommendations"]
    assert recs[0]["model"] == "model-beta"  # 0.70 measured, n=40
    gamma = next(rec for rec in recs if rec["model"] == "model-gamma")
    assert gamma["solution_rate"] == 0.95  # highest raw rate…
    assert gamma["rank"] > 1  # …but n=5 ⇒ low confidence ⇒ never first
    assert gamma["confidence"] == "low"
    assert gamma["disclosure"]["low_n"] is True
    assert any("ranked first" in label for label in gamma["disclosure"]["labels"])


def test_recommend_respects_min_confidence(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    result = _recommend(tmp_path, monkeypatch, {"family": "refactor"}, {"min_confidence": "high"})

    assert result["ok"] is True
    recs = result["data"]["recommendations"]
    assert recs
    assert all(rec["confidence"] == "high" for rec in recs)
    assert {rec["model"] for rec in recs} == {"model-alpha", "model-beta"}
    assert result["data"]["filtered"]["confidence"] >= 1


def test_recommend_rejects_unknown_min_confidence(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    result = _recommend(tmp_path, monkeypatch, {"family": "refactor"}, {"min_confidence": "ultra"})

    assert result["ok"] is False
    assert "min_confidence" in result["error"]


def test_recommend_inferred_is_labeled_not_measured(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    result = _recommend(tmp_path, monkeypatch, {"family": "bugfix", "language": "python"})

    assert result["ok"] is True
    recs = result["data"]["recommendations"]
    beta = next(rec for rec in recs if rec["model"] == "model-beta")
    assert beta["evidence"] == "inferred"
    assert beta["disclosure"]["inferred"] is True
    assert any("shrinkage-pooled" in label for label in beta["disclosure"]["labels"])


def test_recommend_max_cost_constraint(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    result = _recommend(tmp_path, monkeypatch, {"family": "refactor"}, {"max_cost_usd": 2.5})

    assert result["ok"] is True
    recs = result["data"]["recommendations"]
    assert all((rec["cost_usd_median"] or 0) <= 2.5 for rec in recs)
    assert result["data"]["filtered"]["cost"] >= 1
    # model-beta's refactor row ($3.00) is filtered; the pairing may still
    # appear via its cheaper overall-scope row ($2.00).
    beta = next((rec for rec in recs if rec["model"] == "model-beta"), None)
    if beta is not None:
        assert beta["scope"].get("family") == "overall"
        assert beta["cost_usd_median"] == 2.0


def test_recommend_missing_bench_returns_envelope_error(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv(bench.BENCH_JSON_ENV, str(tmp_path / "absent.json"))

    result = bench.recommend({"family": "refactor"})

    assert result["ok"] is False
    assert result["data"] is None
    assert result["error"] == "bench_json_missing"
    assert result["evidence"]["guidance"]


# ---------------------------------------------------------------------------
# compare / profiles / frontier / explain / status
# ---------------------------------------------------------------------------


def _use_fresh_bench(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    path = _write_bench(tmp_path, _bench_payload(_iso()))
    monkeypatch.setenv(bench.BENCH_JSON_ENV, str(path))


def test_compare_picks_higher_rate_and_flags_ci(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    _use_fresh_bench(tmp_path, monkeypatch)

    result = bench.compare(
        {"harness": "droid", "model": "model-alpha", "scope": {"family": "refactor"}},
        {"harness": "droid", "model": "model-beta", "scope": {"family": "refactor"}},
    )

    assert result["ok"] is True
    verdict = result["data"]["verdict"]
    assert verdict["solution_rate"]["winner"] == "b"
    assert verdict["solution_rate"]["delta"] == pytest.approx(-0.30, abs=1e-3)
    assert verdict["solution_rate"]["ci_overlap"] is False
    assert verdict["cost_usd_median"]["winner"] == "a"


def test_compare_notes_overlapping_cis(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    payload = _bench_payload(_iso())
    payload["stacks"][1]["ci95"] = [0.50, 0.82]  # overlaps alpha's [0.24, 0.54]
    path = _write_bench(tmp_path, payload)
    monkeypatch.setenv(bench.BENCH_JSON_ENV, str(path))

    result = bench.compare({"harness": "droid", "model": "model-alpha"}, {"harness": "droid", "model": "model-beta"})

    assert result["ok"] is True
    assert result["data"]["verdict"]["solution_rate"]["ci_overlap"] is True
    assert "not statistically significant" in result["data"]["verdict"]["note"]


def test_compare_missing_stack_is_envelope_error(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    _use_fresh_bench(tmp_path, monkeypatch)

    result = bench.compare({"harness": "droid", "model": "nope"}, {"harness": "droid", "model": "model-beta"})

    assert result["ok"] is False
    assert "stack_not_found" in result["error"]


def test_model_profile_aggregates_stacks_and_arena(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    _use_fresh_bench(tmp_path, monkeypatch)

    result = bench.model_profile("model-beta")

    assert result["ok"] is True
    data = result["data"]
    assert data["model"]["provider"] == "p2"
    assert data["stack_count"] == 4
    assert set(data["by_harness"]) == {"droid", "codex"}
    assert data["arena"]["votes"] == 3
    assert len(data["arena"]["ratings"]) == 1


def test_model_profile_unknown_lists_available(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    _use_fresh_bench(tmp_path, monkeypatch)

    result = bench.model_profile("model-nope")

    assert result["ok"] is False
    assert "model_not_found" in result["error"]
    assert "model-alpha" in result["evidence"]["available_models"]


def test_harness_profile_groups_by_model(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    _use_fresh_bench(tmp_path, monkeypatch)

    result = bench.harness_profile("codex")

    assert result["ok"] is True
    assert result["data"]["stack_count"] == 2
    assert set(result["data"]["by_model"]) == {"model-alpha", "model-beta"}


def test_frontier_resolves_confidence_from_stacks(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    _use_fresh_bench(tmp_path, monkeypatch)

    result = bench.frontier({"family": "refactor"})

    assert result["ok"] is True
    entries = result["data"]["frontier"]
    assert len(entries) == 1  # overall-scope frontier row still applies to a family query
    assert entries[0]["model"] == "model-beta"
    assert entries[0]["confidence"] == "high"
    assert entries[0]["evidence"] == "measured"


def test_explain_reports_rank_disclosure_and_frontier(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    _use_fresh_bench(tmp_path, monkeypatch)

    result = bench.explain({"harness": "droid", "model": "model-beta", "scope": {"family": "refactor"}})

    assert result["ok"] is True
    data = result["data"]
    # model-gamma (0.95, n=5) outranks on raw rate; disclosure keeps it from top picks elsewhere.
    assert data["rank_in_scope"] == 2
    assert data["scope_size"] == 4
    assert data["on_frontier"] is True
    assert any("ranked 2 of 4" in line for line in data["rationale"])


def test_explain_unknown_stack(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    _use_fresh_bench(tmp_path, monkeypatch)

    result = bench.explain({"harness": "droid", "model": "model-nope"})

    assert result["ok"] is False
    assert "stack_not_found" in result["error"]


def test_status_reports_freshness_cells_and_votes(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    _use_fresh_bench(tmp_path, monkeypatch)

    result = bench.status()

    assert result["ok"] is True
    data = result["data"]
    assert data["stale"] is False
    assert data["cells"] == 8
    assert data["models"] == 3
    assert data["harnesses"] == 2
    assert data["low_confidence_cells"] == 2
    assert data["inferred_cells"] == 1
    assert data["measured_cells"] == 7
    assert data["arena"] == {"votes": 3, "ratings": 1}


# ---------------------------------------------------------------------------
# server.py bench_* tools: contract §4 envelope over the MCP boundary
# ---------------------------------------------------------------------------


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

    spec = importlib.util.spec_from_file_location("openburnbar_mcp_server_bench_test", str(_PARENT / "server.py"))
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules["openburnbar_mcp_server_bench_test"] = module
    spec.loader.exec_module(module)  # type: ignore[union-attr]
    return module


def _assert_envelope(payload: dict) -> None:
    assert {"ok", "data", "evidence", "error"} <= set(payload)


def test_bench_tools_return_contract_envelopes(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    _use_fresh_bench(tmp_path, monkeypatch)
    server = _load_server()

    calls = [
        server.bench_status(),
        server.bench_recommend_stack('{"family": "refactor", "language": "python"}', '{"min_confidence": "high"}'),
        server.bench_compare_stacks(
            '{"harness": "droid", "model": "model-alpha"}', '{"harness": "droid", "model": "model-beta"}'
        ),
        server.bench_model_profile("model-beta"),
        server.bench_harness_profile("droid"),
        server.bench_frontier('{"family": "refactor"}'),
        server.bench_explain('{"harness": "droid", "model": "model-beta"}'),
    ]
    for raw in calls:
        payload = json.loads(raw)
        _assert_envelope(payload)
        assert payload["ok"] is True, raw
        assert payload["error"] is None

    status = json.loads(calls[0])
    assert status["data"]["cells"] == 8
    recommend = json.loads(calls[1])
    assert recommend["data"]["recommendations"][0]["model"] == "model-beta"


def test_bench_tools_envelope_when_bench_missing(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv(bench.BENCH_JSON_ENV, str(tmp_path / "absent.json"))
    server = _load_server()

    for raw in (
        server.bench_status(),
        server.bench_recommend_stack('{"family": "refactor"}', None),
        server.bench_model_profile("model-beta"),
        server.bench_harness_profile("droid"),
        server.bench_frontier(None),
        server.bench_explain('{"harness": "droid", "model": "model-beta"}'),
    ):
        payload = json.loads(raw)
        _assert_envelope(payload)
        assert payload["ok"] is False
        assert payload["error"] == "bench_json_missing"


def test_bench_tools_tolerate_malformed_json_args(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    _use_fresh_bench(tmp_path, monkeypatch)
    server = _load_server()

    payload = json.loads(server.bench_recommend_stack("{not json", "[1, 2]"))

    _assert_envelope(payload)
    assert payload["ok"] is True  # malformed args fall back to empty intent/constraints


# ---------------------------------------------------------------------------
# ministry.py tie-break: identical behavior without fresh evidence, optional
# reorder with it
# ---------------------------------------------------------------------------


def _wand_store(tmp_path: Path) -> Path:
    store = tmp_path / "wands.v1.json"
    store.write_text(
        json.dumps(
            {
                "wands": [
                    {
                        "id": "headmaster",
                        "name": "Headmaster's Wand",
                        "selector": "best",
                        "constraints": {"minCapabilityRank": 10},
                        "autonomy": "medium",
                        "allowBackends": ["direct"],
                        "isDefault": True,
                    }
                ]
            }
        ),
        encoding="utf-8",
    )
    return store


def _tied_candidates() -> list[dict]:
    # Equal (quota tier, capability rank, price): baseline order falls to arg,
    # so "alpha" outranks "beta" before any bench evidence is considered.
    return [
        {
            "arg": "alpha",
            "model": "model-alpha",
            "provider": "p1",
            "backend": "direct",
            "capabilityClassRank": 100,
            "price": 1.0,
            "costUnknown": False,
            "quota": {"state": "unknown"},
        },
        {
            "arg": "beta",
            "model": "model-beta",
            "provider": "p2",
            "backend": "direct",
            "capabilityClassRank": 100,
            "price": 1.0,
            "costUnknown": False,
            "quota": {"state": "unknown"},
        },
    ]


def _stub_launchable(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(
        ministry,
        "list_launchable",
        lambda include_quota=True: {"candidates": _tied_candidates()},
    )


def test_ministry_tiebreak_engages_with_fresh_bench(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    _use_fresh_bench(tmp_path, monkeypatch)
    _stub_launchable(monkeypatch)
    store = _wand_store(tmp_path)

    result = ministry.select_model_for_wand(store, mission_family="refactor")

    assert result["selected"]["arg"] == "beta"  # 0.70 > 0.40 in bench.json
    assert result["benchTieBreak"]["applied"] is True
    assert result["benchTieBreak"]["family"] == "refactor"


def test_ministry_tiebreak_falls_back_to_overall_scope_without_family(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _use_fresh_bench(tmp_path, monkeypatch)
    _stub_launchable(monkeypatch)
    store = _wand_store(tmp_path)

    result = ministry.select_model_for_wand(store)

    assert result["selected"]["arg"] == "beta"  # overall rows: 0.55 > 0.45
    assert result["benchTieBreak"]["applied"] is True


def test_ministry_selection_identical_when_bench_stale(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    stale_path = _write_bench(tmp_path, _bench_payload(_iso(days_ago=30)))
    _stub_launchable(monkeypatch)
    store = _wand_store(tmp_path)

    monkeypatch.setenv(bench.BENCH_JSON_ENV, str(stale_path))
    with_stale = ministry.select_model_for_wand(store, mission_family="refactor")

    bench.reset_cache()
    monkeypatch.setenv(bench.BENCH_JSON_ENV, str(tmp_path / "absent.json"))
    without_bench = ministry.select_model_for_wand(store, mission_family="refactor")

    assert with_stale["selected"]["arg"] == "alpha"
    assert without_bench["selected"]["arg"] == "alpha"
    assert with_stale["selected"] == without_bench["selected"]
    assert "benchTieBreak" not in with_stale
    assert "benchTieBreak" not in without_bench


def test_ministry_selection_identical_when_bench_unparseable(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    broken = tmp_path / "bench.json"
    broken.write_text("{not json", encoding="utf-8")
    monkeypatch.setenv(bench.BENCH_JSON_ENV, str(broken))
    _stub_launchable(monkeypatch)
    store = _wand_store(tmp_path)

    result = ministry.select_model_for_wand(store, mission_family="refactor")

    assert result["selected"]["arg"] == "alpha"
    assert "benchTieBreak" not in result


def test_ministry_tiebreak_ignores_low_n_evidence(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    payload = _bench_payload(_iso())
    # beta's only refactor row becomes low-powered; its 0.95 must not promote it.
    payload["stacks"] = [
        _stack("droid", "model-alpha", "refactor", 40, 0.40),
        _stack("droid", "model-beta", "refactor", 5, 0.95),
    ]
    path = _write_bench(tmp_path, payload)
    monkeypatch.setenv(bench.BENCH_JSON_ENV, str(path))
    _stub_launchable(monkeypatch)
    store = _wand_store(tmp_path)

    result = ministry.select_model_for_wand(store, mission_family="refactor")

    assert result["selected"]["arg"] == "alpha"


def test_ministry_select_models_tiebreak_orders_fanout(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    _use_fresh_bench(tmp_path, monkeypatch)
    _stub_launchable(monkeypatch)
    store = _wand_store(tmp_path)
    monkeypatch.setenv("OPENBURNBAR_WAND_PARALLEL_MAX", "2")

    result = ministry.select_models_for_wand(
        store, count=2, require_provider_diversity=False, mission_family="refactor"
    )

    assert [candidate["arg"] for candidate in result["selected"]] == ["beta", "alpha"]
    assert result["benchTieBreak"]["applied"] is True
