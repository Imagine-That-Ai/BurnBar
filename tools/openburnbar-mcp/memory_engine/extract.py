"""Entities, relations, and extraction: the `Fact` record, the heuristic
extractor, the LLM extractors, and the transcript gate."""

from __future__ import annotations

import json
import os
import re
import subprocess
import time
import urllib.error
import urllib.request
from collections.abc import Callable, Sequence
from dataclasses import dataclass, field
from typing import Any

from ._util import _clamp, raw_tags
from .constants import (
    CUE_PATTERNS,
    DEFAULT_MAX_FACTS,
    DEFAULT_OLLAMA_BASE_URL,
    DISCOURSE_MARKER_RE,
    EXTRACT_PROMPT,
    EXTRACT_PROMPT_V2_SYSTEM,
    EXTRACT_PROMPT_V2_USER,
    EXTRACT_PROMPT_VERSION,
    EXTRACTOR_ENV,
    HANDLE_RE,
    IDENTIFIER_RE,
    ISSUE_RE,
    MAX_BODY_CHARS,
    NOISE_PATTERNS,
    OLLAMA_BASE_URL_ENV,
    PATH_RE,
    PROPER_NOUN_RE,
    RELATION_PREDICATES,
    SENTENCE_SPLIT_RE,
    STOPWORDS,
    VERSION_RE,
)
from .gate import scan_text
from .text import _jaccard, tokenize


def extract_entities(text: str, limit: int = 16) -> list[str]:
    found: list[str] = []

    def add(value: str) -> None:
        cleaned = value.strip("`\"' .,;:()[]{}")
        if not cleaned or len(cleaned) < 2 or len(cleaned) > 80:
            return
        if cleaned.lower() in STOPWORDS:
            return
        if cleaned not in found:
            found.append(cleaned)

    for match in PATH_RE.finditer(text):
        add(match.group(0))
    for match in re.finditer(r"`([^`\n]{2,80})`", text):
        add(match.group(1))
    for match in HANDLE_RE.finditer(text):
        add(match.group(0))
    for match in ISSUE_RE.finditer(text):
        add(match.group(0))
    for match in IDENTIFIER_RE.finditer(text):
        value = match.group(0)
        if value.startswith("`"):
            continue
        if value.isupper() and len(value) < 3:
            continue
        add(value)
    for match in PROPER_NOUN_RE.finditer(text):
        value = match.group(0)
        if len(value) < 3:
            continue
        # Skip sentence-initial common words that only look proper because of position.
        if match.start() == 0 and value.lower() in {"the", "this", "that", "when", "use", "we", "it", "if", "for"}:
            continue
        add(value)
    return found[:limit]


def extract_relations(text: str) -> list[tuple[str, str, str]]:
    """Heuristic (subject, predicate, object) triples from one sentence-ish text."""
    triples: list[tuple[str, str, str]] = []
    sentence = DISCOURSE_MARKER_RE.sub("", re.sub(r"\s+", " ", text).strip())
    if not sentence or len(sentence) > 400:
        return triples
    for predicate, pattern in RELATION_PREDICATES:
        match = pattern.search(sentence)
        if not match:
            continue
        subject = sentence[: match.start()].strip(" ,;:")
        obj = re.split(r"[.;,]| because | so that | which | that ", sentence[match.end() :].strip(), maxsplit=1)[
            0
        ].strip(" .")
        subject_words = subject.split()
        object_words = obj.split()
        if not subject_words or not object_words or len(subject_words) > 6 or len(object_words) > 8:
            continue
        subject_norm = " ".join(subject_words[-4:])
        object_norm = " ".join(object_words[:6])
        if subject_norm.lower() in STOPWORDS or object_norm.lower() in STOPWORDS:
            continue
        triples.append((subject_norm, predicate, object_norm))
        break
    return triples


def _slot_key(subject: str, predicate: str) -> str:
    return f"{' '.join(tokenize(subject))}|{predicate}"


_PACK_SENTINEL_RE = re.compile(r"(?:END_)?OPENBURNBAR_MEMORY_PACK_V1")
PACK_TOKEN_BUDGET_FLOOR = 192  # the envelope plus one truncated line always fits


def _pack_safe(body: str) -> str:
    """One physical line per memory inside a pack: newlines collapse so a body
    cannot fake a new pack line, and the pack sentinels cannot appear inside."""
    collapsed = re.sub(r"\s+", " ", body).strip()
    return _PACK_SENTINEL_RE.sub("[pack-sentinel]", collapsed)


