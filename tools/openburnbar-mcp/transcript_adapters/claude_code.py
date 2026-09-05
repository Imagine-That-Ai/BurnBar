"""Transcript adapter for Claude Code sessions."""

from __future__ import annotations

import collections
import json
import re
from pathlib import Path
from typing import Any

MAX_MESSAGES = 400
WRAPPER_TAGS = (
    "system-reminder",
    "command-name",
    "command-message",
    "command-args",
    "local-command-stdout",
    "local-command-stderr",
)
_WRAPPER_RE = re.compile("|".join(rf"<{tag}>.*?</{tag}>" for tag in WRAPPER_TAGS), re.DOTALL)


def _text_of(content: Any) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = [block.get("text", "") for block in content if isinstance(block, dict) and block.get("type") == "text"]
        return "\n".join(part for part in parts if isinstance(part, str))
    return ""


def load_claude_code_transcript(
    path: Path | str,
    *,
    max_messages: int = MAX_MESSAGES,
) -> list[dict[str, str]]:
    """Read a Claude Code JSONL transcript, keeping only user/assistant prose."""
    messages: collections.deque[dict[str, str]] = collections.deque(maxlen=max(1, int(max_messages)))
    with Path(path).open(encoding="utf-8", errors="replace") as handle:
        for line in handle:
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            if not isinstance(entry, dict) or entry.get("type") not in {"user", "assistant"} or entry.get("isMeta"):
                continue
            message = entry.get("message")
            if not isinstance(message, dict) or message.get("role") not in {"user", "assistant"}:
                continue
            text = _WRAPPER_RE.sub("", _text_of(message.get("content"))).strip()
            if text:
                messages.append({"role": str(message["role"]), "content": text})
    return list(messages)
