#!/usr/bin/env python3
"""CLI bridge for selecting The Wand's worker model routes.

This is intentionally thin: it parses process arguments, points the Ministry
module at the desired catalog/model metadata roots, then calls
ministry.select_models_for_wand(). The ranking logic stays in ministry.py.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any

import ministry


def _default_db_path() -> Path:
    raw = os.environ.get("BURNBAR_DB_PATH", "").strip()
    if raw:
        return Path(raw).expanduser().resolve()
    support = Path.home() / "Library" / "Application Support"
    for app_dir in ("OpenBurnBar", "AgentLens"):
        base = support / app_dir
        for name in ("openburnbar.sqlite", "agentlens.sqlite"):
            candidate = base / name
            if candidate.is_file():
                return candidate
    return support / "OpenBurnBar" / "openburnbar.sqlite"


def _configure_repo_root(repo_root: str | None) -> None:
    if not repo_root:
        return
    root = Path(repo_root).expanduser().resolve()
    ministry.REPO_ROOT = root
    ministry.CATALOG_PATH = root / "OpenBurnBarCore" / "Sources" / "OpenBurnBarCore" / "Resources" / "catalog.json"
    ministry.MODELS_JSON_PATHS = (
        root / "website" / "public" / "data" / "models.json",
        root / "website" / "scripts" / "rundown-seed" / "models.json",
    )


def _selection_for_index(selected: list[dict[str, Any]], index: int) -> dict[str, Any] | None:
    if not selected:
        return None
    if index < 0:
        return None
    return selected[index % len(selected)]


def _public_candidate(candidate: dict[str, Any] | None) -> dict[str, Any] | None:
    if not candidate:
        return None
    public_fields = ("arg", "model", "displayName", "provider", "source")
    return {
        field: candidate[field]
        for field in public_fields
        if isinstance(candidate.get(field), str) and candidate[field]
    }


def _public_payload(payload: dict[str, Any], sibling_index: int) -> dict[str, Any]:
    selected = payload.get("selected")
    selected_candidates = selected if isinstance(selected, list) else []
    selected_for_index = _selection_for_index(selected_candidates, sibling_index)
    return {
        "status": payload.get("status") if isinstance(payload.get("status"), str) else "ok",
        "selectedCount": len(selected_candidates),
        "requestedCount": payload.get("requestedCount"),
        "reason": payload.get("reason") if isinstance(payload.get("reason"), str) else None,
        "selectedForIndex": _public_candidate(selected_for_index),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Select model routes for an OpenBurnBar Wand fan-out.")
    parser.add_argument("--repo-root", default=os.environ.get("OPENBURNBAR_REPO_ROOT"))
    parser.add_argument("--wand-id", default=os.environ.get("OPENBURNBAR_WAND_ID") or None)
    parser.add_argument("--count", type=int, default=1)
    parser.add_argument("--sibling-index", type=int, default=0)
    parser.add_argument("--require-provider-diversity", action=argparse.BooleanOptionalAction, default=True)
    parser.add_argument("--prove-headless", action="store_true")
    parser.add_argument("--max-probes", type=int, default=4)
    parser.add_argument("--probe-ttl", type=int, default=3600)
    args = parser.parse_args()

    _configure_repo_root(args.repo_root)
    try:
        payload = ministry.select_models_for_wand(
            ministry.default_wands_path(_default_db_path()),
            wand_id=args.wand_id,
            count=max(1, args.count),
            require_provider_diversity=bool(args.require_provider_diversity),
            prove_headless=bool(args.prove_headless),
            max_probes=max(1, min(args.max_probes, 12)),
            probe_ttl=max(0, args.probe_ttl),
        )
        sys.stdout.write(json.dumps(_public_payload(payload, args.sibling_index), sort_keys=True) + "\n")
        return 0
    except Exception as exc:  # pragma: no cover - defensive CLI boundary
        sys.stdout.write(
            json.dumps(
                {
                    "status": "unavailable",
                    "code": "MINISTRY_SELECT_MANY_FAILED",
                    "reason": type(exc).__name__,
                },
                sort_keys=True,
            )
            + "\n",
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
