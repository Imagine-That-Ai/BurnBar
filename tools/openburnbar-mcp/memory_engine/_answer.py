"""The Memory Pro answer contract: what a model may say, and what is thrown away.

`_read.py` decides which memories a question reaches; this module decides what
survives of a model's reply. Both halves refuse rather than guess — an answer
whose citations are not in the list it was given, or that carries a tool call or
a refusal sentinel, is dropped whole.

Only pure functions live here; the recall path in `_read.py` calls them."""

from __future__ import annotations

import json
import re
from typing import Any

from .constants import ANSWER_REFUSAL, ANSWER_REJECT_SENTINELS


def _parse_rerank_answer(parsed: Any, listed_ids: set[str]) -> dict[str, float] | None:
    """`{"results": [{"id", "relevance"}]}` over listed ids only; anything else is out of contract."""
    rows = parsed.get("results") if isinstance(parsed, dict) else None
    if not isinstance(rows, list):
        return None
    scores: dict[str, float] = {}
    for row in rows:
        if not isinstance(row, dict) or str(row.get("id")) not in listed_ids:
            return None
        memory_id = str(row["id"])
        if memory_id in scores:
            return None  # a duplicate verdict is ambiguous, not a tie
        try:
            relevance = float(row.get("relevance"))
        except (TypeError, ValueError):
            return None
        if relevance != relevance:  # NaN
            return None
        scores[memory_id] = min(1.0, max(0.0, relevance))
    if set(scores) != set(listed_ids):
        return None  # every listed candidate must be scored, or the fusion order stands
    return scores


_CITATION_MARKER = re.compile(r"\[(mem_[0-9a-f]+)\]")


def _validate_answer(parsed: Any, listed_ids: set[str]) -> dict[str, Any]:
    """Apply the answer contract: listed citations only, no sentinels, no tool calls, refusal on no evidence."""
    answer = str(parsed.get("answer") or "").strip() if isinstance(parsed, dict) else ""
    # Only inline markers count: a bare `citations` array cannot vouch for
    # claims the answer text never ties to a memory.
    mentioned: list[str] = []
    for candidate in _CITATION_MARKER.findall(answer):
        if candidate not in mentioned:
            mentioned.append(candidate)
    refusal = {"answer": ANSWER_REFUSAL, "citations": [], "groundedness": "refused", "dropped": 0}
    upper = answer.upper()
    if any(sentinel in upper for sentinel in ANSWER_REJECT_SENTINELS):
        return {**refusal, "code": "ANSWER_REJECTED"}
    if answer.startswith("{"):
        try:
            shaped = json.loads(answer)
        except ValueError:
            shaped = None
        if isinstance(shaped, dict) and {"tool_calls", "tool_call", "function_call", "tool_use"} & set(shaped):
            return {**refusal, "code": "ANSWER_REJECTED"}
    valid = [memory_id for memory_id in mentioned if memory_id in listed_ids]
    dropped = len(mentioned) - len(valid)
    if not valid or not answer:
        return {**refusal, "dropped": dropped}
    for unknown in (memory_id for memory_id in mentioned if memory_id not in listed_ids):
        answer = answer.replace(f"[{unknown}]", "").replace(unknown, "")
    answer = re.sub(r"[ \t]{2,}", " ", answer).strip()
    return {
        "answer": answer,
        "citations": valid,
        "groundedness": "grounded" if dropped == 0 else "partial",
        "dropped": dropped,
    }
