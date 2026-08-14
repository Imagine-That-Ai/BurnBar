#!/usr/bin/env python3
"""BurnBench evidence reader for the local MCP server and the Ministry.

This module is intentionally stdlib-only (mirrors ministry.py) so the local MCP
server can expose benchmark evidence without adding runtime dependencies.

It reads bench.json — the evidence export described in
recommendation-platform-contracts §3 — with mtime-based caching and a 14-day
staleness check, and enforces the contract's disclosure rules on every read:

- ``n < 10`` ⇒ the stack is treated as low confidence and may not be ranked
  first in recommendations, regardless of the producer-declared confidence.
- ``evidence: inferred`` rows are always labeled as shrinkage-pooled estimates
  and never presented as measured.

Every public query helper returns the contract §4 envelope:
``{"ok": bool, "data": ..., "evidence": {...}, "error": str|None}``.
"""

from __future__ import annotations

import json
import os
import re
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

_THIS_DIR = Path(__file__).resolve().parent
REPO_ROOT = _THIS_DIR.parent.parent
BENCH_JSON_PATH = REPO_ROOT / "website" / "public" / "data" / "bench.json"
BENCH_JSON_ENV = "BURNBENCH_BENCH_JSON"
STALE_AFTER_DAYS = 14
LOW_N_THRESHOLD = 10
CONFIDENCE_RANK = {"low": 0, "medium": 1, "high": 2}
SCHEMA_VERSION = 1

_BENCH_CACHE: dict[str, Any] = {"path": None, "mtime_ns": None, "payload": None}


def utc_now() -> str:
    return datetime.now(UTC).isoformat().replace("+00:00", "Z")


def json_dumps(payload: Any) -> str:
    return json.dumps(payload, indent=2, default=str, sort_keys=True)


def normalize_key(value: Any) -> str:
    raw = str(value or "").strip().lower()
    raw = re.sub(r"[^a-z0-9]+", "-", raw)
    return re.sub(r"-+", "-", raw).strip("-")


