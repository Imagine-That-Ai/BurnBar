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


def _candidate_records(json_obj: dict[str, Any]) -> list[dict[str, Any]]:
    """Every dict a Codex rollout line may keep the message on, newest shape first.

    A current rollout record is
    `{"type": "response_item", "payload": {"type": "message", "role": ..., "content": [...]}}`
    -- the message sits on `payload` ITSELF, with no `item` wrapper. Reading only
    `payload.item` and then falling back to the outer envelope (which carries no
    `role`) discarded every user and assistant turn of a real session, so the
    advertised collector reported `skipped_empty` on live logs. Older rollouts
    nested the same fields under `item` / `payload.item` / `msg.item`, so those
    stay in the list: a member's archived sessions keep working.
    """
    candidates: list[dict[str, Any]] = []
    payload = json_obj.get("payload")
    msg = json_obj.get("msg")
    for candidate in (
        payload,
        payload.get("item") if isinstance(payload, dict) else None,
        json_obj.get("item"),
        msg.get("item") if isinstance(msg, dict) else None,
        msg,
        json_obj,
    ):
        if isinstance(candidate, dict) and not any(candidate is seen for seen in candidates):
            candidates.append(candidate)
    return candidates


def _extract_codex_message(json_obj: dict[str, Any]) -> tuple[str, str] | None:
    for item in _candidate_records(json_obj):
        found = _message_from_record(item)
        if found is not None:
            return found
    return None


def _message_from_record(item: dict[str, Any]) -> tuple[str, str] | None:
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
