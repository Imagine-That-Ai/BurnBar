"""Tokenizer, in-process BM25, and the snippet/token-budget helpers.

There is deliberately no FTS table on disk: BM25 runs over the decrypted active
bodies of one project."""

from __future__ import annotations

import contextlib
import math
import re
from collections.abc import Iterable, Sequence

import project_code_memory as pcm

from .constants import STOPWORDS


_CAMEL_RE = re.compile(r"(?<=[a-z0-9])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])")
_TOKEN_RE = re.compile(r"[A-Za-z0-9]+")


_ACRONYM_PLURAL_RE = re.compile(r"^([A-Z]{2,})s$")


def _stem(token: str) -> str:
    """Light, consistent stemmer (Porter-lite). Consistency matters more than
    linguistic correctness: `_stem("tables") == _stem("table")`."""
    if len(token) <= 2 or not token.isalpha():
        return token
    word = token
    # Plurals first.
    if word.endswith("ies") and len(word) > 4:
        word = word[:-3] + "y"
    elif word.endswith("sses"):
        word = word[:-2]
    elif word.endswith("es") and len(word) > 4 and (word[-3] in "xz" or word.endswith(("ches", "shes", "sses"))):
        word = word[:-2]
    elif word.endswith("s") and not word.endswith("ss") and len(word) > 3:
        word = word[:-1]
    # Common derivational suffixes.
    for suffix in ("ingly", "edly", "ing", "ed", "ly", "ence", "ance", "ness", "ment"):
        if word.endswith(suffix) and len(word) - len(suffix) >= 2:
            word = word[: -len(suffix)]
            break
    # Trailing 'e' so use/uses/used/using and store/stores/stored agree.
    if len(word) >= 3 and word.endswith("e"):
        word = word[:-1]
    return word


def tokenize(text: str) -> list[str]:
    """Code-aware tokenizer: splits camelCase/snake_case, keeps the joined identifier too."""
    out: list[str] = []
    for raw in re.split(r"[^A-Za-z0-9_./\-]+", text or ""):
        if not raw:
            continue
        lowered = raw.lower().strip("._/-")
        if not lowered:
            continue
        subparts = [part for part in re.split(r"[._/\-]+", raw) if part]
        expanded: list[str] = []
        for part in subparts:
            acronym = _ACRONYM_PLURAL_RE.match(part)
            if acronym:
                expanded.append(acronym.group(1))  # "PRs" → "PR", never "P" + "Rs"
                continue
            expanded.extend(piece for piece in _CAMEL_RE.split(part) if piece)
        pieces = [piece.lower() for piece in expanded]
        if len(pieces) > 1 and len(lowered) <= 48:
            out.append(lowered)
        for piece in pieces:
            for token in _TOKEN_RE.findall(piece):
                if len(token) < 2 or token in STOPWORDS:
                    continue
                out.append(_stem(token))
    return out


def _jaccard(a: Iterable[str], b: Iterable[str]) -> float:
    sa, sb = set(a), set(b)
    if not sa or not sb:
        return 0.0
    return len(sa & sb) / len(sa | sb)


class BM25:
    def __init__(self, docs: dict[str, list[str]], k1: float = 1.2, b: float = 0.75) -> None:
        self.k1 = k1
        self.b = b
        self.docs = docs
        self.doc_len = {doc_id: len(tokens) for doc_id, tokens in docs.items()}
        self.avgdl = (sum(self.doc_len.values()) / len(docs)) if docs else 0.0
        self.df: dict[str, int] = {}
        self.tf: dict[str, dict[str, int]] = {}
        for doc_id, tokens in docs.items():
            counts: dict[str, int] = {}
            for token in tokens:
                counts[token] = counts.get(token, 0) + 1
            self.tf[doc_id] = counts
            for token in counts:
                self.df[token] = self.df.get(token, 0) + 1
        self.n = len(docs)

    def idf(self, token: str) -> float:
        df = self.df.get(token, 0)
        return math.log(1 + (self.n - df + 0.5) / (df + 0.5))

    def score(self, query_tokens: Sequence[str], doc_id: str) -> float:
        counts = self.tf.get(doc_id)
        if not counts:
            return 0.0
        dl = self.doc_len.get(doc_id, 0)
        norm = self.k1 * (1 - self.b + self.b * (dl / self.avgdl if self.avgdl else 0.0))
        total = 0.0
        for token in set(query_tokens):
            tf = counts.get(token, 0)
            if tf == 0:
                continue
            total += self.idf(token) * (tf * (self.k1 + 1)) / (tf + norm)
        return total

    def rank(self, query_tokens: Sequence[str], limit: int) -> list[tuple[str, float]]:
        scored = [(doc_id, self.score(query_tokens, doc_id)) for doc_id in self.docs]
        scored = [item for item in scored if item[1] > 0]
        scored.sort(key=lambda item: (-item[1], item[0]))
        return scored[:limit]


def _snippet(body: str, query_tokens: Sequence[str], max_chars: int = 240) -> str:
    collapsed = re.sub(r"\s+", " ", body).strip()
    if len(collapsed) <= max_chars:
        return collapsed
    lowered = collapsed.lower()
    for token in query_tokens:
        index = lowered.find(token[:6])
        if index >= 0:
            start = max(0, index - 80)
            end = min(len(collapsed), index + max_chars - 80)
            return ("…" if start > 0 else "") + collapsed[start:end].strip() + ("…" if end < len(collapsed) else "")
    return collapsed[: max_chars - 1].rstrip() + "…"


def _estimate_tokens(text: str) -> int:
    encoder = pcm._context_token_encoder()
    if encoder is not None:
        with contextlib.suppress(Exception):
            return len(encoder.encode(text))
    return max(1, len(text) // 4)
