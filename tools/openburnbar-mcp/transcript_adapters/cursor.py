"""Transcript adapter for Cursor Agent sessions."""

from __future__ import annotations

import collections
import json
import re
from pathlib import Path
from typing import Any

MAX_MESSAGES = 400
CURSOR_STRIP_TAGS = (
    "system-reminder",
    "USER_REQUEST",
    "ADDITIONAL_METADATA",
    "USER_SETTINGS_CHANGE",
    "user_information",
    "user_rules",
    "skills",
    "subagents",
    "slash_commands",
    "artifacts",
    r"RULE\[.*?\]",
)
_CURSOR_STRIP_RE = re.compile(
    "|".join(
        rf"<{tag}>.*?</{tag}>" if not tag.startswith(r"RULE") else rf"<{tag}>.*?</RULE\[.*?\]>"
        for tag in CURSOR_STRIP_TAGS
    ),
    re.DOTALL | re.IGNORECASE,
)


def _text_of(content: Any) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts: list[str] = []
        for block in content:
            if isinstance(block, str):
                parts.append(block)
            elif isinstance(block, dict):
                part_text = block.get("text") or block.get("content")
                if isinstance(part_text, str):
                    parts.append(part_text)
        return "\n".join(parts)
    return ""


def _parse_entry(entry: dict[str, Any]) -> tuple[str, str] | None:
    role = (entry.get("role") or "").strip().lower()
    msg_type = (entry.get("type") or "").strip().upper()
    source = (entry.get("source") or "").strip().upper()

    if not role:
        if msg_type == "USER_INPUT" or source == "USER_EXPLICIT":
            role = "user"
        elif msg_type == "PLANNER_RESPONSE" or source == "MODEL":
            role = "assistant"

    if role not in {"user", "assistant"}:
        return None

    raw_content = entry.get("content") or (
        entry.get("message", {}).get("content") if isinstance(entry.get("message"), dict) else None
    )
    text = _CURSOR_STRIP_RE.sub("", _text_of(raw_content)).strip()
    if text:
        return (role, text)
    return None


def load_cursor_transcript(
    path: Path | str,
    *,
    max_messages: int = MAX_MESSAGES,
) -> list[dict[str, str]]:
    """Read a Cursor JSONL or JSON transcript, keeping only user/assistant prose."""
    messages: collections.deque[dict[str, str]] = collections.deque(maxlen=max(1, int(max_messages)))
    p = Path(path)
    if not p.is_file():
        return []

    content = p.read_text(encoding="utf-8", errors="replace").strip()
    if not content:
        return []

    # Check if full JSON object
    if content.startswith("{") and content.endswith("}") is not False:
        try:
            root = json.loads(content)
            if isinstance(root, dict):
                raw_msgs = root.get("messages")
                if isinstance(raw_msgs, list):
                    for item in raw_msgs:
                        if isinstance(item, dict):
                            parsed = _parse_entry(item)
                            if parsed:
                                messages.append({"role": parsed[0], "content": parsed[1]})
                    return list(messages)
        except ValueError:
            pass

    # Process as JSONL
    for line in content.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        if not isinstance(entry, dict):
            continue
        parsed = _parse_entry(entry)
        if parsed:
            messages.append({"role": parsed[0], "content": parsed[1]})

    return list(messages)
