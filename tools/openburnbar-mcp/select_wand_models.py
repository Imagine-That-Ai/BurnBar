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
        selected = payload.get("selected")
        payload["selectedForIndex"] = _selection_for_index(selected if isinstance(selected, list) else [], args.sibling_index)
        print(json.dumps(payload, sort_keys=True))
        return 0
    except Exception as exc:  # pragma: no cover - defensive CLI boundary
        print(
            json.dumps(
                {
                    "status": "unavailable",
                    "code": "MINISTRY_SELECT_MANY_FAILED",
                    "reason": str(exc),
                },
                sort_keys=True,
            ),
            file=sys.stdout,
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
