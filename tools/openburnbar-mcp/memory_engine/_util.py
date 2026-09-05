"""Small utilities shared across the package: timestamps, hashing, JSON, and
the normalizers for kind / scope / tags."""

from __future__ import annotations

import hashlib
import json
import re
from collections.abc import Sequence
from datetime import UTC, datetime
from typing import Any

from .constants import INGEST_DECISION_KEYS, KIND_ALIASES, KINDS, MEMORY_SCOPES, PERSONAL_KINDS


def now_iso() -> str:
    return datetime.now(UTC).isoformat().replace("+00:00", "Z")


def _parse_iso(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        text = str(value).strip()
        if text.endswith("Z"):
            text = text[:-1] + "+00:00"
        parsed = datetime.fromisoformat(text)
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=UTC)
        return parsed
    except ValueError:
        return None


def sha256_hex(data: bytes | str) -> str:
    if isinstance(data, str):
        data = data.encode("utf-8")
    return hashlib.sha256(data).hexdigest()


def canonical_body_hash(body: str) -> str:
    # NOTE: The daemon-mirror hash (server.py:2075, server.py:2172, _admin.py:420 -> engine_meta key
    # daemon_mirror:<id>) is a different, non-lowered hash in a different namespace and must never
    # be folded into this helper.
    return sha256_hex(body.lower())


def _json_dumps(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), default=str)


def _json_loads(value: Any, default: Any) -> Any:
    if value in (None, ""):
        return default
    try:
        return json.loads(value)
    except (TypeError, ValueError):
        return default


def _truthy(value: str | None) -> bool:
    return (value or "").strip().lower() in {"1", "true", "yes", "y", "on"}


def _clamp(value: float, low: float, high: float) -> float:
    return max(low, min(high, value))


def normalize_kind(kind: str | None, default: str = "fact") -> str:
    raw = (kind or "").strip().lower()
    if raw in KINDS:
        return raw
    return KIND_ALIASES.get(raw, default)


def normalize_kind_strict(kind: str) -> str:
    """Normalize an explicit kind without applying a destructive default."""
    raw = str(kind).strip().lower()
    if raw in KINDS:
        return raw
    if raw in KIND_ALIASES:
        return KIND_ALIASES[raw]
    raise ValueError(f"kind must be one of: {', '.join(KINDS)}")


def normalize_scope(scope: str | None, kind: str) -> str:
    raw = (scope or "").strip().lower()
    if raw in ("", "auto"):
        return "personal" if kind in PERSONAL_KINDS else "project"
    if raw not in MEMORY_SCOPES:
        raise ValueError(f"scope must be one of: auto, {', '.join(MEMORY_SCOPES)}")
    return raw


def _split_tags(tags: Sequence[str] | str | None) -> list[str]:
    if tags is None:
        return []
    if isinstance(tags, str):
        parts = re.split(r"[,;\n]", tags)
    else:
        parts = [str(part) for part in tags]
    return [part.strip() for part in parts if part and part.strip()]


def raw_tags(tags: Sequence[str] | str | None) -> list[str]:
    """The caller's tags split and trimmed but *not* lowercased or capped.

    The secret gate has to read a tag the way the caller wrote it: an
    `AKIA…` access key id no longer matches its corpus pattern once
    `normalize_tags` folds it to lowercase. Write paths therefore carry the raw
    form as far as the gate and call `normalize_tags` on what the gate returns,
    which yields the same stored tags as normalizing first.
    """
    return sorted(set(_split_tags(tags)))


def normalize_tags(tags: Sequence[str] | str | None) -> list[str]:
    cleaned = sorted({part.lower() for part in _split_tags(tags)})
    return cleaned[:32]


def _aux_strings(
    tags: Sequence[str], entities: Sequence[str], metadata: dict[str, Any] | None, source_ref: str | None
) -> list[str]:
    """Every caller-controlled string stored beside the body (tags, entities,
    metadata keys and nested values, source_ref) so they can be screened like it."""
    out: list[str] = [str(item) for item in tags] + [str(item) for item in entities]
    if source_ref:
        out.append(str(source_ref))

    def walk(value: Any) -> None:
        if isinstance(value, str):
            out.append(value)
        elif isinstance(value, dict):
            for key, item in value.items():
                out.append(str(key))
                walk(item)
        elif isinstance(value, list):
            for item in value:
                walk(item)

    walk(metadata or {})
    return out


def _ingest_decision(decision: dict[str, Any]) -> dict[str, Any]:
    return {key: value for key, value in decision.items() if key in INGEST_DECISION_KEYS}


def _is_expired(expires_at: str | None, now: datetime) -> bool:
    if not expires_at:
        return False
    parsed = _parse_iso(expires_at)
    return parsed is None or parsed <= now


def _normalize_expiration(expires_at: str | None) -> str | None:
    if expires_at is None:
        return None
    text = str(expires_at).strip()
    if not text:
        return None
    parsed = _parse_iso(text)
    if parsed is None:
        raise ValueError("expiresAt must be a valid ISO-8601 timestamp")
    return text


def fail_closed_refusal(status: str, code: str, reason: str | None, project_id: str, root: Any) -> dict[str, Any]:
    from .store import project_payload

    return {
        "status": status,
        "code": code,
        "reason": reason,
        "summary": {event: 0 for event in ("ADD", "UPDATE", "NONE", "DELETE", "REJECT")},
        "decisions": [],
        **project_payload(project_id, root),
    }
