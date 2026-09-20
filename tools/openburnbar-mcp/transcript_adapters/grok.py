"""Transcript adapter for Grok Build sessions."""

from __future__ import annotations

import collections
import json
from pathlib import Path
from typing import Any

MAX_MESSAGES = 400


def _flatten_content(raw: Any) -> str:
    if isinstance(raw, str):
        return raw
    if isinstance(raw, list):
        parts: list[str] = []
        for item in raw:
            if isinstance(item, str):
                parts.append(item)
            elif isinstance(item, dict):
                text = item.get("text") or item.get("content")
                if isinstance(text, str):
                    parts.append(text)
        return "\n".join(parts)
    return ""


def load_grok_transcript(
    path: Path | str,
    *,
    max_messages: int = MAX_MESSAGES,
) -> list[dict[str, str]]:
    """Read a Grok Build chat_history.jsonl or session log, keeping only user/assistant prose."""
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
            role = str(entry.get("type") or entry.get("role") or "").strip().lower()
            if role not in {"user", "assistant"}:
                continue
            text = _flatten_content(entry.get("content")).strip()
            if text:
                messages.append({"role": role, "content": text})

    return list(messages)
