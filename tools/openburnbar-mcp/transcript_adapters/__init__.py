"""Transcript adapters for OpenBurnBar memory collectors."""

from __future__ import annotations

import json
from pathlib import Path
from collections.abc import Callable

from transcript_adapters.claude_code import load_claude_code_transcript
from transcript_adapters.codex import load_codex_transcript
from transcript_adapters.cursor import load_cursor_transcript
from transcript_adapters.grok import load_grok_transcript
from transcript_adapters.hermes import load_hermes_transcript

ADAPTERS: dict[str, Callable[..., list[dict[str, str]]]] = {
    "claude_code": load_claude_code_transcript,
    "cursor": load_cursor_transcript,
    "codex": load_codex_transcript,
    "hermes": load_hermes_transcript,
    "grok": load_grok_transcript,
}

ADVERTISED_CLIENTS = ("claude_code", "cursor", "codex", "hermes", "grok")


def detect_client(path: Path | str) -> str:
    """Detect the client format from the file path and initial content."""
    p = Path(path)
    name = p.name.lower()

    # 1. Path-based detection
    if "grok" in str(p).lower() or name == "chat_history.jsonl":
        return "grok"
    if name.startswith("session_") and name.endswith(".json"):
        return "hermes"
    if "hermes" in str(p).lower():
        return "hermes"
    if name.startswith("rollout-") or "codex" in str(p).lower():
        return "codex"
    if "cursor" in str(p).lower():
        return "cursor"
    if "claude" in str(p).lower():
        return "claude_code"

    # 2. Content-based probe
    if not p.is_file():
        return "claude_code"

    try:
        sample_lines: list[str] = []
        with p.open(encoding="utf-8", errors="replace") as f:
            for _ in range(10):
                line = f.readline()
                if not line:
                    break
                if line.strip():
                    sample_lines.append(line.strip())
    except OSError:
        return "claude_code"

    if not sample_lines:
        return "claude_code"

    # Check if single JSON object
    if sample_lines[0].startswith("{") and (name.endswith(".json") or len(sample_lines) == 1):
        try:
            doc = json.loads(p.read_text(encoding="utf-8", errors="replace"))
            if isinstance(doc, dict):
                if "session_id" in doc or "choices" in doc:
                    return "hermes"
                if "messages" in doc:
                    return "hermes"
        except ValueError:
            pass

    # Inspect JSONL lines
    for raw_line in sample_lines:
        try:
            entry = json.loads(raw_line)
        except ValueError:
            continue
        if not isinstance(entry, dict):
            continue
        if "item" in entry or "payload" in entry:
            return "codex"
        if entry.get("type") in {"user", "assistant"}:
            if "message" in entry:
                return "claude_code"
            if "content" in entry:
                return "grok"
        if entry.get("source") in {"USER_EXPLICIT", "MODEL"} or entry.get("type") in {"USER_INPUT", "PLANNER_RESPONSE"}:
            return "cursor"
        if entry.get("role") in {"user", "assistant", "system", "tool"}:
            if "tool_calls" in entry or "thinking" in entry:
                return "cursor"

    return "claude_code"


def load_client_transcript(
    path: Path | str,
    *,
    client: str = "auto",
    max_messages: int = 400,
) -> tuple[str, list[dict[str, str]]]:
    """Load transcript messages using the specified or auto-detected client adapter.

    Returns (resolved_client, messages).
    """
    resolved_client = client.strip().lower() if client and client != "auto" else detect_client(path)
    # Normalize aliases
    if resolved_client in {"claudecode", "claude-code"}:
        resolved_client = "claude_code"
    elif resolved_client in {"cursor-agent", "cursoragent"}:
        resolved_client = "cursor"
    elif resolved_client in {"grok-build", "grokbuild"}:
        resolved_client = "grok"

    adapter = ADAPTERS.get(resolved_client, load_claude_code_transcript)
    messages = adapter(path, max_messages=max_messages)
    return (resolved_client, messages)
