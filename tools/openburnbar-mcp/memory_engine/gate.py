"""The secret / PII gate: detection over the raw text and its encoded views,
then the redact / reject / retain policy."""

from __future__ import annotations

import base64
import binascii
import json
import re
from collections.abc import Sequence
from dataclasses import dataclass, field
from typing import Any

import project_code_memory as pcm

from ._util import _aux_strings
from .constants import ALWAYS_REDACT_PII_LABELS, INJECTION_PATTERNS


@dataclass
class GatePattern:
    label: str
    kind: str
    pattern: re.Pattern[str]


def _compile_gate_patterns() -> tuple[list[GatePattern], bool]:
    try:
        corpus = pcm._load_secret_corpus()
    except (OSError, json.JSONDecodeError):
        corpus = None
    if not corpus:
        return [], False
    compiled: list[GatePattern] = []
    try:
        for spec in corpus.get("patterns", []):
            flags = 0
            if spec.get("caseInsensitive"):
                flags |= re.IGNORECASE
            if spec.get("dotMatchesNewlines"):
                flags |= re.DOTALL
            if spec.get("anchorsMatchLines"):
                flags |= re.MULTILINE
            kind = str(spec.get("kind") or "secret").lower()
            compiled.append(
                GatePattern(
                    str(spec["label"]), "pii" if kind == "pii" else "secret", re.compile(str(spec["regex"]), flags)
                )
            )
    except (KeyError, TypeError, re.error):
        return [], False
    return compiled, True


GATE_PATTERNS, GATE_CORPUS_AVAILABLE = _compile_gate_patterns()


@dataclass
class GateFindings:
    secret_labels: list[str] = field(default_factory=list)
    pii_labels: list[str] = field(default_factory=list)
    redacted_text: str = ""
    corpus_available: bool = True
    # Secret labels found only in a joined / continued view of the text. They
    # have no single surface span, so `redacted_text` still contains them.
    unlocalizable_labels: list[str] = field(default_factory=list)

    @property
    def has_secret(self) -> bool:
        return bool(self.secret_labels)

    @property
    def has_pii(self) -> bool:
        return bool(self.pii_labels)


_LINE_CONTINUATION_RE = re.compile(r"\\\s*\n\s*")
_JOINED_STRING_LITERAL_RE = re.compile(r"[\"']\s*(?:\\\s*)?\n\s*[\"']")


def _joined_views(text: str) -> list[str]:
    """Views of `text` with line continuations and adjacent string literals joined.

    Mirrors `project_code_memory._secret_scan_views` minus the decoded views,
    which `_redact_encoded_secrets` handles span by span.
    """
    views: list[str] = []
    joined = _LINE_CONTINUATION_RE.sub("", text)
    if joined != text:
        views.append(joined)
    literals = _JOINED_STRING_LITERAL_RE.sub("", text)
    if literals != text and literals not in views:
        views.append(literals)
    return views


def _decode_base64_candidate(raw: str, limit: int) -> str | None:
    padded = raw + ("=" * ((4 - len(raw) % 4) % 4))
    try:
        decoded = base64.b64decode(padded, validate=True)
    except (binascii.Error, ValueError):
        return None
    if 0 < len(decoded) <= limit:
        return decoded.decode("utf-8", errors="replace")
    return None


def _decode_hex_candidate(raw: str, limit: int) -> str | None:
    if len(raw) % 2:
        raw = raw[:-1]
    try:
        decoded = bytes.fromhex(raw)
    except ValueError:
        return None
    if 0 < len(decoded) <= limit:
        return decoded.decode("utf-8", errors="replace")
    return None


def _redact_encoded_secrets(text: str) -> tuple[list[str], str]:
    """Decode base64 / hex candidates one token at a time and redact the ones
    that decode to a corpus secret. Returns (labels, redacted text)."""
    labels: list[str] = []
    config = getattr(pcm, "SECRET_DECODING_CONFIG", {}) or {}
    if not config.get("enabled", False):
        return labels, text
    max_candidates = int(config.get("maxCandidates") or 32)
    max_decoded = int(config.get("maxDecodedBytes") or 8192)
    spans: list[tuple[int, int, str]] = []
    seen = 0
    for regex, decoder in (
        (pcm.BASE64_SECRET_CANDIDATE_RE, _decode_base64_candidate),
        (pcm.HEX_SECRET_CANDIDATE_RE, _decode_hex_candidate),
    ):
        for match in regex.finditer(text):
            if seen >= max_candidates:
                break
            seen += 1
            decoded = decoder(match.group(0), max_decoded)
            if not decoded:
                continue
            for entry in GATE_PATTERNS:
                if entry.kind == "secret" and entry.pattern.search(decoded):
                    labels.append(entry.label)
                    spans.append((match.start(), match.end(), entry.label))
                    break
    if not spans:
        return labels, text
    spans.sort()
    merged: list[tuple[int, int, str]] = []
    for start, end, label in spans:
        if merged and start < merged[-1][1]:
            continue
        merged.append((start, end, label))
    out = text
    for start, end, label in reversed(merged):
        out = out[:start] + f"[REDACTED:{label} (encoded)]" + out[end:]
    return labels, out


