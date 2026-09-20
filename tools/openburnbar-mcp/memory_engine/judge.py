"""The reconciliation judge: a frontier model decides the ambiguous ADD / UPDATE / NONE / DELETE
cases, inside guardrails the rules layer keeps (only listed candidates, same scope, never immutable rows).
"""

from __future__ import annotations

import json
from collections.abc import Sequence
from dataclasses import dataclass
from typing import Any

from .constants import JUDGE_PROMPT_SYSTEM, JUDGE_PROMPT_VERSION
from .providers import ModelUnavailable

JUDGE_EVENTS = ("ADD", "UPDATE", "NONE", "DELETE")


@dataclass
class JudgeDecision:
    event: str
    targets: list[str]
    rationale: str
    confidence: float
    model: str
    prompt_version: str = JUDGE_PROMPT_VERSION


def judge_payload(*, incoming: dict[str, Any], candidates: Sequence[Any]) -> str:
    return json.dumps(
        {
            "incoming": {"text": incoming.get("text"), "kind": incoming.get("kind"), "scope": incoming.get("scope")},
            "candidates": [
                {"id": item.id, "text": item.body, "kind": item.kind, "updatedAt": item.updated_at}
                for item in candidates
            ],
            "answer_schema": {
                "event": "ADD|UPDATE|NONE|DELETE",
                "targets": ["mem_..."],
                "rationale": "one sentence",
                "confidence": 0.0,
            },
        },
        ensure_ascii=False,
    )


def parse_judge_answer(parsed: Any, *, allowed_ids: Sequence[str], model: str) -> JudgeDecision | None:
    """Validate the contract; None for anything outside it (the rules then decide)."""
    if not isinstance(parsed, dict):
        return None
    event = str(parsed.get("event") or "").strip().upper()
    if event not in JUDGE_EVENTS:
        return None
    raw_targets = parsed.get("targets")
    targets = [str(item) for item in raw_targets if str(item) in allowed_ids] if isinstance(raw_targets, list) else []
    if event in ("UPDATE", "DELETE", "NONE") and not targets:
        return None
    if event == "ADD":
        targets = []
    rationale = str(parsed.get("rationale") or "").strip()[:280]
    try:
        confidence = float(parsed.get("confidence", 0.5))
    except (TypeError, ValueError):
        confidence = 0.5
    return JudgeDecision(event=event, targets=targets, rationale=rationale, confidence=confidence, model=model)


def llm_judge(call: Any, *, incoming: dict[str, Any], candidates: Sequence[Any]) -> JudgeDecision | None:
    """One judge call; raises `ModelUnavailable` on refusal, returns None on an out-of-contract answer."""
    if not candidates:
        return None
    parsed, _usage = call.json(
        JUDGE_PROMPT_SYSTEM, judge_payload(incoming=incoming, candidates=candidates), max_tokens=400
    )
    return parse_judge_answer(parsed, allowed_ids=[item.id for item in candidates], model=call.label)


__all__ = ["JUDGE_EVENTS", "JudgeDecision", "ModelUnavailable", "judge_payload", "llm_judge", "parse_judge_answer"]
