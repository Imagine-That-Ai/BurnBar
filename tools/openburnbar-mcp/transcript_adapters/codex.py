"""Transcript adapter for Codex session rollout logs."""

from __future__ import annotations

import collections
import json
from pathlib import Path
from typing import Any

MAX_MESSAGES = 400


def _extract_text(raw: Any) -> str:
    if isinstance(raw, str):
        return raw
    if isinstance(raw, list):
        pieces: list[str] = []
        for piece in raw:
            if isinstance(piece, str):
                pieces.append(piece)
            elif isinstance(piece, dict):
                text = piece.get("text") or piece.get("content")
                if isinstance(text, str):
                    pieces.append(text)
        return "\n".join(pieces)
    return ""


def _extract_codex_message(json_obj: dict[str, Any]) -> tuple[str, str] | None:
    item = (
        json_obj.get("item")
        or (json_obj.get("payload", {}).get("item") if isinstance(json_obj.get("payload"), dict) else None)
        or (json_obj.get("msg", {}).get("item") if isinstance(json_obj.get("msg"), dict) else None)
        or json_obj
    )
    if not isinstance(item, dict):
        return None

    role = str(item.get("role") or "").strip().lower()
    if role not in {"user", "assistant"}:
        return None

    raw_text = (
        _extract_text(item.get("content")) or _extract_text(item.get("message")) or _extract_text(item.get("text"))
    )
    cleaned = raw_text.strip()
    if cleaned:
        return (role, cleaned)
    return None


def load_codex_transcript(
    path: Path | str,
    *,
    max_messages: int = MAX_MESSAGES,
) -> list[dict[str, str]]:
    """Read a Codex JSONL rollout log, keeping only user/assistant prose."""
    messages: collections.deque[dict[str, str]] = collections.deque(maxlen=max(1, int(max_messages)))
    p = Path(path)
    if not p.is_file():
        return []

    with p.open(encoding="utf-8", errors="replace") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            if not isinstance(entry, dict):
                continue
            msg = _extract_codex_message(entry)
            if msg:
                messages.append({"role": msg[0], "content": msg[1]})

    return list(messages)