def scan_text(text: str, pii_policy: str = "keep") -> GateFindings:
    """Scan `text`; return typed labels and a redacted rendering.

    Secrets are always redacted in `redacted_text`, including secrets that only
    appear after base64 / hex decoding (the encoded surface token is replaced).
    Secrets that only appear once line continuations or adjacent string
    literals are joined have no single surface span; they are reported in
    `unlocalizable_labels` so the caller can refuse the write. PII is redacted
    in `redacted_text` only when `pii_policy != "keep"` or the label is in
    `ALWAYS_REDACT_PII_LABELS`.
    """
    if not GATE_CORPUS_AVAILABLE:
        return GateFindings(
            secret_labels=[pcm.SCANNER_CORPUS_UNAVAILABLE_LABEL], redacted_text=text, corpus_available=False
        )
    findings = GateFindings(redacted_text=text)
    out = text
    for entry in GATE_PATTERNS:
        if not entry.pattern.search(out):
            continue
        if entry.kind == "secret":
            findings.secret_labels.append(entry.label)
            out = entry.pattern.sub(f"[REDACTED:{entry.label}]", out)
        else:
            findings.pii_labels.append(entry.label)
            if pii_policy != "keep" or entry.label in ALWAYS_REDACT_PII_LABELS:
                out = entry.pattern.sub(f"[REDACTED:{entry.label}]", out)
    encoded_labels, out = _redact_encoded_secrets(out)
    findings.secret_labels.extend(encoded_labels)
    for view in _joined_views(text):
        for entry in GATE_PATTERNS:
            if entry.kind == "secret" and entry.pattern.search(view) and not entry.pattern.search(text):
                findings.secret_labels.append(entry.label)
                findings.unlocalizable_labels.append(entry.label)
    entropy_labels = pcm._entropy_labels(text)
    if entropy_labels:
        findings.secret_labels.extend(entropy_labels)
        out = pcm.SECRET_LIKE_TOKEN_RE.sub(
            lambda match: (
                match.group(0)
                if len(match.group(0)) < 32 or _looks_like_prose(match.group(0))
                else "[REDACTED:High entropy token]"
            ),
            out,
        )
    findings.secret_labels = sorted(set(findings.secret_labels))
    findings.pii_labels = sorted(set(findings.pii_labels))
    findings.unlocalizable_labels = sorted(set(findings.unlocalizable_labels))
    findings.redacted_text = out
    return findings


def _looks_like_prose(token: str) -> bool:
    return pcm._shannon_entropy(token) < 4.2 or "-" in token and token.count("-") > 3


@dataclass
class GateDecision:
    action: str  # keep | redact | reject | retain
    sensitivity: str  # none | pii | redacted | secret
    body: str  # what is stored in `memories` (indexable)
    vault_body: str | None  # verbatim body stored in the vault (retain only)
    labels: list[str]
    reason: str | None = None


def apply_gate(text: str, *, secret_policy: str, pii_policy: str, retain_allowed: bool) -> GateDecision:
    findings = scan_text(text, pii_policy=pii_policy)
    labels = findings.secret_labels + findings.pii_labels
    if not findings.corpus_available:
        return GateDecision("reject", "none", text, None, labels, "secret scanner corpus unavailable; failing closed")
    if findings.has_secret:
        if secret_policy == "reject":  # noqa: S105 — policy selector, not a credential
            return GateDecision("reject", "secret", "", None, labels, "secret policy is reject")
        if secret_policy == "retain":  # noqa: S105 — policy selector, not a credential
            if not retain_allowed:
                return GateDecision(
                    "reject",
                    "secret",
                    "",
                    None,
                    labels,
                    "secret policy is retain but the memory_secret_retain capability is disabled",
                )
            body = findings.redacted_text
            if findings.unlocalizable_labels:
                # The verbatim body goes to the vault; the indexable body must not
                # carry a secret we cannot point at, so it is withheld entirely.
                body = (
                    "[REDACTED:" + ", ".join(findings.unlocalizable_labels) + "] secret-bearing memory; body withheld"
                )
            return GateDecision("retain", "secret", body, text, labels)
        if findings.unlocalizable_labels:
            return GateDecision(
                "reject",
                "secret",
                "",
                None,
                labels,
                "secret detected in a joined or continued form that cannot be redacted in place; rephrase without the secret",
            )
        return GateDecision("redact", "redacted", findings.redacted_text, None, labels)
    if findings.has_pii:
        if pii_policy == "reject":
            return GateDecision("reject", "pii", "", None, labels, "pii policy is reject")
        if pii_policy == "redact" or any(label in ALWAYS_REDACT_PII_LABELS for label in findings.pii_labels):
            return GateDecision("redact", "pii", findings.redacted_text, None, labels)
        return GateDecision("keep", "pii", text, None, labels)
    return GateDecision("keep", "none", text, None, [])


