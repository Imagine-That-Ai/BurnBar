"""Named rollback implementation for local-MCP CloudVault transforms.

Keep this module path-addressable until the shared-Rust crypto deletion gate.
It must not acquire I/O, credential, or persistence responsibilities.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import os
import re
from datetime import UTC, datetime
from typing import Any

OPENBURNBAR_TOKEN_SEARCH_SALT = b"OpenBurnBar-CloudSearch-Salt-v1"
OPENBURNBAR_TOKEN_SEARCH_INFO = b"OpenBurnBar-CloudSearch-TokenHash-v1"
OPENBURNBAR_SEMANTIC_SEARCH_SALT = b"OpenBurnBar-CloudSearch-Semantic-Salt-v1"
OPENBURNBAR_SEMANTIC_SEARCH_INFO = b"OpenBurnBar-CloudSearch-SemanticHash-v1"
OPENBURNBAR_DOC_ID_SALT = b"OpenBurnBar-DocID-Salt-v1"
OPENBURNBAR_PROJECT_MEMORY_DOC_ID_INFO = b"OpenBurnBar-ProjectMemory-DocID-v1"
OPENBURNBAR_CLOUD_VAULT_AAD_PREFIX = "OpenBurnBar-CloudVault-aad-v2"
OPENBURNBAR_CLOUD_VAULT_BLOB_AAD_CONTEXT = "OpenBurnBar-CloudVaultBlob-v2"
OPENBURNBAR_CLOUD_VAULT_HMAC_SALT = b"OpenBurnBar-CloudVault-HMAC-Salt-v1"
OPENBURNBAR_CLOUD_VAULT_HMAC_INFO_PREFIX = b"OpenBurnBar-CloudVault-HMAC-v1"
OPENBURNBAR_STOPWORDS = {
    "the", "and", "for", "with", "that", "this", "from", "how", "what",
    "where", "when", "why", "are", "was", "were", "you", "your", "have",
    "has", "had", "into", "onto", "can", "could", "should", "would",
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


def _cloud_vault_aad_part(value: str, name: str) -> str:
    if not value or "|" in value or any(ord(ch) < 0x20 or ord(ch) == 0x7F for ch in value):
        raise ValueError(f"invalid CloudVault AAD {name}")
    return value


def _cloud_vault_aad_context(
    uid: str,
    collection: str,
    doc_id: str,
    field: str,
    schema_version: int = 2,
    purpose: str | None = None,
) -> str:
    if schema_version < 2:
        raise ValueError("invalid CloudVault AAD schema version")
    purpose_value = purpose or field
    return "|".join([
        OPENBURNBAR_CLOUD_VAULT_AAD_PREFIX,
        _cloud_vault_aad_part(uid, "uid"),
        _cloud_vault_aad_part(collection, "collection"),
        _cloud_vault_aad_part(doc_id, "docID"),
        _cloud_vault_aad_part(field, "field"),
        str(schema_version),
        _cloud_vault_aad_part(purpose_value, "purpose"),
    ])


def _validate_cloud_vault_aad(value: str) -> str:
    parts = value.split("|")
    if len(parts) != 7 or parts[0] != OPENBURNBAR_CLOUD_VAULT_AAD_PREFIX:
        raise ValueError("invalid CloudVault AAD context")
    _cloud_vault_aad_part(parts[1], "uid")
    _cloud_vault_aad_part(parts[2], "collection")
    _cloud_vault_aad_part(parts[3], "docID")
    _cloud_vault_aad_part(parts[4], "field")
    if not parts[5].isdigit() or int(parts[5]) < 2:
        raise ValueError("invalid CloudVault AAD schema version")
    _cloud_vault_aad_part(parts[6], "purpose")
    return value


def _cloud_vault_hmac_hex(data: bytes, vault_key: bytes, purpose: str) -> str:
    hmac_key = _hkdf_sha256(
        vault_key,
        OPENBURNBAR_CLOUD_VAULT_HMAC_SALT,
        OPENBURNBAR_CLOUD_VAULT_HMAC_INFO_PREFIX + b"|" + purpose.encode("utf-8"),
        32,
    )
    return hmac.new(hmac_key, data, hashlib.sha256).hexdigest()


def _cloud_vault_project_memory_doc_id(project_slug: str, vault_key: bytes) -> str:
    doc_id_key = _hkdf_sha256(
        vault_key, OPENBURNBAR_DOC_ID_SALT, OPENBURNBAR_PROJECT_MEMORY_DOC_ID_INFO, 32
    )
    digest = hmac.new(doc_id_key, project_slug.encode("utf-8"), hashlib.sha256).digest()
    return "pm_" + digest[:16].hex()


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
    suffixes = ["ization", "ations", "ation", "ments", "ment", "ingly", "edly", "ing", "ies", "ied", "ers", "er", "ed", "s"]
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


def _aesgcm_open(nonce: bytes, ciphertext_and_tag: bytes, key: bytes, aad: bytes | None = None) -> bytes:
    try:
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    except ImportError as exc:
        raise RuntimeError("install cryptography to decrypt OpenBurnBar cloud data") from exc
    return AESGCM(key).decrypt(nonce, ciphertext_and_tag, aad)


def _open_cloud_sealed_text(envelope: dict[str, Any], vault_key: bytes, expected_aad: str | None = None) -> str:
    if envelope.get("algorithm") != "AES-256-GCM":
        raise ValueError("unsupported sealed text algorithm")
    nonce = base64.b64decode(str(envelope["nonce"]))
    ciphertext = base64.b64decode(str(envelope["ciphertext"]))
    tag = base64.b64decode(str(envelope["tag"]))
    schema_version = int(envelope.get("schemaVersion") or 1)
    aad_bytes: bytes | None = None
    if schema_version >= 2:
        if not expected_aad or envelope.get("aad") != expected_aad:
            raise ValueError("sealed text AAD context mismatch")
        aad_bytes = expected_aad.encode("utf-8")
    return _aesgcm_open(nonce, ciphertext + tag, vault_key, aad_bytes).decode("utf-8")


def _open_cloud_blob_envelope(envelope: dict[str, Any], vault_key: bytes, expected_aad: str | None = None) -> bytes:
    if envelope.get("algorithm") != "AES-256-GCM":
        raise ValueError("unsupported blob algorithm")
    combined = base64.b64decode(str(envelope["sealedBoxBase64"]))
    if len(combined) <= 28:
        raise ValueError("encrypted blob envelope is too short")
    schema_version = int(envelope.get("schemaVersion") or 1)
    aad_bytes: bytes | None = None
    if schema_version >= 2:
        envelope_aad = str(envelope.get("aad", ""))
        if envelope_aad != OPENBURNBAR_CLOUD_VAULT_BLOB_AAD_CONTEXT:
            if not expected_aad or envelope_aad != expected_aad:
                raise ValueError("encrypted blob AAD context mismatch")
            aad_bytes = _validate_cloud_vault_aad(expected_aad).encode("utf-8")
    plaintext = _aesgcm_open(combined[:12], combined[12:], vault_key, aad_bytes)
    if schema_version >= 2:
        if int(envelope.get("integrityHashVersion") or 0) != 1:
            raise ValueError("encrypted blob integrity version mismatch")
        if _cloud_vault_hmac_hex(plaintext, vault_key, "blob-integrity") != str(envelope.get("plaintextHMAC", "")):
            raise ValueError("encrypted blob HMAC mismatch")
    elif hashlib.sha256(plaintext).hexdigest() != str(envelope.get("plaintextSHA256", "")):
        raise ValueError("encrypted blob SHA-256 mismatch")
    return plaintext


def _seal_cloud_blob_envelope(
    plaintext: bytes,
    vault_key: bytes,
    key_version: int = 1,
    aad_context: str | None = None,
    *,
    nonce: bytes | None = None,
    created_at: str | None = None,
) -> dict[str, Any]:
    try:
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    except ImportError as exc:
        raise RuntimeError("install cryptography to seal OpenBurnBar cloud payloads") from exc
    nonce = nonce or os.urandom(12)
    aad = _validate_cloud_vault_aad(aad_context).encode("utf-8") if aad_context else None
    combined = nonce + AESGCM(vault_key).encrypt(nonce, plaintext, aad)
    return {
        "schemaVersion": 2,
        "algorithm": "AES-256-GCM",
        "keyVersion": int(key_version),
        "plaintextHMAC": _cloud_vault_hmac_hex(plaintext, vault_key, "blob-integrity"),
        "integrityHashVersion": 1,
        "sealedBoxBase64": base64.b64encode(combined).decode("utf-8"),
        "createdAt": created_at or datetime.now(UTC).isoformat().replace("+00:00", "Z"),
        "aad": aad_context or OPENBURNBAR_CLOUD_VAULT_BLOB_AAD_CONTEXT,
    }
