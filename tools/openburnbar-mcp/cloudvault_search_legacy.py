"""Named rollback implementation for local-MCP CloudVault search transforms."""

from __future__ import annotations

import hashlib
import hmac
import re

OPENBURNBAR_TOKEN_SEARCH_SALT = b"OpenBurnBar-CloudSearch-Salt-v1"
OPENBURNBAR_TOKEN_SEARCH_INFO = b"OpenBurnBar-CloudSearch-TokenHash-v1"
OPENBURNBAR_SEMANTIC_SEARCH_SALT = b"OpenBurnBar-CloudSearch-Semantic-Salt-v1"
OPENBURNBAR_SEMANTIC_SEARCH_INFO = b"OpenBurnBar-CloudSearch-SemanticHash-v1"
OPENBURNBAR_STOPWORDS = {
    "the",
    "and",
    "for",
    "with",
    "that",
    "this",
    "from",
    "how",
    "what",
    "where",
    "when",
    "why",
    "are",
    "was",
    "were",
    "you",
    "your",
    "have",
    "has",
    "had",
    "into",
    "onto",
    "can",
    "could",
    "should",
    "would",
}


def _hkdf_sha256(input_key: bytes, salt: bytes, info: bytes, length: int) -> bytes:
    effective_salt = salt if salt else bytes(32)
    prk = hmac.new(effective_salt, input_key, hashlib.sha256).digest()
    output = b""
    previous = b""
    counter = 1
    while len(output) < length:
        previous = hmac.new(prk, previous + info + bytes([counter]), hashlib.sha256).digest()
        output += previous
        counter += 1
    return output[:length]


def _cloud_normalized_tokens(text: str) -> list[str]:
    tokens = re.split(r"[^a-z0-9]+", text.lower())
    return [token for token in tokens if len(token) >= 2 and token not in OPENBURNBAR_STOPWORDS]


def _cloud_token_hashes(text: str, vault_key: bytes, limit: int = 10) -> list[str]:
    search_key = _hkdf_sha256(vault_key, OPENBURNBAR_TOKEN_SEARCH_SALT, OPENBURNBAR_TOKEN_SEARCH_INFO, 32)
    seen: set[str] = set()
    hashes: list[str] = []
    for token in _cloud_normalized_tokens(text):
        if token in seen:
            continue
        seen.add(token)
        hashes.append(hmac.new(search_key, token.encode("utf-8"), hashlib.sha256).digest()[:16].hex())
        if len(hashes) >= limit:
            break
    return hashes


def _simple_semantic_stem(token: str) -> str:
    suffixes = [
        "ization",
        "ations",
        "ation",
        "ments",
        "ment",
        "ingly",
        "edly",
        "ing",
        "ies",
        "ied",
        "ers",
        "er",
        "ed",
        "s",
    ]
    for suffix in suffixes:
        if len(token) > len(suffix) + 3 and token.endswith(suffix):
            stem = token[: -len(suffix)]
            return stem + "y" if suffix in {"ies", "ied"} else stem
    return token


def _cloud_semantic_features(tokens: list[str]) -> list[tuple[str, float]]:
    features: list[tuple[str, float]] = []
    seen: set[str] = set()

    def append(name: str, weight: float) -> None:
        if name and name not in seen:
            seen.add(name)
            features.append((name, weight))

    for token in tokens:
        append(f"token:{token}", 2.4)
        stem = _simple_semantic_stem(token)
        if stem != token:
            append(f"stem:{stem}", 1.8)
        if len(token) >= 5:
            append(f"prefix:{token[:5]}", 0.8)
    for index in range(0, max(0, len(tokens) - 1)):
        append(f"bigram:{tokens[index]}_{tokens[index + 1]}", 1.3)
    return features


def _cloud_semantic_hashes(text: str, vault_key: bytes, limit: int = 12) -> list[str]:
    tokens = _cloud_normalized_tokens(text)
    if not tokens or limit <= 0:
        return []
    search_key = _hkdf_sha256(vault_key, OPENBURNBAR_SEMANTIC_SEARCH_SALT, OPENBURNBAR_SEMANTIC_SEARCH_INFO, 32)
    features = _cloud_semantic_features(tokens)
    accumulator = [0.0] * 64
    for name, weight in features:
        digest = hmac.new(search_key, name.encode("utf-8"), hashlib.sha256).digest()
        index = ((digest[0] << 8) | digest[1]) % 64
        accumulator[index] += (1.0 if (digest[2] & 1) == 0 else -1.0) * weight
    hashes: list[str] = []
    seen: set[str] = set()

    def append_bucket(bucket: str) -> None:
        if len(hashes) >= limit:
            return
        digest = hmac.new(search_key, bucket.encode("utf-8"), hashlib.sha256).digest()[:16].hex()
        if digest not in seen:
            seen.add(digest)
            hashes.append(digest)

    for band in range(8):
        value = 0
        for bit in range(8):
            if accumulator[band * 8 + bit] >= 0:
                value |= 1 << bit
        append_bucket(f"simhash:v1:band:{band}:{value:02x}")
    for name, _weight in features[: max(0, limit - len(hashes))]:
        append_bucket(f"feature:v1:{name}")
    return hashes