@dataclass
class AuxGate:
    """Gate outcome for the caller-controlled fields stored beside the body."""

    tags: list[str]
    entities: list[str]
    metadata: dict[str, Any]
    source_ref: str | None
    labels: list[str]
    reject_reason: str | None = None
    reject_code: str | None = None


def _gate_string(
    value: str, *, secret_policy: str, pii_policy: str
) -> tuple[str | None, list[str], str | None, str | None]:
    """Gate one auxiliary string. Returns (replacement or None to drop, labels, reject reason, reject code)."""
    findings = scan_text(value, pii_policy=pii_policy)
    if not findings.corpus_available:
        return None, findings.secret_labels, "secret scanner corpus unavailable; failing closed", "GATE_REJECTED"
    labels = findings.secret_labels + findings.pii_labels
    if findings.has_secret:
        if secret_policy == "reject":  # noqa: S105 — policy selector, not a credential
            return None, labels, "secret policy is reject", "SECRET_DETECTED"
        if findings.unlocalizable_labels:
            return None, labels, None, None
        return findings.redacted_text, labels, None, None
    if findings.has_pii:
        if pii_policy == "reject":
            return None, labels, "pii policy is reject", "GATE_REJECTED"
        if pii_policy == "redact" or any(label in ALWAYS_REDACT_PII_LABELS for label in findings.pii_labels):
            return findings.redacted_text, labels, None, None
    return value, labels, None, None


def gate_aux_fields(
    *,
    tags: Sequence[str],
    entities: Sequence[str],
    metadata: dict[str, Any] | None,
    source_ref: str | None,
    secret_policy: str,
    pii_policy: str,
) -> AuxGate:
    """Apply the secret and PII gates to auxiliary fields.

    These columns are plaintext and are returned by get / list / recall /
    export, so they get the same policy as the body: secrets are redacted in
    place (a tag or entity that *is* a secret is dropped), `reject` refuses the
    write, and `retain` never applies here because there is no vault for
    auxiliary fields.
    """
    labels: list[str] = []
    reject_reason: str | None = None
    reject_code: str | None = None

    def gate(value: str) -> str | None:
        nonlocal reject_reason, reject_code
        replacement, found, reason, code = _gate_string(value, secret_policy=secret_policy, pii_policy=pii_policy)
        labels.extend(found)
        if reason and reject_reason is None:
            reject_reason, reject_code = reason, code
        return replacement

    def walk(value: Any) -> Any:
        if isinstance(value, str):
            replaced = gate(value)
            return "[REDACTED]" if replaced is None else replaced
        if isinstance(value, dict):
            return {(gate(str(key)) or "[REDACTED]"): walk(item) for key, item in value.items()}
        if isinstance(value, list):
            return [walk(item) for item in value]
        return value

    clean_tags = [tag for tag in tags if gate(tag) == tag]
    clean_entities = [item for item in entities if gate(item) == item]
    clean_metadata = walk(dict(metadata or {}))
    clean_ref: str | None = source_ref
    if source_ref:
        replaced = gate(source_ref)
        clean_ref = "[REDACTED]" if replaced is None else replaced
    return AuxGate(
        clean_tags,
        clean_entities,
        clean_metadata,
        clean_ref,
        sorted(set(labels)),
        reject_reason,
        reject_code,
    )


def injection_labels(text: str) -> list[str]:
    labels: list[str] = []
    for index, pattern in enumerate(INJECTION_PATTERNS):
        if pattern.search(text):
            labels.append(f"injection_sentinel_{index}")
    return labels


def auxiliary_injection_labels(
    tags: Sequence[str], entities: Sequence[str], metadata: dict[str, Any], source_ref: str | None
) -> list[str]:
    """Find injection sentinels in every caller-controlled auxiliary string."""
    return injection_labels("\n".join(_aux_strings(tags, entities, metadata, source_ref)))