# `heuristic_extract` stamps each fact with the index of the message it came
# from (`m3`). It names a position inside one batch and nothing about the batch
# itself, so the write path recognizes it and lets a caller's `source_ref`
# prefix it instead of being discarded.
EXTRACTOR_MARKER_RE = re.compile(r"^m\d+$")


@dataclass
class Fact:
    text: str
    kind: str = "fact"
    confidence: float = 0.7
    scope: str | None = None
    tags: list[str] = field(default_factory=list)
    entities: list[str] = field(default_factory=list)
    metadata: dict[str, Any] = field(default_factory=dict)
    source_ref: str | None = None
    supersedes: list[str] = field(default_factory=list)
    expires_at: str | None = None
    immutable: bool = False
    review_status: str | None = None
    sensitivity: str | None = None

    @classmethod
    def from_mapping(cls, raw: Any) -> Fact | None:
        if isinstance(raw, str):
            raw = {"text": raw}
        if not isinstance(raw, dict):
            return None
        text = str(raw.get("text") or raw.get("memory") or raw.get("body") or "").strip()
        if not text:
            return None
        raw_kind = raw.get("kind") if raw.get("kind") is not None else raw.get("category")
        kind = str(raw_kind if raw_kind is not None else "fact").strip().lower()
        try:
            confidence = _clamp(float(raw.get("confidence", 0.7)), 0.0, 1.0)
        except (TypeError, ValueError):
            confidence = 0.7
        # Raw, not normalized: `_commit_fact` gates these strings and lowercases
        # what the gate returns, so the gate never sees a case-folded secret.
        tags = raw_tags(raw.get("tags"))
        entities = [str(item).strip() for item in (raw.get("entities") or []) if str(item).strip()][:16]
        metadata = raw.get("metadata") if isinstance(raw.get("metadata"), dict) else {}
        supersedes = [str(item) for item in (raw.get("supersedes") or []) if str(item).strip()]
        # Accept both the snake_case write contract and the camelCase export
        # contract so an export/import round trip keeps provenance and expiry.
        source_ref = raw.get("source_ref") or raw.get("sourceRef")
        expires_at = raw.get("expires_at") or raw.get("expiresAt")
        review_status = raw.get("review_status") or raw.get("reviewStatus")
        raw_sensitivity = raw.get("sensitivity")
        sensitivity = str(raw_sensitivity).strip().lower() if raw_sensitivity is not None else None
        return cls(
            text=text[:MAX_BODY_CHARS],
            kind=kind,
            confidence=confidence,
            scope=str(raw["scope"]) if raw.get("scope") else None,
            tags=tags,
            entities=entities,
            metadata=metadata,
            source_ref=str(source_ref) if source_ref else None,
            supersedes=supersedes,
            expires_at=str(expires_at) if expires_at else None,
            immutable=bool(raw.get("immutable", False)),
            review_status=str(review_status).strip().lower() if review_status else None,
            sensitivity=sensitivity,
        )


_EVIDENCE_MARKER = re.compile(r"^\[m\d+\] ", re.M)


def render_transcript(messages: Sequence[dict[str, Any]], max_chars: int = 24_000) -> str:
    lines: list[str] = []
    for index, message in enumerate(messages):
        role = str(message.get("role") or "user").strip().lower()[:16]
        content = message.get("content")
        if isinstance(content, list):
            content = " ".join(str(part.get("text", "")) if isinstance(part, dict) else str(part) for part in content)
        text = re.sub(r"\s+", " ", str(content or "")).strip()
        if text:
            lines.append(f"[m{index}] {role}: {text}")
    rendered = "\n".join(lines)
    if len(rendered) > max_chars:
        rendered = rendered[-max_chars:]
    return rendered


def _split_sentences(text: str) -> list[str]:
    parts = [part.strip() for part in SENTENCE_SPLIT_RE.split(text) if part and part.strip()]
    out: list[str] = []
    for part in parts:
        part = re.sub(r"^[-*•]\s+|^\d+[.)]\s+", "", part).strip()
        if 12 <= len(part) <= 600:
            out.append(part)
    return out