def _read_json_file(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as fh:
        return json.load(fh)


def _coerce_float(value: Any) -> float | None:
    if value is None:
        return None
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    if number < 0:
        return None
    return number


def _coerce_rate(value: Any) -> float | None:
    number = _coerce_float(value)
    if number is None or number > 1:
        return None
    return number


def _coerce_int(value: Any) -> int | None:
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def bench_json_path() -> Path:
    override = os.environ.get(BENCH_JSON_ENV, "").strip()
    if override:
        return Path(override).expanduser().resolve()
    return BENCH_JSON_PATH


def reset_cache() -> None:
    """Drop the mtime cache. Intended for tests and long-lived processes."""
    _BENCH_CACHE.update({"path": None, "mtime_ns": None, "payload": None})


def _parse_iso8601(value: Any) -> datetime | None:
    if not isinstance(value, str) or not value.strip():
        return None
    try:
        parsed = datetime.fromisoformat(value.strip().replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=UTC)
    return parsed


def load_bench(path: Path | None = None) -> dict[str, Any]:
    """Load bench.json with mtime-based caching and the 14-day staleness check.

    Returns ``ok: False`` with operator guidance when the file is missing or
    unparseable; otherwise ``ok: True`` with ``stale: True`` and a warning when
    ``generated_at_utc`` is missing, unparseable, or older than 14 days.
    """
    bench_path = path or bench_json_path()
    try:
        stat = bench_path.stat()
    except OSError:
        return {
            "ok": False,
            "path": str(bench_path),
            "stale": False,
            "generatedAtUtc": None,
            "ageDays": None,
            "warnings": [],
            "bench": None,
            "error": "bench_json_missing",
            "guidance": (
                "bench.json not found. Run the BurnBench pipeline to produce site/bench.json, "
                f"then copy it to {BENCH_JSON_PATH} (or point {BENCH_JSON_ENV} at an existing export)."
            ),
            "cacheHit": False,
        }
    if (
        _BENCH_CACHE["payload"] is not None
        and _BENCH_CACHE["path"] == str(bench_path)
        and _BENCH_CACHE["mtime_ns"] == stat.st_mtime_ns
    ):
        cached = dict(_BENCH_CACHE["payload"])
        cached["cacheHit"] = True
        return cached

    try:
        raw = _read_json_file(bench_path)
    except json.JSONDecodeError as exc:
        return {
            "ok": False,
            "path": str(bench_path),
            "stale": False,
            "generatedAtUtc": None,
            "ageDays": None,
            "warnings": [],
            "bench": None,
            "error": "bench_json_invalid",
            "guidance": f"bench.json is not valid JSON: {exc}",
            "cacheHit": False,
        }
    except OSError as exc:
        return {
            "ok": False,
            "path": str(bench_path),
            "stale": False,
            "generatedAtUtc": None,
            "ageDays": None,
            "warnings": [],
            "bench": None,
            "error": "bench_json_unreadable",
            "guidance": f"bench.json could not be read: {exc}",
            "cacheHit": False,
        }
    if not isinstance(raw, dict):
        return {
            "ok": False,
            "path": str(bench_path),
            "stale": False,
            "generatedAtUtc": None,
            "ageDays": None,
            "warnings": [],
            "bench": None,
            "error": "bench_json_invalid",
            "guidance": "bench.json must be a JSON object per recommendation-platform-contracts §3.",
            "cacheHit": False,
        }

    warnings: list[str] = []
    if raw.get("schema_version") != SCHEMA_VERSION:
        warnings.append(
            f"schema_version {raw.get('schema_version')!r} is not the supported {SCHEMA_VERSION}; reading defensively"
        )
    generated = raw.get("generated_at_utc")
    parsed = _parse_iso8601(generated)
    age_days: float | None = None
    stale = False
    if parsed is None:
        stale = True
        warnings.append("generated_at_utc missing or unparseable; treating bench.json as stale")
    else:
        age_days = (datetime.now(UTC) - parsed).total_seconds() / 86400.0
        if age_days > STALE_AFTER_DAYS:
            stale = True
            warnings.append(
                f"bench.json is stale: generated {age_days:.1f} days ago (> {STALE_AFTER_DAYS} days); "
                "re-run the BurnBench pipeline to refresh"
            )
        elif age_days < -1:
            warnings.append("generated_at_utc is in the future; check producer clock")

    payload = {
        "ok": True,
        "path": str(bench_path),
        "stale": stale,
        "generatedAtUtc": generated if isinstance(generated, str) else None,
        "ageDays": round(age_days, 3) if age_days is not None else None,
        "warnings": warnings,
        "bench": raw,
        "error": None,
        "cacheHit": False,
    }
    _BENCH_CACHE.update({"path": str(bench_path), "mtime_ns": stat.st_mtime_ns, "payload": payload})
    return dict(payload)


# ---------------------------------------------------------------------------
# Disclosure rules (contract §3): n < 10 ⇒ low confidence, never ranked first;
# inferred rows are always labeled as shrinkage-pooled estimates.
# ---------------------------------------------------------------------------


def _stack_disclosure(stack: dict[str, Any]) -> dict[str, Any]:
    n = _coerce_int(stack.get("n")) or 0
    declared = normalize_key(stack.get("confidence"))
    if declared not in CONFIDENCE_RANK:
        declared = "low"
    low_n = n < LOW_N_THRESHOLD
    effective = "low" if low_n else declared
    inferred = normalize_key(stack.get("evidence")) == "inferred"
    labels: list[str] = []
    if low_n:
        labels.append(f"low confidence: n={n} < {LOW_N_THRESHOLD}; not eligible to be ranked first")
    if inferred:
        labels.append("inferred estimate: shrinkage-pooled, not measured")
    return {
        "n": n,
        "declared_confidence": declared,
        "effective_confidence": effective,
        "low_n": low_n,
        "inferred": inferred,
        "labels": labels,
    }


def _envelope(ok: bool, data: Any, evidence: dict[str, Any], error: str | None) -> dict[str, Any]:
    return {"ok": ok, "data": data, "evidence": evidence, "error": error}


def _evidence_meta(loaded: dict[str, Any]) -> dict[str, Any]:
    bench = loaded.get("bench") or {}
    return {
        "path": loaded.get("path"),
        "generated_at_utc": loaded.get("generatedAtUtc"),
        "age_days": loaded.get("ageDays"),
        "stale": bool(loaded.get("stale")),
        "warnings": list(loaded.get("warnings") or []),
        "cells": len(bench.get("stacks") or []),
    }


def _load_error_envelope(loaded: dict[str, Any]) -> dict[str, Any]:
    return _envelope(
        False,
        None,
        {
            "path": loaded.get("path"),
            "stale": bool(loaded.get("stale")),
            "guidance": loaded.get("guidance"),
        },
        str(loaded.get("error") or "bench_json_unavailable"),
    )


def _scope_score(scope: dict[str, Any], intent: dict[str, Any]) -> int | None:
    """Specificity score when a stack scope is compatible with the intent.

    Returns None when the scope names a concrete value the intent contradicts.
    Wildcard/absent scope values (null, "overall") still match but score lower
    than an exact match.
    """
    score = 0
    for key in ("family", "language", "platform", "framework"):
        want = normalize_key(intent.get(key))
        if not want:
            continue
        got = normalize_key(scope.get(key))
        if got in {"", "overall", "any", "all"}:
            score += 1
            continue
        if got != want:
            return None
        score += 2
    return score


def _public_stack(stack: dict[str, Any], disclosure: dict[str, Any]) -> dict[str, Any]:
    return {
        "harness": stack.get("harness"),
        "model": stack.get("model"),
        "config": stack.get("config"),
        "scope": stack.get("scope") or {},
        "n": disclosure["n"],
        "strict_rate": _coerce_rate(stack.get("strict_rate")),
        "solution_rate": _coerce_rate(stack.get("solution_rate")),
        "ci95": stack.get("ci95"),
        "cost_usd_median": _coerce_float(stack.get("cost_usd_median")),
        "wall_seconds_median": _coerce_float(stack.get("wall_seconds_median")),
        "tokens_median": _coerce_int(stack.get("tokens_median")),
        "arena_bt": _coerce_float(stack.get("arena_bt")),
        "confidence": disclosure["effective_confidence"],
        "evidence": "inferred" if disclosure["inferred"] else "measured",
        "disclosure": disclosure,
    }


def _rationale(stack: dict[str, Any], disclosure: dict[str, Any]) -> str:
    rate = _coerce_rate(stack.get("solution_rate"))
    ci = stack.get("ci95") if isinstance(stack.get("ci95"), list) else None
    ci_text = ""
    if ci and len(ci) == 2 and all(isinstance(v, (int, float)) for v in ci):
        ci_text = f", 95% CI [{ci[0]:.2f}, {ci[1]:.2f}]"
    scope = stack.get("scope") or {}
    family = scope.get("family") or "overall"
    cost = _coerce_float(stack.get("cost_usd_median"))
    wall = _coerce_float(stack.get("wall_seconds_median"))
    parts = [
        f"solution_rate {rate:.2f}{ci_text} over n={disclosure['n']} {family} cells"
        if rate is not None
        else f"no measured solution_rate over n={disclosure['n']} {family} cells"
    ]
    if cost is not None:
        parts.append(f"median cost ${cost:.2f}")
    if wall is not None:
        parts.append(f"median wall {wall:.0f}s")
    parts.extend(disclosure["labels"])
    return "; ".join(parts)


def recommend(intent: dict[str, Any] | None, constraints: dict[str, Any] | None = None) -> dict[str, Any]:
    """Rank harness+model stacks for an intent under optional constraints.

    intent keys: family, language, framework, platform, tags, free_text.
    constraints keys: max_cost_usd, max_wall_seconds, min_confidence.
    Low-confidence stacks (n < 10 or declared low) are never ranked first.
    """
    loaded = load_bench()
    if not loaded["ok"]:
        return _load_error_envelope(loaded)
    bench = loaded["bench"]
    intent = dict(intent) if isinstance(intent, dict) else {}
    constraints = dict(constraints) if isinstance(constraints, dict) else {}

    min_confidence = normalize_key(constraints.get("min_confidence"))
    if min_confidence and min_confidence not in CONFIDENCE_RANK:
        return _envelope(
            False,
            None,
            _evidence_meta(loaded),
            f"min_confidence must be one of {sorted(CONFIDENCE_RANK)}",
        )
    max_cost = _coerce_float(constraints.get("max_cost_usd"))
    max_wall = _coerce_float(constraints.get("max_wall_seconds"))

    filtered = {"confidence": 0, "cost": 0, "wall": 0, "scope": 0}
    best_by_pairing: dict[tuple[str, str, str], tuple[int, int, dict[str, Any], dict[str, Any]]] = {}
    for stack in bench.get("stacks") or []:
        if not isinstance(stack, dict):
            continue
        disclosure = _stack_disclosure(stack)
        if min_confidence and CONFIDENCE_RANK[disclosure["effective_confidence"]] < CONFIDENCE_RANK[min_confidence]:
            filtered["confidence"] += 1
            continue
        cost = _coerce_float(stack.get("cost_usd_median"))
        if max_cost is not None and cost is not None and cost > max_cost:
            filtered["cost"] += 1
            continue
        wall = _coerce_float(stack.get("wall_seconds_median"))
        if max_wall is not None and wall is not None and wall > max_wall:
            filtered["wall"] += 1
            continue
        score = _scope_score(stack.get("scope") or {}, intent)
        if score is None:
            filtered["scope"] += 1
            continue
        key = (
            str(stack.get("harness") or ""),
            str(stack.get("model") or ""),
            str(stack.get("config") or ""),
        )
        # One row per pairing: prefer the most specific scope, then the largest n.
        candidate = (score, disclosure["n"], stack, disclosure)
        current = best_by_pairing.get(key)
        if current is None or (candidate[0], candidate[1]) > (current[0], current[1]):
            best_by_pairing[key] = candidate

    def rank_key(item: tuple[int, int, dict[str, Any], dict[str, Any]]) -> tuple[Any, ...]:
        score, _n, stack, disclosure = item
        rate = _coerce_rate(stack.get("solution_rate"))
        strict = _coerce_rate(stack.get("strict_rate"))
        cost = _coerce_float(stack.get("cost_usd_median"))
        wall = _coerce_float(stack.get("wall_seconds_median"))
        return (
            1 if disclosure["effective_confidence"] == "low" else 0,  # low-n/low-confidence never first
            -(rate if rate is not None else -1.0),
            -score,
            -(strict if strict is not None else -1.0),
            cost if cost is not None else float("inf"),
            wall if wall is not None else float("inf"),
            str(stack.get("harness") or ""),
            str(stack.get("model") or ""),
        )

    ranked = sorted(best_by_pairing.values(), key=rank_key)
    recommendations = []
    for index, (_score, _n, stack, disclosure) in enumerate(ranked):
        row = _public_stack(stack, disclosure)
        row["rank"] = index + 1
        row["rationale"] = _rationale(stack, disclosure)
        recommendations.append(row)

    data: dict[str, Any] = {
        "recommendations": recommendations,
        "intent": intent,
        "constraints": constraints,
        "considered": len(bench.get("stacks") or []),
        "filtered": filtered,
    }
    if recommendations and recommendations[0]["confidence"] == "low":
        data["note"] = (
            "only low-confidence evidence matches this intent; no stack may be presented as a top pick "
            "until more cells are measured"
        )
    return _envelope(True, data, _evidence_meta(loaded), None)


def _match_rows(bench: dict[str, Any], field: str, name: str) -> list[dict[str, Any]]:
    key = normalize_key(name)
    if not key:
        return []
    rows = []
    for stack in bench.get("stacks") or []:
        if isinstance(stack, dict) and normalize_key(stack.get(field)) == key:
            rows.append(stack)
    return rows


def _arena_ratings_for(bench: dict[str, Any], field: str, name: str) -> list[dict[str, Any]]:
    key = normalize_key(name)
    arena = bench.get("arena") or {}
    ratings = []
    for rating in arena.get("ratings") or []:
        if isinstance(rating, dict) and normalize_key(rating.get(field)) == key:
            ratings.append(rating)
    return ratings


def model_profile(name: str) -> dict[str, Any]:
    """Aggregate every measured/inferred stack row for one model."""
    loaded = load_bench()
    if not loaded["ok"]:
        return _load_error_envelope(loaded)
    bench = loaded["bench"]
    key = normalize_key(name)
    model_row = None
    for row in bench.get("models") or []:
        if not isinstance(row, dict):
            continue
        if key in {normalize_key(row.get("id")), normalize_key(row.get("display"))}:
            model_row = row
            break
    rows = _match_rows(bench, "model", name)
    if model_row is None and not rows:
        available = sorted(
            {str(row.get("id")) for row in bench.get("models") or [] if isinstance(row, dict) and row.get("id")}
        )
        return _envelope(
            False,
            None,
            {**_evidence_meta(loaded), "available_models": available},
            f"model_not_found: {name}",
        )
    stacks = [_public_stack(stack, _stack_disclosure(stack)) for stack in rows]
    stacks.sort(key=lambda row: (-(row["solution_rate"] or -1.0), str(row["harness"])))
    by_harness: dict[str, list[dict[str, Any]]] = {}
    for row in stacks:
        by_harness.setdefault(str(row["harness"]), []).append(row)
    data = {
        "model": model_row or {"id": name},
        "stack_count": len(stacks),
        "by_harness": by_harness,
        "stacks": stacks,
        "arena": {
            "votes": int((bench.get("arena") or {}).get("votes") or 0),
            "ratings": _arena_ratings_for(bench, "model", name),
        },
    }
    return _envelope(True, data, _evidence_meta(loaded), None)


def harness_profile(name: str) -> dict[str, Any]:
    """Aggregate every measured/inferred stack row for one harness."""
    loaded = load_bench()
    if not loaded["ok"]:
        return _load_error_envelope(loaded)
    bench = loaded["bench"]
    key = normalize_key(name)
    harness_row = None
    for row in bench.get("harnesses") or []:
        if not isinstance(row, dict):
            continue
        if key in {normalize_key(row.get("id")), normalize_key(row.get("display"))}:
            harness_row = row
            break
    rows = _match_rows(bench, "harness", name)
    if harness_row is None and not rows:
        available = sorted(
            {str(row.get("id")) for row in bench.get("harnesses") or [] if isinstance(row, dict) and row.get("id")}
        )
        return _envelope(
            False,
            None,
            {**_evidence_meta(loaded), "available_harnesses": available},
            f"harness_not_found: {name}",
        )
    stacks = [_public_stack(stack, _stack_disclosure(stack)) for stack in rows]
    stacks.sort(key=lambda row: (-(row["solution_rate"] or -1.0), str(row["model"])))
    by_model: dict[str, list[dict[str, Any]]] = {}
    for row in stacks:
        by_model.setdefault(str(row["model"]), []).append(row)
    data = {
        "harness": harness_row or {"id": name},
        "stack_count": len(stacks),
        "by_model": by_model,
        "stacks": stacks,
        "arena": {
            "votes": int((bench.get("arena") or {}).get("votes") or 0),
            "ratings": _arena_ratings_for(bench, "harness", name),
        },
    }
    return _envelope(True, data, _evidence_meta(loaded), None)


def frontier(scope: dict[str, Any] | None = None) -> dict[str, Any]:
    """Return the cost/performance frontier, optionally narrowed by scope."""
    loaded = load_bench()
    if not loaded["ok"]:
        return _load_error_envelope(loaded)
    bench = loaded["bench"]
    scope = dict(scope) if isinstance(scope, dict) else {}
    entries = []
    for entry in bench.get("frontier") or []:
        if not isinstance(entry, dict):
            continue
        if scope and _scope_score(entry.get("scope") or {}, scope) is None:
            continue
        row = dict(entry)
        match = _resolve_stack(
            bench, {"harness": entry.get("harness"), "model": entry.get("model"), "scope": entry.get("scope")}
        )
        if match is not None:
            stack, disclosure = match
            row["confidence"] = disclosure["effective_confidence"]
            row["evidence"] = "inferred" if disclosure["inferred"] else "measured"
            row["n"] = disclosure["n"]
            row["disclosure"] = disclosure
        entries.append(row)
    entries.sort(
        key=lambda row: (
            -(_coerce_rate(row.get("solution_rate")) or -1.0),
            _coerce_float(row.get("cost_usd_median"))
            if _coerce_float(row.get("cost_usd_median")) is not None
            else float("inf"),
            str(row.get("harness") or ""),
            str(row.get("model") or ""),
        )
    )
    data = {"frontier": entries, "scope": scope, "count": len(entries)}
    return _envelope(True, data, _evidence_meta(loaded), None)


def _resolve_stack(bench: dict[str, Any], spec: dict[str, Any]) -> tuple[dict[str, Any], dict[str, Any]] | None:
    """Find the best stack row for a {harness, model, scope?} spec.

    Prefers the row whose scope best matches the requested scope, then the
    overall-scope row, then the largest-n row.
    """
    rows = _match_rows(bench, "harness", str(spec.get("harness") or ""))
    model_key = normalize_key(spec.get("model"))
    rows = [row for row in rows if normalize_key(row.get("model")) == model_key]
    if not rows:
        return None
    requested_scope = spec.get("scope") if isinstance(spec.get("scope"), dict) else {}

    def row_key(row: dict[str, Any]) -> tuple[int, int]:
        scope = row.get("scope") or {}
        if requested_scope:
            score = _scope_score(scope, requested_scope)
            if score is None:
                return (-1, 0)
            return (score, _coerce_int(row.get("n")) or 0)
        family = normalize_key(scope.get("family"))
        return (1 if family in {"", "overall"} else 0, _coerce_int(row.get("n")) or 0)

    scored = [(row_key(row), row) for row in rows]
    scored = [item for item in scored if item[0][0] >= 0]
    if not scored:
        return None
    scored.sort(key=lambda item: item[0], reverse=True)
    best = scored[0][1]
    return best, _stack_disclosure(best)


def _ci_overlap(a: Any, b: Any) -> bool | None:
    if not (isinstance(a, list) and isinstance(b, list) and len(a) == 2 and len(b) == 2):
        return None
    if not all(isinstance(v, (int, float)) for v in (*a, *b)):
        return None
    return bool(a[0] <= b[1] and b[0] <= a[1])


def compare(a: dict[str, Any], b: dict[str, Any]) -> dict[str, Any]:
    """Compare two {harness, model, scope?} stacks on rate, cost, and wall time."""
    loaded = load_bench()
    if not loaded["ok"]:
        return _load_error_envelope(loaded)
    bench = loaded["bench"]
    a = dict(a) if isinstance(a, dict) else {}
    b = dict(b) if isinstance(b, dict) else {}
    resolved_a = _resolve_stack(bench, a)
    resolved_b = _resolve_stack(bench, b)
    missing = []
    if resolved_a is None:
        missing.append(f"a={a.get('harness')}/{a.get('model')}")
    if resolved_b is None:
        missing.append(f"b={b.get('harness')}/{b.get('model')}")
    if missing:
        return _envelope(False, None, _evidence_meta(loaded), f"stack_not_found: {', '.join(missing)}")

    stack_a, disclosure_a = resolved_a
    stack_b, disclosure_b = resolved_b
    rate_a = _coerce_rate(stack_a.get("solution_rate"))
    rate_b = _coerce_rate(stack_b.get("solution_rate"))
    overlap = _ci_overlap(stack_a.get("ci95"), stack_b.get("ci95"))
    if rate_a is None or rate_b is None or rate_a == rate_b:
        winner = "tie"
    else:
        winner = "a" if rate_a > rate_b else "b"
    verdict_note = None
    if winner != "tie" and overlap:
        verdict_note = "95% confidence intervals overlap; the solution_rate difference is not statistically significant"
    if disclosure_a["low_n"] or disclosure_b["low_n"]:
        low_note = "at least one side has n < 10 and is low confidence; treat the comparison as directional only"
        verdict_note = f"{verdict_note}; {low_note}" if verdict_note else low_note

    data = {
        "a": _public_stack(stack_a, disclosure_a),
        "b": _public_stack(stack_b, disclosure_b),
        "verdict": {
            "solution_rate": {
                "winner": winner,
                "delta": round(rate_a - rate_b, 4) if rate_a is not None and rate_b is not None else None,
                "ci_overlap": overlap,
            },
            "cost_usd_median": {
                "winner": _lower_winner(
                    _coerce_float(stack_a.get("cost_usd_median")), _coerce_float(stack_b.get("cost_usd_median"))
                )
            },
            "wall_seconds_median": {
                "winner": _lower_winner(
                    _coerce_float(stack_a.get("wall_seconds_median")), _coerce_float(stack_b.get("wall_seconds_median"))
                )
            },
            "note": verdict_note,
        },
    }
    return _envelope(True, data, _evidence_meta(loaded), None)


def _lower_winner(a: float | None, b: float | None) -> str:
    if a is None or b is None or a == b:
        return "tie"
    return "a" if a < b else "b"


def explain(stack: dict[str, Any]) -> dict[str, Any]:
    """Explain one {harness, model, scope?} stack: rank, CI, disclosure, frontier."""
    loaded = load_bench()
    if not loaded["ok"]:
        return _load_error_envelope(loaded)
    bench = loaded["bench"]
    spec = dict(stack) if isinstance(stack, dict) else {}
    resolved = _resolve_stack(bench, spec)
    if resolved is None:
        return _envelope(
            False,
            None,
            _evidence_meta(loaded),
            f"stack_not_found: {spec.get('harness')}/{spec.get('model')}",
        )
    row, disclosure = resolved

    scope = row.get("scope") or {}
    family = normalize_key(scope.get("family")) or "overall"
    peers = []
    for peer in bench.get("stacks") or []:
        if not isinstance(peer, dict):
            continue
        peer_family = normalize_key((peer.get("scope") or {}).get("family")) or "overall"
        if peer_family == family:
            peers.append(peer)
    peers.sort(key=lambda peer: -(_coerce_rate(peer.get("solution_rate")) or -1.0))
    rank_in_scope = None
    for index, peer in enumerate(peers):
        if peer is row or (
            normalize_key(peer.get("harness")) == normalize_key(row.get("harness"))
            and normalize_key(peer.get("model")) == normalize_key(row.get("model"))
            and normalize_key((peer.get("scope") or {}).get("family")) == family
        ):
            rank_in_scope = index + 1
            break

    frontier_hit = False
    for entry in bench.get("frontier") or []:
        if not isinstance(entry, dict):
            continue
        if normalize_key(entry.get("harness")) == normalize_key(row.get("harness")) and normalize_key(
            entry.get("model")
        ) == normalize_key(row.get("model")):
            entry_family = normalize_key((entry.get("scope") or {}).get("family")) or "overall"
            if entry_family in {family, "overall"}:
                frontier_hit = True
                break

    rationale = [_rationale(row, disclosure)]
    if rank_in_scope is not None:
        rationale.append(f"ranked {rank_in_scope} of {len(peers)} stacks in the {family} scope by solution_rate")
    if frontier_hit:
        rationale.append("sits on the cost/performance frontier")
    if disclosure["low_n"]:
        rationale.append("may not be ranked first until n >= 10 cells are measured")
    if disclosure["inferred"]:
        rationale.append("rate is a shrinkage-pooled inference and must not be presented as measured")

    data = {
        "stack": _public_stack(row, disclosure),
        "rank_in_scope": rank_in_scope,
        "scope_size": len(peers),
        "on_frontier": frontier_hit,
        "arena": {
            "votes": int((bench.get("arena") or {}).get("votes") or 0),
            "ratings": [
                rating
                for rating in (bench.get("arena") or {}).get("ratings") or []
                if isinstance(rating, dict)
                and normalize_key(rating.get("harness")) == normalize_key(row.get("harness"))
                and normalize_key(rating.get("model")) == normalize_key(row.get("model"))
            ],
        },
        "rationale": rationale,
    }
    return _envelope(True, data, _evidence_meta(loaded), None)


def status() -> dict[str, Any]:
    """Freshness, cell counts, and arena vote totals for bench.json."""
    loaded = load_bench()
    if not loaded["ok"]:
        return _load_error_envelope(loaded)
    bench = loaded["bench"]
    stacks = [stack for stack in bench.get("stacks") or [] if isinstance(stack, dict)]
    disclosures = [_stack_disclosure(stack) for stack in stacks]
    arena = bench.get("arena") or {}
    data = {
        "path": loaded.get("path"),
        "generated_at_utc": loaded.get("generatedAtUtc"),
        "age_days": loaded.get("ageDays"),
        "stale": bool(loaded.get("stale")),
        "stale_after_days": STALE_AFTER_DAYS,
        "schema_version": bench.get("schema_version"),
        "cells": len(stacks),
        "models": len(bench.get("models") or []),
        "harnesses": len(bench.get("harnesses") or []),
        "measured_cells": sum(1 for item in disclosures if not item["inferred"]),
        "inferred_cells": sum(1 for item in disclosures if item["inferred"]),
        "low_confidence_cells": sum(1 for item in disclosures if item["effective_confidence"] == "low"),
        "arena": {
            "votes": int(arena.get("votes") or 0),
            "ratings": len(arena.get("ratings") or []),
        },
        "source": bench.get("source"),
    }
    return _envelope(True, data, _evidence_meta(loaded), None)


def solution_rate_for_model(harness: str, model: str, family: str | None = None) -> float | None:
    """Fresh-only, adequately-powered solution_rate for the Ministry tie-break.

    Returns None unless bench.json loads, is fresh, and carries a measured or
    inferred stack row for the (harness, model) pairing in the requested family
    (falling back to the overall scope) with effective confidence above low.
    Never raises: any failure is indistinguishable from "no evidence".
    """
    try:
        loaded = load_bench()
        if not loaded.get("ok") or loaded.get("stale"):
            return None
        bench = loaded.get("bench") or {}
        harness_key = normalize_key(harness)
        model_key = normalize_key(model)
        if not harness_key or not model_key:
            return None
        wanted = normalize_key(family) or "overall"

        def lookup(scope_family: str) -> tuple[int, float] | None:
            best: tuple[int, float] | None = None
            for stack in bench.get("stacks") or []:
                if not isinstance(stack, dict):
                    continue
                if normalize_key(stack.get("harness")) != harness_key:
                    continue
                if normalize_key(stack.get("model")) != model_key:
                    continue
                stack_family = normalize_key((stack.get("scope") or {}).get("family")) or "overall"
                if stack_family != scope_family:
                    continue
                disclosure = _stack_disclosure(stack)
                if disclosure["effective_confidence"] == "low":
                    continue
                rate = _coerce_rate(stack.get("solution_rate"))
                if rate is None:
                    continue
                candidate = (disclosure["n"], rate)
                if best is None or candidate > best:
                    best = candidate
            return best

        found = lookup(wanted)
        if found is None and wanted != "overall":
            found = lookup("overall")
        return found[1] if found else None
    except Exception:  # pragma: no cover - defensive: tie-break must never raise
        return None
