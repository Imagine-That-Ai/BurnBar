#!/usr/bin/env python3
"""CLI bridge for selecting The Wand's worker model routes.

This is intentionally thin: it parses process arguments, points the Ministry
module at the desired catalog/model metadata roots, then calls
ministry.select_models_for_wand(). The ranking logic stays in ministry.py.
"""

from __future__ import annotations

import argparse
import os
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
    ministry.CATALOG_PATH = root / "OpenBurnBarCore" / "Sources" / "OpenBurnBarKernelModels" / "Resources" / "catalog.json"
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


def _safe_public_string(value: Any, *, max_length: int = 160) -> str | None:
    if not isinstance(value, str):
        return None
    trimmed = value.strip()
    if not trimmed:
        return None
    lowered = trimmed.lower()
    sensitive_markers = (
        "api_key",
        "apikey",
        "authorization",
        "bearer ",
        "password",
        "secret",
        "token",
        "ghp_",
        "sk-",
    )
    if any(marker in lowered for marker in sensitive_markers):
        return None
    allowed = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:/@+- ()[]{}#,")
    cleaned = "".join(character for character in trimmed[:max_length] if character in allowed).strip()
    return cleaned or None


def _public_candidate(candidate: dict[str, Any] | None) -> dict[str, Any] | None:
    if not candidate:
        return None
    public_fields = ("arg", "model", "displayName", "provider", "source")
    return {
        field: public_value
        for field in public_fields
        if (public_value := _safe_public_string(candidate.get(field))) is not None
    }


def _public_payload(payload: dict[str, Any], sibling_index: int) -> dict[str, Any]:
    selected = payload.get("selected")
    selected_candidates = selected if isinstance(selected, list) else []
    selected_for_index = _selection_for_index(selected_candidates, sibling_index)
    return {
        "status": _safe_public_string(payload.get("status"), max_length=32) or "ok",
        "selectedCount": len(selected_candidates),
        "requestedCount": int(payload.get("requestedCount"))
        if isinstance(payload.get("requestedCount"), int)
        else None,
        "reason": _safe_public_string(payload.get("reason"), max_length=120),
        "selectedForIndex": _public_candidate(selected_for_index),
    }


def _json_string(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def _json_string_or_null(value: str | None) -> str:
    return "null" if value is None else _json_string(value)


def _json_int_or_null(value: int | None) -> str:
    return "null" if value is None else str(value)


def _public_candidate_json(candidate: dict[str, Any] | None) -> str:
    if not candidate:
        return "null"
    parts: list[str] = []
    for field in ("arg", "model", "displayName", "provider", "source"):
        value = _safe_public_string(candidate.get(field))
        if value is not None:
            parts.append(f"{_json_string(field)}:{_json_string(value)}")
    return "{" + ",".join(parts) + "}"


def _public_payload_json(payload: dict[str, Any]) -> str:
    status = _safe_public_string(payload.get("status"), max_length=32) or "ok"
    selected_count = payload.get("selectedCount") if isinstance(payload.get("selectedCount"), int) else 0
    requested_count = payload.get("requestedCount") if isinstance(payload.get("requestedCount"), int) else None
    reason = _safe_public_string(payload.get("reason"), max_length=120)
    selected_for_index = payload.get("selectedForIndex")
    candidate = selected_for_index if isinstance(selected_for_index, dict) else None
    return (
        "{"
        f'"reason":{_json_string_or_null(reason)},'
        f'"requestedCount":{_json_int_or_null(requested_count)},'
        f'"selectedCount":{selected_count},'
        f'"selectedForIndex":{_public_candidate_json(candidate)},'
        f'"status":{_json_string(status)}'
        "}"
    )


def _unavailable_payload_json(reason: str) -> str:
    safe_reason = _safe_public_string(reason, max_length=80) or "Error"
    return f'{{"code":"MINISTRY_SELECT_MANY_FAILED","reason":{_json_string(safe_reason)},"status":"unavailable"}}'


def _emit_cli_json(encoded: str) -> None:
    # This stdout channel is the Swift app's machine-readable CLI protocol.
    # Callers must pass only JSON produced by the public builders above.
    os.write(1, (encoded + "\n").encode("utf-8"))


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
        _emit_cli_json(_public_payload_json(_public_payload(payload, args.sibling_index)))
        return 0
    except Exception as exc:  # pragma: no cover - defensive CLI boundary
        _emit_cli_json(_unavailable_payload_json(type(exc).__name__))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