def heuristic_extract(messages: Sequence[dict[str, Any]], max_facts: int = DEFAULT_MAX_FACTS) -> list[Fact]:
    """Rule-based durable-fact extractor. Deterministic, no network."""
    candidates: list[tuple[float, Fact]] = []
    seen_tokens: list[set[str]] = []
    for index, message in enumerate(messages):
        role = str(message.get("role") or "user").strip().lower()
        content = message.get("content")
        if isinstance(content, list):
            content = " ".join(str(part.get("text", "")) if isinstance(part, dict) else str(part) for part in content)
        text = str(content or "")
        if role in ("tool", "function", "system"):
            continue
        role_weight = 1.0 if role == "user" else 0.75
        for sentence in _split_sentences(text):
            if any(pattern.search(sentence) for pattern in NOISE_PATTERNS):
                continue
            words = sentence.split()
            if len(words) < 4:
                continue
            score = 0.0
            kind = "fact"
            best_kind_score = 0.0
            for cue_kind, pattern, weight in CUE_PATTERNS:
                if pattern.search(sentence):
                    score += weight
                    if weight > best_kind_score:
                        best_kind_score = weight
                        kind = cue_kind
            identifiers = len(IDENTIFIER_RE.findall(sentence)) + len(PATH_RE.findall(sentence))
            score += min(identifiers, 3) * 0.35
            if VERSION_RE.search(sentence):
                score += 0.25
            if re.search(r"\b(I|we|you)\b", sentence) and kind in ("fact", "other"):
                score += 0.1
            if len(words) > 60:
                score -= 0.5
            score *= role_weight
            if score < 0.75:
                continue
            tokens = set(tokenize(sentence))
            if any(_jaccard(tokens, prior) >= 0.8 for prior in seen_tokens):
                continue
            seen_tokens.append(tokens)
            confidence = _clamp(0.45 + 0.15 * score, 0.45, 0.95)
            fact = Fact(
                text=sentence,
                kind=kind,
                confidence=round(confidence, 3),
                scope=None,
                tags=[],
                entities=extract_entities(sentence),
                source_ref=f"m{index}",
            )
            candidates.append((score, fact))
    candidates.sort(key=lambda item: -item[0])
    return [fact for _, fact in candidates[:max_facts]]


def parse_llm_facts(raw_output: str) -> list[Fact]:
    text = (raw_output or "").strip()
    if not text:
        return []
    try:
        payload = json.loads(text)
    except ValueError:
        payload = None
    if isinstance(payload, dict) and isinstance(payload.get("result"), str):
        # `claude -p --output-format json` wraps the model text in {result: "..."}.
        return parse_llm_facts(payload["result"])
    if isinstance(payload, dict) and isinstance(payload.get("memories"), list):
        payload = payload["memories"]
    if not isinstance(payload, list):
        start, end = text.find("["), text.rfind("]")
        if start < 0 or end <= start:
            return []
        try:
            payload = json.loads(text[start : end + 1])
        except ValueError:
            return []
    facts: list[Fact] = []
    for item in payload if isinstance(payload, list) else []:
        fact = Fact.from_mapping(item)
        if fact is not None:
            facts.append(fact)
    return facts


