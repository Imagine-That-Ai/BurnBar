"""Transcript adapter for Hermes sessions, reusing hermes_proxy."""

from __future__ import annotations

import collections
import json
import sys
from pathlib import Path

# Ensure sibling tools/openburnbar-mcp directory is on sys.path for hermes_proxy import
_MCP_DIR = str(Path(__file__).resolve().parents[1])
if _MCP_DIR not in sys.path:
    sys.path.insert(0, _MCP_DIR)

import hermes_proxy  # noqa: E402 — sibling module; the sys.path insert above has to run first

MAX_MESSAGES = 400


def load_hermes_transcript(
    path: Path | str,
    *,
    max_messages: int = MAX_MESSAGES,
) -> list[dict[str, str]]:
    """Read a Hermes JSON snapshot or JSONL session log, keeping only user/assistant prose."""
    messages: collections.deque[dict[str, str]] = collections.deque(maxlen=max(1, int(max_messages)))
    p = Path(path)
    if not p.is_file():
        return []

    raw = p.read_text(encoding="utf-8", errors="replace").strip()
    if not raw:
        return []

    # Case 1: Single JSON document (session snapshot like `session_<id>.json` or request/response body)
    if raw.startswith("{") or raw.startswith("["):
        try:
            parsed = json.loads(raw)
            extracted = hermes_proxy.extract_messages_from_payload(parsed)
            if extracted:
                for msg in extracted:
                    messages.append(msg)
                return list(messages)
        except ValueError:
            pass

    # Case 2: JSONL stream of events / messages
    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        if not isinstance(entry, dict):
            continue
        extracted = hermes_proxy.extract_messages_from_payload(entry)
        for msg in extracted:
            messages.append(msg)

    return list(messages)