def claude_cli_extract(transcript: str, max_facts: int, timeout: float = 120.0) -> list[Fact]:
    prompt = EXTRACT_PROMPT.format(max_facts=max_facts, transcript=transcript)
    try:
        completed = subprocess.run(
            ["claude", "-p", prompt, "--output-format", "json"],
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise RuntimeError(f"claude extractor unavailable: {exc}") from exc
    if completed.returncode != 0:
        raise RuntimeError(f"claude extractor failed ({completed.returncode}): {completed.stderr[:300]}")
    return parse_llm_facts(completed.stdout)


def ollama_extract(transcript: str, max_facts: int, model: str, base_url: str, timeout: float = 120.0) -> list[Fact]:
    prompt = EXTRACT_PROMPT.format(max_facts=max_facts, transcript=transcript)
    request = urllib.request.Request(
        base_url.rstrip("/") + "/api/generate",
        data=json.dumps({"model": model, "prompt": prompt, "stream": False, "format": "json"}).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:  # noqa: S310 — loopback URL from config
            payload = json.loads(response.read().decode("utf-8"))
    except (urllib.error.URLError, OSError, ValueError) as exc:
        raise RuntimeError(f"ollama extractor unavailable: {exc}") from exc
    return parse_llm_facts(str(payload.get("response") or ""))


ExtractorFn = Callable[[str, int], list[Fact]]


def gate_transcript(transcript: str, *, pii_policy: str = "keep") -> tuple[str | None, dict[str, Any]]:
    """Gate a rendered transcript before it leaves the process.

    Returns (safe transcript or None, report). The transcript is withheld
    (None) when the scanner corpus is unavailable or a secret only appears in a
    joined form that cannot be redacted in place; otherwise secrets are
    redacted and the redacted rendering is returned.
    """
    findings = scan_text(transcript, pii_policy=pii_policy)
    if not findings.corpus_available:
        return None, {
            "redacted": False,
            "withheld": True,
            "reason": "secret scanner corpus unavailable; transcript withheld from the external extractor",
            "labels": [],
        }
    if findings.unlocalizable_labels:
        return None, {
            "redacted": False,
            "withheld": True,
            "reason": "secret detected in a joined or continued form that cannot be redacted; transcript withheld from the external extractor",
            "labels": findings.secret_labels,
        }
    if findings.has_pii and pii_policy == "reject":
        return None, {
            "redacted": False,
            "withheld": True,
            "reason": "PII policy is reject; transcript withheld from the external extractor",
            "labels": findings.pii_labels,
        }
    return findings.redacted_text, {
        "redacted": findings.redacted_text != transcript,
        "withheld": False,
        "reason": None,
        "labels": sorted(set(findings.secret_labels + findings.pii_labels)),
    }


class BoundExtractor:
    """A frontier-model extractor bound lazily to the router.

    Resolution happens on the first call so a refusal (no policy, no Pro, no
    consent, no budget) surfaces as a typed `ModelUnavailable` inside
    `memorize`'s try/except and degrades to the heuristic path with a reason.
    """

    name = "pro"

    def __init__(self, models: Any, provider_hint: str | None = None) -> None:
        self.models = models
        self.provider_hint = provider_hint
        self.provenance: dict[str, Any] | None = None

    def __call__(self, transcript: str, max_facts: int) -> list[Fact]:
        from .providers import ModelUnavailable

        if self.models is None:
            raise ModelUnavailable(
                "CLOUD_CONSENT_REQUIRED", "no memory model policy (cloud models are off or the daemon is unavailable)"
            )
        call = self.models.call("memory-extract", self.provider_hint)
        facts, self.provenance = llm_extract(call, transcript, max_facts)
        return facts


def llm_extract(call: Any, transcript: str, max_facts: int) -> tuple[list[Fact], dict[str, Any]]:
    """Extract with a frontier model through a `ModelCall`; returns facts and provenance."""
    started = time.monotonic()
    parsed, usage = call.json(
        EXTRACT_PROMPT_V2_SYSTEM.replace("{max_facts}", str(max(1, min(int(max_facts), 64)))),
        EXTRACT_PROMPT_V2_USER.format(transcript=transcript),
        max_tokens=2_048,
    )
    raw_facts = parsed.get("facts") if isinstance(parsed, dict) else None
    evidence_lines = len(_EVIDENCE_MARKER.findall(transcript))
    facts: list[Fact] = []
    dropped_ungrounded = 0
    if isinstance(raw_facts, list):
        for item in raw_facts:
            # The v2 contract requires every fact to cite the [m<n>] line it came
            # from; a hallucinated or unplaceable fact never reaches the store.
            index = item.get("evidence_message_index") if isinstance(item, dict) else None
            if isinstance(index, bool) or not isinstance(index, int) or not 1 <= index <= evidence_lines:
                dropped_ungrounded += 1
                continue
            fact = Fact.from_mapping(item)
            if fact is not None:
                facts.append(fact)
    provenance = {
        "provider": call.provider,
        "model": call.model,
        "label": call.label,
        "promptVersion": EXTRACT_PROMPT_VERSION,
        "latencyMs": int((time.monotonic() - started) * 1_000),
        "usage": dict(usage or {}),
        "droppedUngrounded": dropped_ungrounded,
    }
    return facts[: max(1, min(int(max_facts), 64))], provenance


def resolve_extractor(
    name: str | None, override: ExtractorFn | None = None, *, models: Any = None
) -> tuple[str, ExtractorFn | None]:
    if override is not None:
        return (name or "custom"), override
    configured = (name or os.environ.get(EXTRACTOR_ENV, "heuristic")).strip().lower() or "heuristic"
    if configured == "pro" or configured.startswith("pro:"):
        hint = configured.split(":", 1)[1].strip() or None if ":" in configured else None
        return "pro", BoundExtractor(models, hint)
    if configured in ("none", "raw"):
        return "none", None
    if configured == "claude":
        return "claude", claude_cli_extract
    if configured == "ollama":
        model = os.environ.get("OPENBURNBAR_MEMORY_EXTRACTOR_MODEL", "").strip() or "llama3.2"
        base_url = os.environ.get(OLLAMA_BASE_URL_ENV, DEFAULT_OLLAMA_BASE_URL)
        return "ollama", lambda transcript, max_facts: ollama_extract(transcript, max_facts, model, base_url)
    return "heuristic", None
