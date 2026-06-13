#!/usr/bin/env python3
"""
OpenBurnBar local MCP: read-only access to the OpenBurnBar macOS SQLite database (conversations, usage).

Install: ./setup.sh  (creates .venv and installs deps)

Configure Cursor / Claude Desktop to run:
  command: <repo>/tools/openburnbar-mcp/.venv/bin/python
  args: [ "<repo>/tools/openburnbar-mcp/server.py" ]

Optional env:
  BURNBAR_DB_PATH — override path to openburnbar.sqlite (default: ~/Library/Application Support/OpenBurnBar/openburnbar.sqlite)
"""

from __future__ import annotations

import json
import base64
import hashlib
import hmac
import math
import os
import re
import sqlite3
import string
import struct
import sys
import urllib.error
import urllib.request
from datetime import datetime, UTC
from pathlib import Path
from typing import Any

from mcp.server.fastmcp import FastMCP

# Make the sibling hermes_proxy module importable so the MCP server can share
# its idempotent ledger writer with the standalone proxy.
_THIS_DIR = Path(__file__).resolve().parent
if str(_THIS_DIR) not in sys.path:
    sys.path.insert(0, str(_THIS_DIR))

from burnbar_usage_ledger import (  # noqa: E402  — module import after sys.path tweak
    KNOWN_CONFIDENCE,
    KNOWN_PROVIDER_IDS,
    UsageEvent,
    append_usage_record,
    default_ledger_path,
    derive_idempotency_key,
)
from resume_core import (  # noqa: E402
    dispatch_resume,
    list_resumable_conversations,
    spawn_resume,
)

mcp = FastMCP("openburnbar-local")

DETERMINISTIC_EMBEDDING_PROVIDER = "openburnbar"
DETERMINISTIC_EMBEDDING_MODEL = "deterministic-fake-embedding"
DETERMINISTIC_EMBEDDING_DIMENSIONS = 96
DETERMINISTIC_EMBEDDING_VERSION_TAG = "ci-v1"
DETERMINISTIC_CHUNKER_VERSION = "openburnbar-chunker-v1"
DETERMINISTIC_NORMALIZATION_VERSION = "unit-l2-v1"
DETERMINISTIC_PROMPT_VERSION = "plain-text-v1"
DETERMINISTIC_EMBEDDING_SEED = "openburnbar-deterministic-embedding-seed-v1"
SEMANTIC_REQUIRED_TABLES = {
    "search_documents",
    "search_chunks",
    "chunk_embeddings",
    "embedding_models",
    "embedding_versions",
}
OPENBURNBAR_FIREBASE_PROJECT_ID = "burnbar"
OPENBURNBAR_FUNCTIONS_REGION = "us-central1"
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


def _sanitize_db_path(raw: str) -> Path:
    """
    Validate a developer-supplied SQLite path before opening it read-only.

    The MCP only ever opens this file in `mode=ro`, but we still constrain the
    input to: no NUL bytes, resolves to an absolute path, and the basename
    matches a conservative SQLite filename pattern. This neutralizes the
    py/path-injection taint flow CodeQL traces from the env var into sqlite3.
    """
    if "\x00" in raw:
        raise ValueError("BURNBAR_DB_PATH must not contain NUL bytes.")
    candidate = Path(raw).expanduser().resolve()
    if not candidate.is_absolute():
        raise ValueError("BURNBAR_DB_PATH must resolve to an absolute path.")
    if not re.fullmatch(r"[A-Za-z0-9._-]+\.sqlite[0-9]?", candidate.name):
        raise ValueError("BURNBAR_DB_PATH basename must match [A-Za-z0-9._-]+\\.sqlite[0-9]?")
    return candidate


def _default_db_path() -> Path:
    if env := os.environ.get("BURNBAR_DB_PATH", "").strip():
        return _sanitize_db_path(env)
    home = Path.home()
    support = home / "Library" / "Application Support"
    for app_dir in ("OpenBurnBar", "AgentLens"):
        base = support / app_dir
        for name in ("openburnbar.sqlite", "agentlens.sqlite"):
            p = base / name
            if p.is_file():
                return p
    return support / "OpenBurnBar" / "openburnbar.sqlite"


def _connect_ro(path: Path) -> sqlite3.Connection:
    if not path.is_file():
        raise FileNotFoundError(
            f"OpenBurnBar database not found at {path}. Open OpenBurnBar once or set BURNBAR_DB_PATH."
        )
    uri = f"file:{path}?mode=ro"
    return sqlite3.connect(uri, uri=True)
    # check_same_thread: default True; MCP tools run sync on one thread


def _connect_rw(path: Path) -> sqlite3.Connection:
    """Read-write SQLite connection for budget rule + event writes from Hermes / MCP.

    Used only by the budget mutation tools (`burnbar_set_budget_limit`,
    `burnbar_pause_budget_gate`, `burnbar_resume_budget_gate`). All other tools stay
    read-only via `_connect_ro` so an MCP misuse can never corrupt the conversation,
    usage, or operating-layer tables.
    """
    if not path.is_file():
        raise FileNotFoundError(
            f"OpenBurnBar database not found at {path}. Open OpenBurnBar once or set BURNBAR_DB_PATH."
        )
    conn = sqlite3.connect(str(path), check_same_thread=False)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    return conn


def fts5_safe_query(user_input: str) -> str:
    """
    Natural-language friendly FTS5 query builder, matching BurnBarFTSQueryBuilder.naturalLanguage().
    Uses OR for longer queries to improve recall; AND for short precision queries.
    Strips common English stopwords from NL queries.
    """
    # Common English stopwords
    stopwords = {
        "a",
        "an",
        "the",
        "and",
        "or",
        "but",
        "if",
        "then",
        "else",
        "when",
        "where",
        "why",
        "how",
        "what",
        "who",
        "which",
        "is",
        "are",
        "was",
        "were",
        "be",
        "been",
        "being",
        "to",
        "of",
        "in",
        "on",
        "for",
        "with",
        "about",
        "into",
        "from",
        "at",
        "by",
        "as",
        "it",
        "its",
        "this",
        "that",
        "these",
        "those",
        "i",
        "you",
        "we",
        "they",
        "he",
        "she",
        "my",
        "your",
        "our",
        "their",
        "me",
        "him",
        "her",
        "them",
        "do",
        "does",
        "did",
        "have",
        "has",
        "had",
        "can",
        "could",
        "would",
        "should",
        "will",
        "just",
        "not",
        "no",
        "yes",
        "so",
        "very",
        "too",
        "also",
        "only",
        "even",
        "there",
        "here",
        "some",
        "any",
        "all",
        "each",
        "every",
        "both",
        "few",
        "more",
        "most",
        "other",
        "such",
        "than",
        "up",
        "out",
        "off",
        "over",
        "under",
        "again",
        "once",
        "ever",
        "please",
        "tell",
        "give",
        "show",
        "find",
        "search",
        "look",
        "get",
        "got",
        "make",
        "made",
        "using",
        "use",
        "used",
    }

    trimmed = user_input.strip()
    if not trimmed:
        return ""

    raw_parts = re.split(r"[\s\n]+", trimmed)
    lowered = [p.lower() for p in raw_parts]

    # Filter stopwords and tokens < 2 chars
    filtered = [p for p in lowered if len(p) >= 2 and p not in stopwords]

    if not filtered:
        # Fallback to raw tokens if all were filtered
        parts = [p.lower() for p in raw_parts if p]
    else:
        parts = filtered

    if not parts:
        return ""

    # Use OR for longer queries (> 48 chars or >= 5 tokens), AND for short precision queries
    unique_parts = sorted(set(parts))
    use_or = len(trimmed) > 48 or len(unique_parts) >= 5

    def quote_token(t: str) -> str:
        return '"' + t.replace('"', '""') + '"'

    if use_or:
        return " OR ".join(quote_token(t) for t in unique_parts)
    elif len(unique_parts) <= 3:
        return " AND ".join(quote_token(t) for t in unique_parts)
    else:
        # 4+ tokens that don't trigger OR: use OR for better recall
        return " OR ".join(quote_token(t) for t in unique_parts)


def _row_to_dict(row: sqlite3.Row) -> dict[str, Any]:
    return {k: row[k] for k in row.keys()}


def _json_unavailable(code: str, reason: str, **extra: Any) -> str:
    payload: dict[str, Any] = {
        "status": "unavailable",
        "code": code,
        "reason": reason,
    }
    payload.update(extra)
    return json.dumps(payload, indent=2, default=str)


def _unavailable_payload(code: str, reason: str, **extra: Any) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "status": "unavailable",
        "code": code,
        "reason": reason,
    }
    payload.update(extra)
    return payload


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
    return "|".join(
        [
            OPENBURNBAR_CLOUD_VAULT_AAD_PREFIX,
            _cloud_vault_aad_part(uid, "uid"),
            _cloud_vault_aad_part(collection, "collection"),
            _cloud_vault_aad_part(doc_id, "docID"),
            _cloud_vault_aad_part(field, "field"),
            str(schema_version),
            _cloud_vault_aad_part(purpose_value, "purpose"),
        ]
    )


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
        vault_key,
        OPENBURNBAR_DOC_ID_SALT,
        OPENBURNBAR_PROJECT_MEMORY_DOC_ID_INFO,
        32,
    )
    return "pm_" + hmac.new(doc_id_key, project_slug.encode("utf-8"), hashlib.sha256).digest()[:16].hex()


def _uid_from_firebase_id_token(id_token: str) -> str | None:
    try:
        _header, payload, _signature = id_token.split(".", 2)
        padded = payload + "=" * (-len(payload) % 4)
        decoded = json.loads(base64.urlsafe_b64decode(padded.encode("utf-8")).decode("utf-8"))
    except (ValueError, json.JSONDecodeError, UnicodeDecodeError):
        return None
    if not isinstance(decoded, dict):
        return None
    uid = decoded.get("user_id") or decoded.get("sub")
    return uid if isinstance(uid, str) and uid else None


def _session_log_document_id(storage_path: str, uid: str) -> str | None:
    prefix = f"users/{uid}/session_logs/"
    if not storage_path.startswith(prefix):
        return None
    remainder = storage_path[len(prefix) :]
    parts = remainder.split("/")
    if len(parts) >= 3 and parts[1] == "bodies":
        return parts[0]
    return None


def _cloud_normalized_tokens(text: str) -> list[str]:
    tokens = re.split(r"[^a-z0-9]+", text.lower())
    return [token for token in tokens if len(token) >= 2 and token not in OPENBURNBAR_STOPWORDS]


def _cloud_token_hashes(text: str, vault_key: bytes, limit: int = 10) -> list[str]:
    search_key = _hkdf_sha256(
        vault_key,
        OPENBURNBAR_TOKEN_SEARCH_SALT,
        OPENBURNBAR_TOKEN_SEARCH_INFO,
        32,
    )
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
        if not name or name in seen:
            return
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
    search_key = _hkdf_sha256(
        vault_key,
        OPENBURNBAR_SEMANTIC_SEARCH_SALT,
        OPENBURNBAR_SEMANTIC_SEARCH_INFO,
        32,
    )
    features = _cloud_semantic_features(tokens)
    dimensions = 64
    accumulator = [0.0] * dimensions
    for name, weight in features:
        digest = hmac.new(search_key, name.encode("utf-8"), hashlib.sha256).digest()
        index = ((digest[0] << 8) | digest[1]) % dimensions
        sign = 1.0 if (digest[2] & 1) == 0 else -1.0
        accumulator[index] += sign * weight

    hashes: list[str] = []
    seen: set[str] = set()

    def append_bucket(bucket: str) -> None:
        if len(hashes) >= limit:
            return
        digest = hmac.new(search_key, bucket.encode("utf-8"), hashlib.sha256).digest()[:16].hex()
        if digest not in seen:
            seen.add(digest)
            hashes.append(digest)

    band_size = 8
    for band in range(dimensions // band_size):
        value = 0
        for bit in range(band_size):
            if accumulator[band * band_size + bit] >= 0:
                value |= 1 << bit
        append_bucket(f"simhash:v1:band:{band}:{value:02x}")

    for name, _weight in features[: max(0, limit - len(hashes))]:
        append_bucket(f"feature:v1:{name}")
    return hashes


def _cloud_config() -> dict[str, Any]:
    project_id = os.environ.get("OPENBURNBAR_FIREBASE_PROJECT_ID", OPENBURNBAR_FIREBASE_PROJECT_ID).strip()
    region = os.environ.get("OPENBURNBAR_FUNCTIONS_REGION", OPENBURNBAR_FUNCTIONS_REGION).strip()
    id_token = os.environ.get("OPENBURNBAR_FIREBASE_ID_TOKEN", "").strip()
    vault_key_raw = os.environ.get("OPENBURNBAR_CLOUD_VAULT_KEY_BASE64", "").strip()
    if not id_token:
        return _unavailable_payload(
            "CLOUD_AUTH_UNCONFIGURED",
            "set OPENBURNBAR_FIREBASE_ID_TOKEN to a Firebase Auth ID token for the signed-in user",
        )
    if not vault_key_raw:
        return _unavailable_payload(
            "CLOUD_VAULT_KEY_UNCONFIGURED",
            "set OPENBURNBAR_CLOUD_VAULT_KEY_BASE64 to the 32-byte cloud vault key for this device",
        )
    try:
        vault_key = base64.b64decode(vault_key_raw, validate=True)
    except ValueError as exc:
        return _unavailable_payload("CLOUD_VAULT_KEY_INVALID", "cloud vault key must be base64", error=str(exc))
    if len(vault_key) != 32:
        return _unavailable_payload("CLOUD_VAULT_KEY_INVALID", "cloud vault key must decode to 32 bytes")
    return {
        "status": "ok",
        "projectID": project_id,
        "region": region,
        "idToken": id_token,
        "uid": _uid_from_firebase_id_token(id_token),
        "vaultKey": vault_key,
    }


def _call_firebase_callable(function_name: str, payload: dict[str, Any], config: dict[str, Any]) -> dict[str, Any]:
    url = f"https://{config['region']}-{config['projectID']}.cloudfunctions.net/{function_name}"
    body = json.dumps({"data": payload}).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=body,
        headers={
            "Authorization": f"Bearer {config['idToken']}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            raw = response.read().decode("utf-8")
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"{function_name} failed with HTTP {exc.code}: {detail}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"{function_name} request failed: {exc}") from exc

    decoded = json.loads(raw) if raw else {}
    if isinstance(decoded, dict) and isinstance(decoded.get("result"), dict):
        return decoded["result"]
    if isinstance(decoded, dict) and isinstance(decoded.get("data"), dict):
        return decoded["data"]
    if isinstance(decoded, dict):
        return decoded
    raise RuntimeError(f"{function_name} returned an unsupported payload")


def _aesgcm_open(nonce: bytes, ciphertext_and_tag: bytes, key: bytes, aad: bytes | None = None) -> bytes:
    try:
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    except ImportError as exc:
        raise RuntimeError("install cryptography to decrypt OpenBurnBar cloud search hits") from exc
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
        if envelope_aad == OPENBURNBAR_CLOUD_VAULT_BLOB_AAD_CONTEXT:
            aad_bytes = None
        else:
            if not expected_aad or envelope_aad != expected_aad:
                raise ValueError("encrypted blob AAD context mismatch")
            aad_bytes = _validate_cloud_vault_aad(expected_aad).encode("utf-8")
    plaintext = _aesgcm_open(combined[:12], combined[12:], vault_key, aad_bytes)
    if schema_version >= 2:
        if int(envelope.get("integrityHashVersion") or 0) != 1:
            raise ValueError("encrypted blob integrity version mismatch")
        expected = str(envelope.get("plaintextHMAC", ""))
        actual = _cloud_vault_hmac_hex(plaintext, vault_key, "blob-integrity")
        if actual != expected:
            raise ValueError("encrypted blob HMAC mismatch")
    else:
        expected = str(envelope.get("plaintextSHA256", ""))
        actual = hashlib.sha256(plaintext).hexdigest()
        if actual != expected:
            raise ValueError("encrypted blob SHA-256 mismatch")
    return plaintext


def _seal_cloud_blob_envelope(
    plaintext: bytes,
    vault_key: bytes,
    key_version: int = 1,
    aad_context: str | None = None,
) -> dict[str, Any]:
    try:
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    except ImportError as exc:
        raise RuntimeError("install cryptography to seal OpenBurnBar cloud payloads") from exc
    nonce = os.urandom(12)
    aad = _validate_cloud_vault_aad(aad_context).encode("utf-8") if aad_context else None
    ciphertext_and_tag = AESGCM(vault_key).encrypt(nonce, plaintext, aad)
    combined = nonce + ciphertext_and_tag
    return {
        "schemaVersion": 2,
        "algorithm": "AES-256-GCM",
        "keyVersion": int(key_version),
        "plaintextHMAC": _cloud_vault_hmac_hex(plaintext, vault_key, "blob-integrity"),
        "integrityHashVersion": 1,
        "sealedBoxBase64": base64.b64encode(combined).decode("utf-8"),
        "createdAt": datetime.now(UTC).isoformat().replace("+00:00", "Z"),
        "aad": aad_context or OPENBURNBAR_CLOUD_VAULT_BLOB_AAD_CONTEXT,
    }


def _normalize_project_slug(raw: str) -> str:
    normalized = re.sub(r"[^a-z0-9_-]+", "-", raw.strip().lower())
    normalized = re.sub(r"-{2,}", "-", normalized).strip("-")
    return normalized


def _project_memory_row(conn: sqlite3.Connection, project_slug: str) -> sqlite3.Row | None:
    conn.row_factory = sqlite3.Row
    trimmed = project_slug.strip()
    if not trimmed:
        return None
    candidates = [trimmed]
    normalized = _normalize_project_slug(trimmed)
    if normalized and normalized not in candidates:
        candidates.append(normalized)
    for candidate in candidates:
        row = conn.execute(
            """
            SELECT
                projectSlug,
                projectDisplayName,
                snapshotJSON,
                contentHash,
                sourceSessionCount,
                sourceConversationCount,
                generatedAt,
                schemaVersion,
                updatedAt
            FROM project_memory_snapshots
            WHERE lower(projectSlug) = lower(?)
            LIMIT 1
            """,
            (candidate,),
        ).fetchone()
        if row is not None:
            return row
    return None


def _parse_project_memory_row(row: sqlite3.Row) -> dict[str, Any]:
    record = _row_to_dict(row)
    snapshot: dict[str, Any] = {}
    snapshot_raw = record.get("snapshotJSON")
    if isinstance(snapshot_raw, str) and snapshot_raw.strip():
        try:
            decoded = json.loads(snapshot_raw)
            if isinstance(decoded, dict):
                snapshot = decoded
        except json.JSONDecodeError:
            snapshot = {}

    visuals = snapshot.get("visuals")
    visual_kinds: list[str] = []
    if isinstance(visuals, list):
        visual_kinds = sorted(
            {
                str(item.get("kind"))
                for item in visuals
                if isinstance(item, dict) and isinstance(item.get("kind"), str) and item.get("kind")
            }
        )
    sections = snapshot.get("sections")
    section_count = len(sections) if isinstance(sections, list) else 0
    page = snapshot.get("page")
    title = page.get("title") if isinstance(page, dict) else None

    return {
        "projectSlug": record.get("projectSlug"),
        "projectDisplayName": record.get("projectDisplayName"),
        "contentHash": record.get("contentHash"),
        "sourceSessionCount": record.get("sourceSessionCount"),
        "sourceConversationCount": record.get("sourceConversationCount"),
        "generatedAt": record.get("generatedAt"),
        "updatedAt": record.get("updatedAt"),
        "schemaVersion": record.get("schemaVersion"),
        "freshness": snapshot.get("freshness"),
        "visualKinds": visual_kinds,
        "sectionCount": section_count,
        "title": title,
        "snapshot": snapshot,
    }


def _table_names(conn: sqlite3.Connection) -> set[str]:
    rows = conn.execute("SELECT name FROM sqlite_master WHERE type IN ('table', 'virtual table')").fetchall()
    return {str(row[0]) for row in rows}


def _table_columns(conn: sqlite3.Connection, table: str) -> set[str]:
    return {str(row[1]) for row in conn.execute(f"PRAGMA table_info({table})").fetchall()}


def _deterministic_query_embedding(text: str, dimensions: int = DETERMINISTIC_EMBEDDING_DIMENSIONS) -> list[float]:
    normalized = text.replace("\r\n", "\n").strip().lower()
    split_re = "[" + re.escape(string.whitespace + string.punctuation) + "]+"
    tokens = [token for token in re.split(split_re, normalized) if token]
    source_tokens = tokens if tokens else [normalized]
    vector = [0.0] * max(1, int(dimensions))

    for position, token in enumerate(source_tokens):
        payload = f"{DETERMINISTIC_EMBEDDING_SEED}|{position}|{token}"
        digest = hashlib.sha256(payload.encode("utf-8")).hexdigest()
        byte_values = digest.encode("utf-8")
        weight = 1.0 / float(max(1, position + 1))
        width = min(16, len(byte_values))
        for lane in range(width):
            value = byte_values[lane]
            index = (int(value) + lane * 131) % len(vector)
            sign = 1.0 if lane % 2 == 0 else -1.0
            magnitude = (float(value % 31) / 30.0) + 0.15
            vector[index] += sign * magnitude * weight

    if not source_tokens:
        vector[0] = 1.0

    norm = math.sqrt(sum(value * value for value in vector))
    if norm <= 0 or not math.isfinite(norm):
        return vector
    return [value / norm for value in vector]


def _decode_float32_vector(blob: bytes) -> list[float] | None:
    if not blob or len(blob) % 4 != 0:
        return None
    count = len(blob) // 4
    try:
        return list(struct.unpack("<" + "f" * count, blob))
    except struct.error:
        return None


def _vector_score(lhs: list[float], rhs: list[float], metric: str) -> float:
    if len(lhs) != len(rhs) or not lhs:
        return 0.0
    if metric in {"dotProduct", "dot_product"}:
        return sum(float(left) * float(right) for left, right in zip(lhs, rhs, strict=True))
    if metric == "euclidean":
        return -math.sqrt(sum((float(left) - float(right)) ** 2 for left, right in zip(lhs, rhs, strict=True)))

    dot = 0.0
    lhs_norm = 0.0
    rhs_norm = 0.0
    for left_value, right_value in zip(lhs, rhs, strict=True):
        left = float(left_value)
        right = float(right_value)
        dot += left * right
        lhs_norm += left * left
        rhs_norm += right * right
    if lhs_norm <= 0 or rhs_norm <= 0:
        return 0.0
    return dot / (math.sqrt(lhs_norm) * math.sqrt(rhs_norm))


def _snippet(text: str | None, max_chars: int = 320) -> str | None:
    if not text:
        return None
    collapsed = re.sub(r"\s+", " ", text).strip()
    if len(collapsed) <= max_chars:
        return collapsed
    return collapsed[: max_chars - 1].rstrip() + "…"


def _active_deterministic_embedding(conn: sqlite3.Connection) -> dict[str, Any] | None:
    conn.row_factory = sqlite3.Row
    row = conn.execute(
        """
        SELECT
            v.id AS versionID,
            v.versionTag,
            v.chunkerVersion,
            v.normalizationVersion,
            v.promptVersion,
            v.updatedAt AS versionUpdatedAt,
            m.id AS modelID,
            m.provider,
            m.modelName,
            m.dimensions,
            m.distanceMetric
        FROM embedding_versions AS v
        JOIN embedding_models AS m ON m.id = v.modelID
        WHERE v.isActive = 1
        ORDER BY v.updatedAt DESC
        LIMIT 1
        """
    ).fetchone()
    if row is None:
        return None

    record = _row_to_dict(row)
    if (
        str(record.get("provider", "")).lower() != DETERMINISTIC_EMBEDDING_PROVIDER
        or str(record.get("modelName", "")).lower() != DETERMINISTIC_EMBEDDING_MODEL
        or int(record.get("dimensions") or 0) != DETERMINISTIC_EMBEDDING_DIMENSIONS
        or str(record.get("versionTag", "")) != DETERMINISTIC_EMBEDDING_VERSION_TAG
        or str(record.get("chunkerVersion", "")) != DETERMINISTIC_CHUNKER_VERSION
        or str(record.get("normalizationVersion", "")) != DETERMINISTIC_NORMALIZATION_VERSION
        or str(record.get("promptVersion", "")) != DETERMINISTIC_PROMPT_VERSION
    ):
        return None
    return record


def _semantic_search_payload(
    conn: sqlite3.Connection,
    query: str,
    provider: str | None = None,
    project_name: str | None = None,
    limit: int = 20,
) -> dict[str, Any]:
    trimmed_query = query.strip()
    if not trimmed_query:
        return {"status": "unavailable", "code": "EMPTY_QUERY", "reason": "query is empty after trimming"}

    tables = _table_names(conn)
    missing = sorted(SEMANTIC_REQUIRED_TABLES - tables)
    if missing:
        return {
            "status": "unavailable",
            "code": "SEMANTIC_TABLES_MISSING",
            "reason": "local semantic search tables are not present in this SQLite database",
            "missingTables": missing,
        }

    selection = _active_deterministic_embedding(conn)
    if selection is None:
        return {
            "status": "unavailable",
            "code": "NO_COMPATIBLE_DETERMINISTIC_EMBEDDING",
            "reason": "no active openburnbar deterministic embedding version is available locally",
            "expected": {
                "provider": DETERMINISTIC_EMBEDDING_PROVIDER,
                "modelName": DETERMINISTIC_EMBEDDING_MODEL,
                "dimensions": DETERMINISTIC_EMBEDDING_DIMENSIONS,
                "versionTag": DETERMINISTIC_EMBEDDING_VERSION_TAG,
                "chunkerVersion": DETERMINISTIC_CHUNKER_VERSION,
                "normalizationVersion": DETERMINISTIC_NORMALIZATION_VERSION,
                "promptVersion": DETERMINISTIC_PROMPT_VERSION,
            },
        }

    version_id = str(selection["versionID"])
    vector_count = int(
        conn.execute(
            "SELECT COUNT(*) FROM chunk_embeddings WHERE embeddingVersionID = ?",
            (version_id,),
        ).fetchone()[0]
    )
    if vector_count == 0:
        return {
            "status": "unavailable",
            "code": "NO_SEMANTIC_VECTORS",
            "reason": "the active deterministic embedding version has no chunk vectors",
            "embeddingVersionID": version_id,
        }

    lim = max(1, min(int(limit), 200))
    chunk_cols = _table_columns(conn, "search_chunks")
    doc_cols = _table_columns(conn, "search_documents")
    has_conversations = "conversations" in tables
    conv_cols = _table_columns(conn, "conversations") if has_conversations else set()

    chunk_text_expr = "c.text" if "text" in chunk_cols else "NULL"
    ordinal_expr = "c.ordinal" if "ordinal" in chunk_cols else "NULL"
    source_kind_expr = "d.sourceKind" if "sourceKind" in doc_cols else "NULL"
    source_id_expr = "d.sourceID" if "sourceID" in doc_cols else "d.id"
    title_expr = "d.title" if "title" in doc_cols else "NULL"
    body_preview_expr = "d.bodyPreview" if "bodyPreview" in doc_cols else "NULL"
    doc_provider_expr = "d.provider" if "provider" in doc_cols else "NULL"
    doc_project_expr = "d.projectName" if "projectName" in doc_cols else "NULL"
    indexed_at_expr = "d.indexedAt" if "indexedAt" in doc_cols else "NULL"

    conv_join = ""
    conv_provider_expr = "NULL"
    conv_project_expr = "NULL"
    conv_session_expr = "NULL"
    conv_start_expr = "NULL"
    conv_title_expr = "NULL"
    if has_conversations:
        conv_join = "LEFT JOIN conversations AS conv ON conv.id = d.sourceID OR conv.id = d.id"
        conv_provider_expr = "conv.provider" if "provider" in conv_cols else "NULL"
        conv_project_expr = "conv.projectName" if "projectName" in conv_cols else "NULL"
        conv_session_expr = "conv.sessionId" if "sessionId" in conv_cols else "NULL"
        conv_start_expr = "conv.startTime" if "startTime" in conv_cols else "NULL"
        conv_title_expr = "conv.inferredTaskTitle" if "inferredTaskTitle" in conv_cols else "NULL"

    # S608: selected expressions are fixed schema-column literals derived from local schema inspection.
    sql = f"""
        SELECT
            e.chunkID,
            e.vectorBlob,
            c.documentID,
            {ordinal_expr} AS ordinal,
            {chunk_text_expr} AS chunkText,
            {source_kind_expr} AS sourceKind,
            {source_id_expr} AS sourceID,
            {title_expr} AS title,
            {body_preview_expr} AS bodyPreview,
            {doc_provider_expr} AS documentProvider,
            {doc_project_expr} AS documentProjectName,
            {indexed_at_expr} AS indexedAt,
            {conv_provider_expr} AS conversationProvider,
            {conv_project_expr} AS conversationProjectName,
            {conv_session_expr} AS sessionId,
            {conv_start_expr} AS startTime,
            {conv_title_expr} AS inferredTaskTitle
        FROM chunk_embeddings AS e
        JOIN search_chunks AS c ON c.id = e.chunkID
        JOIN search_documents AS d ON d.id = c.documentID
        {conv_join}
        WHERE e.embeddingVersionID = ?
    """
    args: list[Any] = [version_id]
    if provider:
        sql += f" AND COALESCE({doc_provider_expr}, {conv_provider_expr}, '') = ?"
        args.append(provider)
    if project_name:
        sql += f" AND COALESCE({doc_project_expr}, {conv_project_expr}, '') = ?"
        args.append(project_name)

    query_vector = _deterministic_query_embedding(
        trimmed_query,
        dimensions=int(selection["dimensions"]),
    )
    metric = str(selection["distanceMetric"])
    best: list[dict[str, Any]] = []
    for row in conn.execute(sql, args):
        record = _row_to_dict(row)
        vector = _decode_float32_vector(record["vectorBlob"])
        if vector is None or len(vector) != len(query_vector):
            continue
        score = _vector_score(query_vector, vector, metric)
        if not math.isfinite(score):
            continue
        text = record.get("chunkText") or record.get("bodyPreview")
        result = {
            "chunkID": record.get("chunkID"),
            "documentID": record.get("documentID"),
            "score": score,
            "snippet": _snippet(text),
            "title": record.get("inferredTaskTitle") or record.get("title"),
            "provider": record.get("documentProvider") or record.get("conversationProvider"),
            "projectName": record.get("documentProjectName") or record.get("conversationProjectName"),
            "source": {
                "kind": record.get("sourceKind"),
                "id": record.get("sourceID"),
                "sessionId": record.get("sessionId"),
                "startTime": record.get("startTime"),
                "indexedAt": record.get("indexedAt"),
                "chunkOrdinal": record.get("ordinal"),
            },
        }
        best.append(result)
        best.sort(key=lambda item: (-float(item["score"]), str(item.get("chunkID") or "")))
        if len(best) > lim:
            best.pop()

    return {
        "status": "ok",
        "query": trimmed_query,
        "embedding": {
            "versionID": version_id,
            "modelID": selection["modelID"],
            "provider": selection["provider"],
            "modelName": selection["modelName"],
            "dimensions": selection["dimensions"],
            "distanceMetric": selection["distanceMetric"],
        },
        "results": best,
    }


@mcp.tool()
def burnbar_resolve_db_path() -> str:
    """Return the SQLite path that will be used (for debugging)."""
    p = _default_db_path()
    exists = p.is_file()
    return json.dumps({"path": str(p), "exists": exists}, indent=2)


@mcp.tool()
def burnbar_list_providers() -> str:
    """List distinct conversation providers (e.g. Codex, Claude Code) present in the DB."""
    path = _default_db_path()
    with _connect_ro(path) as conn:
        conn.row_factory = sqlite3.Row
        cur = conn.execute("SELECT DISTINCT provider FROM conversations ORDER BY provider")
        rows = [r[0] for r in cur.fetchall()]
    return json.dumps({"providers": rows}, indent=2)


@mcp.tool()
def burnbar_search_conversations(
    query: str,
    provider: str | None = None,
    project_name: str | None = None,
    limit: int = 30,
) -> str:
    """
    Full-text search over indexed conversations (FTS5 on title + fullText), same family of queries as the OpenBurnBar app.
    `provider` must match stored values (see burnbar_list_providers), e.g. \"Codex\", \"Claude Code\".
    """
    q = fts5_safe_query(query)
    if not q:
        return json.dumps({"error": "empty query after sanitization"}, indent=2)
    lim = max(1, min(int(limit), 200))
    path = _default_db_path()
    with _connect_ro(path) as conn:
        conn.row_factory = sqlite3.Row
        try:
            sql = """
            SELECT c.id, c.provider, c.sessionId, c.projectName, c.startTime, c.inferredTaskTitle,
                   bm25(conversations_fts) AS rank,
                   snippet(conversations_fts, 1, '<b>', '</b>', '…', 12) AS snippet
            FROM conversations_fts
            JOIN conversations AS c ON c.rowid = conversations_fts.rowid
            WHERE conversations_fts MATCH ?
            """
            args: list[Any] = [q]
            if provider:
                sql += " AND c.provider = ?"
                args.append(provider)
            if project_name:
                sql += " AND c.projectName = ?"
                args.append(project_name)
            sql += " ORDER BY rank ASC LIMIT ?"
            args.append(lim)
            cur = conn.execute(sql, args)
            out = [_row_to_dict(row) for row in cur.fetchall()]
        except sqlite3.OperationalError as e:
            return json.dumps(
                {"error": str(e), "hint": "FTS missing or DB schema mismatch; is this a OpenBurnBar DB?"},
                indent=2,
            )
    return json.dumps({"results": out}, indent=2)


@mcp.tool()
def burnbar_semantic_search_conversations(
    query: str,
    provider: str | None = None,
    project_name: str | None = None,
    limit: int = 20,
) -> str:
    """
    Semantic search over local indexed conversation chunks.

    This only returns semantic results when the local SQLite database has the
    search_documents/search_chunks/chunk_embeddings/embedding_versions substrate
    and the active embedding version matches OpenBurnBar's deterministic local
    embedder. Otherwise it returns a structured unavailable payload.
    """
    path = _default_db_path()
    try:
        with _connect_ro(path) as conn:
            conn.row_factory = sqlite3.Row
            payload = _semantic_search_payload(
                conn,
                query=query,
                provider=provider,
                project_name=project_name,
                limit=limit,
            )
    except sqlite3.OperationalError as exc:
        return _json_unavailable(
            "SEMANTIC_SCHEMA_ERROR",
            "local semantic search schema could not be read",
            error=str(exc),
        )
    return json.dumps(payload, indent=2, default=str)


@mcp.tool()
def burnbar_cloud_semantic_search_conversations(
    query: str,
    provider: str | None = None,
    limit: int = 25,
) -> str:
    """
    Hosted encrypted semantic search over the user's cloud session-log index.

    The MCP process derives token/semantic trapdoors locally from the cloud
    vault key, sends only opaque hashes to Firebase Functions, and decrypts
    returned titles/snippets on this device. Required env:
    OPENBURNBAR_FIREBASE_ID_TOKEN and OPENBURNBAR_CLOUD_VAULT_KEY_BASE64.
    """
    config = _cloud_config()
    if config.get("status") != "ok":
        return json.dumps(config, indent=2)

    vault_key = config["vaultKey"]
    token_hashes = _cloud_token_hashes(query, vault_key, limit=10)
    semantic_hashes = _cloud_semantic_hashes(query, vault_key, limit=12)
    if not token_hashes and not semantic_hashes:
        return _json_unavailable("EMPTY_QUERY", "query produced no searchable encrypted hashes")

    payload: dict[str, Any] = {
        "tokenHashes": token_hashes,
        "semanticHashes": semantic_hashes,
        "limit": max(1, min(int(limit), 50)),
    }
    if provider:
        payload["provider"] = provider

    try:
        result = _call_firebase_callable("searchEncryptedConversationIndex", payload, config)
        raw_hits = result.get("hits") if isinstance(result, dict) else []
        hits: list[dict[str, Any]] = []
        for hit in raw_hits if isinstance(raw_hits, list) else []:
            if not isinstance(hit, dict):
                continue
            try:
                hit_uid = str(hit.get("uid") or config.get("uid") or "")
                document_id = str(hit.get("documentID") or "")
                chunk_id = str(hit.get("chunkID") or hit.get("id") or "")
                title = _open_cloud_sealed_text(
                    hit["sealedTitle"],
                    vault_key,
                    _cloud_vault_aad_context(hit_uid, "cloud_search_documents", document_id, "sealedTitle"),
                )
                snippet = _open_cloud_sealed_text(
                    hit["sealedSnippet"],
                    vault_key,
                    _cloud_vault_aad_context(hit_uid, "cloud_search_chunks", chunk_id, "sealedSnippet"),
                )
            except (KeyError, TypeError, ValueError, RuntimeError):
                continue
            hits.append(
                {
                    "id": hit.get("id"),
                    "chunkID": hit.get("chunkID"),
                    "documentID": hit.get("documentID"),
                    "title": title,
                    "snippet": snippet,
                    "provider": hit.get("provider"),
                    "projectName": hit.get("projectName"),
                    "score": hit.get("score"),
                    "tokenScore": hit.get("tokenScore"),
                    "semanticScore": hit.get("semanticScore"),
                    "matchKind": hit.get("matchKind"),
                    "storagePath": hit.get("storagePath"),
                    "bodyHash": hit.get("bodyHash"),
                    "bodyHashVersion": hit.get("bodyHashVersion"),
                    "indexVersion": hit.get("indexVersion"),
                    "semanticHashVersion": hit.get("semanticHashVersion"),
                }
            )
    except RuntimeError as exc:
        return _json_unavailable("CLOUD_SEARCH_FAILED", "hosted encrypted search failed", error=str(exc))

    return json.dumps(
        {
            "status": "ok",
            "query": query,
            "results": hits,
            "privacy": "query plaintext and vault key stayed local; Firebase received only keyed token/semantic hashes",
        },
        indent=2,
        default=str,
    )


@mcp.tool()
def burnbar_cloud_get_conversation_body(
    storage_path: str,
    body_hash: str,
    body_hash_version: int | None = None,
    max_full_text_chars: int = 120_000,
) -> str:
    """
    Download and decrypt one hosted encrypted session body returned by
    burnbar_cloud_semantic_search_conversations.
    """
    config = _cloud_config()
    if config.get("status") != "ok":
        return json.dumps(config, indent=2)

    try:
        ticket = _call_firebase_callable(
            "getEncryptedSessionBlobDownloadUrl",
            {"storagePath": storage_path},
            config,
        )
        download_url = ticket.get("downloadURL")
        if not isinstance(download_url, str) or not download_url:
            raise RuntimeError("downloadURL missing from function response")
        with urllib.request.urlopen(download_url, timeout=30) as response:
            envelope = json.loads(response.read().decode("utf-8"))
        uid = str(config.get("uid") or "")
        document_id = _session_log_document_id(storage_path, uid)
        expected_aad = _cloud_vault_aad_context(uid, "session_logs", document_id, "sealedBody") if document_id else None
        plaintext = _open_cloud_blob_envelope(envelope, config["vaultKey"], expected_aad)
        effective_hash_version = int(
            body_hash_version
            if body_hash_version is not None
            else (2 if int(envelope.get("schemaVersion") or 1) >= 2 else 1)
        )
        actual_hash = (
            _cloud_vault_hmac_hex(plaintext, config["vaultKey"], "session-body")
            if effective_hash_version >= 2
            else hashlib.sha256(plaintext).hexdigest()
        )
        if actual_hash != body_hash:
            raise RuntimeError("decrypted body hash did not match the search hit")
        full_text = plaintext.decode("utf-8")
    except (RuntimeError, urllib.error.URLError, json.JSONDecodeError, ValueError) as exc:
        return _json_unavailable(
            "CLOUD_BODY_DECRYPT_FAILED", "hosted encrypted body could not be decrypted", error=str(exc)
        )

    truncated = False
    max_chars = max(1, min(int(max_full_text_chars), 500_000))
    if len(full_text) > max_chars:
        full_text = full_text[: max_chars // 2] + "\n… [truncated] …\n" + full_text[-max_chars // 2 :]
        truncated = True
    return json.dumps(
        {
            "status": "ok",
            "storagePath": storage_path,
            "bodyHash": body_hash,
            "bodyHashVersion": effective_hash_version,
            "fullText": full_text,
            "fullTextTruncated": truncated,
        },
        indent=2,
    )


@mcp.tool()
def burnbar_list_project_memory(limit: int = 20) -> str:
    """
    List locally cached Project Memory snapshots from SQLite.

    Returns metadata only (slug, freshness, section count, visual kinds, hash),
    ordered by most recently updated.
    """
    lim = max(1, min(int(limit), 100))
    path = _default_db_path()
    with _connect_ro(path) as conn:
        if "project_memory_snapshots" not in _table_names(conn):
            return _json_unavailable(
                "PROJECT_MEMORY_TABLE_MISSING",
                "local project_memory_snapshots table is not present in this SQLite database",
            )
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            """
            SELECT
                projectSlug,
                projectDisplayName,
                snapshotJSON,
                contentHash,
                sourceSessionCount,
                sourceConversationCount,
                generatedAt,
                schemaVersion,
                updatedAt
            FROM project_memory_snapshots
            ORDER BY updatedAt DESC
            LIMIT ?
            """,
            (lim,),
        ).fetchall()
    snapshots = [_parse_project_memory_row(row) for row in rows]
    for item in snapshots:
        item.pop("snapshot", None)
    return json.dumps(
        {
            "status": "ok",
            "source": "local",
            "count": len(snapshots),
            "snapshots": snapshots,
        },
        indent=2,
        default=str,
    )


@mcp.tool()
def burnbar_get_project_memory(project_slug: str, source: str = "auto") -> str:
    """
    Get one Project Memory snapshot.

    source:
      - auto  (default): local first, then cloud fallback
      - local: SQLite project_memory_snapshots only
      - cloud: hosted encrypted snapshot via Firebase callable + local decrypt
    """
    source_mode = source.strip().lower()
    if source_mode not in {"auto", "local", "cloud"}:
        return json.dumps(
            {"error": "source must be one of: auto, local, cloud"},
            indent=2,
        )
    slug = project_slug.strip()
    if not slug:
        return json.dumps({"error": "project_slug is required"}, indent=2)

    if source_mode in {"auto", "local"}:
        path = _default_db_path()
        with _connect_ro(path) as conn:
            if "project_memory_snapshots" not in _table_names(conn):
                if source_mode == "local":
                    return _json_unavailable(
                        "PROJECT_MEMORY_TABLE_MISSING",
                        "local project_memory_snapshots table is not present in this SQLite database",
                    )
            else:
                row = _project_memory_row(conn, slug)
                if row is not None:
                    payload = _parse_project_memory_row(row)
                    return json.dumps(
                        {
                            "status": "ok",
                            "source": "local",
                            **payload,
                        },
                        indent=2,
                        default=str,
                    )
                if source_mode == "local":
                    return _json_unavailable(
                        "PROJECT_MEMORY_NOT_FOUND",
                        "local project memory snapshot was not found",
                        projectSlug=slug,
                    )

    config = _cloud_config()
    if config.get("status") != "ok":
        return json.dumps(config, indent=2)
    try:
        doc_id = _cloud_vault_project_memory_doc_id(_normalize_project_slug(slug) or slug, config["vaultKey"])
        result = _call_firebase_callable(
            "getEncryptedProjectMemorySnapshot",
            {"docID": doc_id},
            config,
        )
        cloud_snapshot = result.get("snapshot") if isinstance(result, dict) else None
        if not isinstance(cloud_snapshot, dict):
            return _json_unavailable(
                "PROJECT_MEMORY_NOT_FOUND",
                "cloud project memory snapshot was not found",
                projectSlug=slug,
            )
        sealed = cloud_snapshot.get("sealedSnapshot")
        if not isinstance(sealed, dict):
            return _json_unavailable(
                "PROJECT_MEMORY_PAYLOAD_INVALID",
                "cloud snapshot is missing sealedSnapshot envelope",
                projectSlug=slug,
            )
        uid = str(config.get("uid") or "")
        plaintext = _open_cloud_blob_envelope(
            sealed,
            config["vaultKey"],
            _cloud_vault_aad_context(uid, "project_memory_snapshots", doc_id, "sealedSnapshot"),
        )
        snapshot = json.loads(plaintext.decode("utf-8"))
        if not isinstance(snapshot, dict):
            return _json_unavailable(
                "PROJECT_MEMORY_PAYLOAD_INVALID",
                "cloud sealed snapshot did not decode to an object",
                projectSlug=slug,
            )
    except (RuntimeError, ValueError, json.JSONDecodeError) as exc:
        return _json_unavailable(
            "PROJECT_MEMORY_CLOUD_READ_FAILED",
            "cloud project memory snapshot could not be read",
            error=str(exc),
            projectSlug=slug,
        )

    visuals = snapshot.get("visuals")
    visual_kinds = (
        sorted(
            {
                str(item.get("kind"))
                for item in visuals
                if isinstance(item, dict) and isinstance(item.get("kind"), str) and item.get("kind")
            }
        )
        if isinstance(visuals, list)
        else []
    )
    sections = snapshot.get("sections")
    section_count = len(sections) if isinstance(sections, list) else 0

    return json.dumps(
        {
            "status": "ok",
            "source": "cloud",
            "docID": cloud_snapshot.get("docID") or doc_id,
            "projectSlug": cloud_snapshot.get("projectSlug") or snapshot.get("projectSlug") or slug,
            "projectDisplayName": cloud_snapshot.get("projectDisplayName") or snapshot.get("projectDisplayName"),
            "contentHash": cloud_snapshot.get("contentHash") or snapshot.get("contentHash"),
            "contentHashVersion": cloud_snapshot.get("contentHashVersion"),
            "sourceSessionCount": cloud_snapshot.get("sourceSessionCount") or snapshot.get("sourceSessionCount"),
            "sourceConversationCount": cloud_snapshot.get("sourceConversationCount")
            or snapshot.get("sourceConversationCount"),
            "generatedAt": cloud_snapshot.get("generatedAt") or snapshot.get("generatedAt"),
            "updatedAt": cloud_snapshot.get("updatedAt"),
            "schemaVersion": cloud_snapshot.get("schemaVersion"),
            "freshness": cloud_snapshot.get("freshness") or snapshot.get("freshness"),
            "visualKinds": cloud_snapshot.get("visualKinds") or visual_kinds,
            "sectionCount": section_count,
            "snapshot": snapshot,
        },
        indent=2,
        default=str,
    )


@mcp.tool()
def burnbar_cloud_sync_project_memory(project_slug: str) -> str:
    """
    Encrypt and upload one local Project Memory snapshot to cloud storage.

    Requires local project_memory_snapshots data plus cloud auth env
    (OPENBURNBAR_FIREBASE_ID_TOKEN and OPENBURNBAR_CLOUD_VAULT_KEY_BASE64).
    """
    slug = project_slug.strip()
    if not slug:
        return json.dumps({"error": "project_slug is required"}, indent=2)

    path = _default_db_path()
    with _connect_ro(path) as conn:
        if "project_memory_snapshots" not in _table_names(conn):
            return _json_unavailable(
                "PROJECT_MEMORY_TABLE_MISSING",
                "local project_memory_snapshots table is not present in this SQLite database",
            )
        row = _project_memory_row(conn, slug)
        if row is None:
            return _json_unavailable(
                "PROJECT_MEMORY_NOT_FOUND",
                "local project memory snapshot was not found",
                projectSlug=slug,
            )
        parsed = _parse_project_memory_row(row)

    snapshot = parsed.get("snapshot")
    if not isinstance(snapshot, dict):
        return _json_unavailable(
            "PROJECT_MEMORY_PAYLOAD_INVALID",
            "local snapshotJSON did not decode to an object",
            projectSlug=slug,
        )

    config = _cloud_config()
    if config.get("status") != "ok":
        return json.dumps(config, indent=2)

    try:
        plaintext = json.dumps(snapshot, separators=(",", ":"), sort_keys=True).encode("utf-8")
        project_slug = str(parsed.get("projectSlug") or slug)
        doc_id = _cloud_vault_project_memory_doc_id(project_slug, config["vaultKey"])
        uid = str(config.get("uid") or "")
        sealed_snapshot = _seal_cloud_blob_envelope(
            plaintext,
            config["vaultKey"],
            key_version=1,
            aad_context=_cloud_vault_aad_context(uid, "project_memory_snapshots", doc_id, "sealedSnapshot"),
        )
        visuals = snapshot.get("visuals")
        visual_kinds = (
            sorted(
                {
                    str(item.get("kind"))
                    for item in visuals
                    if isinstance(item, dict) and isinstance(item.get("kind"), str) and item.get("kind")
                }
            )
            if isinstance(visuals, list)
            else []
        )
        legacy_doc_id = _normalize_project_slug(project_slug)
        payload = {
            "docID": doc_id,
            "legacyDocID": legacy_doc_id if legacy_doc_id and legacy_doc_id != doc_id else None,
            "contentHash": _cloud_vault_hmac_hex(plaintext, config["vaultKey"], "project-memory-content"),
            "contentHashVersion": 2,
            "sourceSessionCount": int(parsed.get("sourceSessionCount") or 0),
            "sourceConversationCount": int(parsed.get("sourceConversationCount") or 0),
            "generatedAt": parsed.get("generatedAt"),
            "freshness": parsed.get("freshness") or "fresh",
            "visualKinds": visual_kinds,
            "sealedSnapshot": sealed_snapshot,
        }
        if payload["legacyDocID"] is None:
            payload.pop("legacyDocID")
        result = _call_firebase_callable("commitEncryptedProjectMemorySnapshot", payload, config)
    except (RuntimeError, ValueError, TypeError) as exc:
        return _json_unavailable(
            "PROJECT_MEMORY_CLOUD_SYNC_FAILED",
            "local project memory snapshot could not be synced to cloud",
            error=str(exc),
            projectSlug=slug,
        )

    return json.dumps(
        {
            "status": "ok",
            "source": "cloud-sync",
            "docID": doc_id,
            "projectSlug": parsed.get("projectSlug"),
            "projectDisplayName": parsed.get("projectDisplayName"),
            "contentHash": payload.get("contentHash"),
            "contentHashVersion": payload.get("contentHashVersion"),
            "result": result,
        },
        indent=2,
        default=str,
    )


@mcp.tool()
def burnbar_get_conversation(conversation_id: str, max_full_text_chars: int = 120_000) -> str:
    """Load one conversation row by id, including fullText (truncated if over max_full_text_chars)."""
    path = _default_db_path()
    with _connect_ro(path) as conn:
        conn.row_factory = sqlite3.Row
        cur = conn.execute("SELECT * FROM conversations WHERE id = ?", (conversation_id,))
        row = cur.fetchone()
    if not row:
        return json.dumps({"error": "not found", "id": conversation_id}, indent=2)
    d = _row_to_dict(row)
    ft = d.get("fullText")
    if isinstance(ft, str) and len(ft) > max_full_text_chars:
        d["fullText"] = ft[: max_full_text_chars // 2] + "\n… [truncated] …\n" + ft[-max_full_text_chars // 2 :]
        d["fullTextTruncated"] = True
    return json.dumps(d, indent=2, default=str)


@mcp.tool()
def burnbar_recent_usage(limit: int = 40) -> str:
    """Recent token_usage rows (cost, model, provider, session, times)."""
    lim = max(1, min(int(limit), 500))
    path = _default_db_path()
    with _connect_ro(path) as conn:
        conn.row_factory = sqlite3.Row
        cur = conn.execute(
            """
            SELECT id, provider, sessionId, projectName, model, totalTokens, cost, startTime, endTime
            FROM token_usage
            ORDER BY startTime DESC
            LIMIT ?
            """,
            (lim,),
        )
        rows = [_row_to_dict(r) for r in cur.fetchall()]
    return json.dumps({"usage": rows}, indent=2, default=str)


@mcp.tool()
def burnbar_project_summary(project_name: str | None = None, days: int = 30) -> str:
    """
    Pre-aggregated cost and session summary per project over a rolling time window.
    Pass project_name to narrow to one project, or omit for all projects ranked by total cost.
    """
    lim_days = max(1, min(int(days), 365))
    path = _default_db_path()
    with _connect_ro(path) as conn:
        conn.row_factory = sqlite3.Row
        sql = """
            SELECT
                projectName,
                COUNT(DISTINCT sessionId) AS sessions,
                SUM(totalTokens) AS totalTokens,
                SUM(cost) AS totalCost,
                MIN(startTime) AS firstSession,
                MAX(startTime) AS lastSession,
                COUNT(DISTINCT model) AS modelsUsed,
                COUNT(DISTINCT provider) AS providersUsed
            FROM token_usage
            WHERE startTime >= datetime('now', ? || ' days')
        """
        args: list[Any] = [f"-{lim_days}"]
        if project_name:
            sql += " AND projectName = ?"
            args.append(project_name)
        sql += " GROUP BY projectName ORDER BY totalCost DESC"
        cur = conn.execute(sql, args)
        rows = [_row_to_dict(r) for r in cur.fetchall()]
    return json.dumps({"days": lim_days, "projects": rows}, indent=2, default=str)


@mcp.tool()
def burnbar_chat_messages(limit: int = 80) -> str:
    """In-app assistant chat_messages rows (role + content), most recent last."""
    lim = max(1, min(int(limit), 500))
    path = _default_db_path()
    with _connect_ro(path) as conn:
        conn.row_factory = sqlite3.Row
        cur = conn.execute(
            """
            SELECT id, role, content, timestamp, cliUsed
            FROM chat_messages
            ORDER BY timestamp DESC
            LIMIT ?
            """,
            (lim,),
        )
        rows = [_row_to_dict(r) for r in cur.fetchall()]
    return json.dumps({"messages": list(reversed(rows))}, indent=2, default=str)


@mcp.tool()
def burnbar_record_hermes_usage(
    provider_id: str,
    model_id: str,
    input_tokens: int,
    output_tokens: int,
    cost: float = 0.0,
    cache_creation_tokens: int = 0,
    cache_read_tokens: int = 0,
    reasoning_tokens: int = 0,
    session_id: str | None = None,
    project_name: str | None = None,
    confidence: str = "exact",
    idempotency_key: str | None = None,
    recorded_at_iso: str | None = None,
) -> str:
    """
    Append an exact (or estimate) token-usage row to the OpenBurnBar usage
    ledger so the macOS app picks it up the next time it imports the daemon
    runtime snapshot. Idempotent: re-sending the same `idempotency_key` will
    not double-count the spend.

    `provider_id` must be one of the daemon-known IDs:
        zai, minimax, ollama, openai, anthropic, google, deepseek, mistral,
        meta, cohere, xai, amazon, alibaba, moonshot, hermes.

    `confidence` must be one of: exact (default for exact provider responses),
    derived_exact, high_confidence_estimate, low_confidence_estimate, unknown.

    Use this from Hermes whenever a model call returns provider usage and you
    want OpenBurnBar to know about it without going through the macOS app.
    """
    if recorded_at_iso:
        try:
            recorded_at = datetime.fromisoformat(recorded_at_iso.replace("Z", "+00:00"))
        except ValueError as exc:
            return json.dumps(
                {"error": f"recorded_at_iso must be ISO8601: {exc}"},
                indent=2,
            )
    else:
        recorded_at = datetime.now(UTC)

    try:
        event = UsageEvent(
            provider_id=provider_id,
            model_id=model_id,
            input_tokens=int(input_tokens),
            output_tokens=int(output_tokens),
            cache_creation_tokens=int(cache_creation_tokens),
            cache_read_tokens=int(cache_read_tokens),
            reasoning_tokens=int(reasoning_tokens),
            cost=float(cost),
            recorded_at=recorded_at,
            run_id=None,
            session_id=session_id,
            project_name=project_name,
            confidence=confidence,
        )
    except ValueError as exc:
        return json.dumps({"error": str(exc)}, indent=2)

    key = idempotency_key or derive_idempotency_key(
        provider_id=provider_id,
        model_id=model_id,
        session_id=session_id,
        recorded_at=recorded_at,
    )
    try:
        result = append_usage_record(event=event, idempotency_key=key)
    except (OSError, ValueError) as exc:
        return json.dumps(
            {
                "error": str(exc),
                "hint": (
                    "Ensure ~/Library/Application Support/OpenBurnBar exists or set "
                    "OPENBURNBAR_USAGE_LEDGER_PATH to a writable absolute path."
                ),
            },
            indent=2,
        )
    return json.dumps(result, indent=2)


@mcp.tool()
def burnbar_resolve_usage_ledger_path() -> str:
    """Return the usage-events.jsonl path the writer will use, for debugging."""
    path = default_ledger_path()
    return json.dumps(
        {
            "path": str(path),
            "exists": path.is_file(),
            "knownProviderIDs": sorted(KNOWN_PROVIDER_IDS),
            "knownConfidenceValues": sorted(KNOWN_CONFIDENCE),
        },
        indent=2,
    )


# ---------------------------------------------------------------------------
# Budget tools (Phase 7)
# ---------------------------------------------------------------------------
# Reads + writes against budget_rules / budget_events (schema v42, see
# AgentLens/Services/DataStore/OpenBurnBarDatabase.swift). Write tools are
# strictly scoped to budget_rules + budget_events; nothing else is mutable from
# MCP.

_BUDGET_PERIODS = {"day", "week", "month", "allTime"}
_BUDGET_SCOPES = {"credential", "project", "global", "organization"}
_BUDGET_BEHAVIORS = {
    "warnThenBlock",
    "hardBlock",
    "warnOnly",
    "hardBlockWithFallback",
}
_BUDGET_GROUP_BY = {"credential", "project", "model", "provider", "day"}


def _budget_period_window_start(period: str) -> str | None:
    """Return SQLite datetime modifier for the start of the rule's current period."""
    if period == "day":
        return "datetime('now', 'start of day')"
    if period == "week":
        return "datetime('now', '-7 days')"
    if period == "month":
        return "datetime('now', 'start of month')"
    return None  # allTime


@mcp.tool()
def burnbar_query_spend(
    group_by: str = "credential",
    period: str = "month",
    filter_provider: str | None = None,
    filter_project: str | None = None,
    limit: int = 20,
) -> str:
    """
    Ranked spend breakdown for the requested period and grouping dimension.

    group_by: one of `credential`, `project`, `model`, `provider`, `day`.
    period:   one of `day`, `week`, `month`, `allTime`.
    filter_provider: optional providerID filter (e.g. "anthropic", "openai", "openrouter").
    filter_project:  optional projectName filter.
    Returns ordered rows with totals so Hermes can answer "where did the money go?"
    """
    if group_by not in _BUDGET_GROUP_BY:
        return json.dumps({"error": f"group_by must be one of {sorted(_BUDGET_GROUP_BY)}"})
    if period not in _BUDGET_PERIODS:
        return json.dumps({"error": f"period must be one of {sorted(_BUDGET_PERIODS)}"})

    column_map = {
        "credential": "providerAccountLabel",
        "project": "projectName",
        "model": "model",
        "provider": "provider",
        "day": "DATE(startTime)",
    }
    column = column_map[group_by]
    window = _budget_period_window_start(period)

    clauses: list[str] = []
    args: list[Any] = []
    if window:
        clauses.append(f"startTime >= {window}")
    if filter_provider:
        clauses.append("providerID = ?")
        args.append(filter_provider)
    if filter_project:
        clauses.append("projectName = ?")
        args.append(filter_project)
    where_sql = ("WHERE " + " AND ".join(clauses)) if clauses else ""

    # S608: column comes from column_map and where_sql uses only fixed clauses with bound parameters.
    sql = f"""
        SELECT {column} AS label,
               COALESCE(SUM(cost), 0) AS totalCost,
               COALESCE(SUM(totalTokens), 0) AS totalTokens,
               COUNT(*) AS sessionCount
        FROM token_usage
        {where_sql}
        GROUP BY {column}
        ORDER BY totalCost DESC
        LIMIT ?
    """
    args.append(max(1, min(int(limit), 200)))

    path = _default_db_path()
    with _connect_ro(path) as conn:
        conn.row_factory = sqlite3.Row
        rows = [dict(r) for r in conn.execute(sql, args).fetchall()]

    return json.dumps(
        {"groupBy": group_by, "period": period, "rows": rows},
        indent=2,
        default=str,
    )


@mcp.tool()
def burnbar_budget_status(
    credential_account_id: str | None = None,
    project_name: str | None = None,
) -> str:
    """
    All active budget rules with their current spend, projected period-end, and remaining headroom.

    Pass credential_account_id (hashed partition token from token_usage.providerAccountID)
    to narrow to one credential. Pass project_name to narrow to one project.
    """
    path = _default_db_path()
    with _connect_ro(path) as conn:
        conn.row_factory = sqlite3.Row
        rule_sql = "SELECT * FROM budget_rules WHERE isEnabled = 1"
        rule_args: list[Any] = []
        if credential_account_id:
            rule_sql += " AND scope = 'credential' AND accountID = ?"
            rule_args.append(credential_account_id)
        if project_name:
            rule_sql += " AND scope = 'project' AND projectName = ?"
            rule_args.append(project_name)
        rules = [dict(r) for r in conn.execute(rule_sql, rule_args).fetchall()]

        snapshots = []
        for rule in rules:
            window = _budget_period_window_start(rule.get("period", "month"))
            spend_clauses: list[str] = []
            spend_args: list[Any] = []
            if window:
                spend_clauses.append(f"startTime >= {window}")
            if rule.get("scope") == "credential":
                if rule.get("providerID"):
                    spend_clauses.append("providerID = ?")
                    spend_args.append(rule["providerID"])
                if rule.get("accountID"):
                    spend_clauses.append("providerAccountID = ?")
                    spend_args.append(rule["accountID"])
            elif rule.get("scope") == "project" and rule.get("projectName"):
                spend_clauses.append("projectName = ?")
                spend_args.append(rule["projectName"])
            spend_where = ("WHERE " + " AND ".join(spend_clauses)) if spend_clauses else ""
            spend_row = conn.execute(
                # S608: spend_where uses only fixed scope clauses with bound parameters.
                f"SELECT COALESCE(SUM(cost), 0) AS total FROM token_usage {spend_where}",  # noqa: S608
                spend_args,
            ).fetchone()
            used = spend_row["total"] if spend_row else 0
            limit = rule.get("amountUSD", 0) or 0
            used_percent = (used / limit * 100) if limit > 0 else 0
            snapshots.append(
                {
                    "ruleID": rule["id"],
                    "label": rule.get("label") or rule.get("identifier") or rule["id"],
                    "scope": rule.get("scope"),
                    "providerID": rule.get("providerID"),
                    "accountID": rule.get("accountID"),
                    "projectName": rule.get("projectName"),
                    "period": rule.get("period"),
                    "behavior": rule.get("behavior"),
                    "amountUSD": limit,
                    "usedUSD": used,
                    "remainingUSD": max(0, limit - used),
                    "usedPercent": round(used_percent, 2),
                    "pausedUntil": rule.get("pausedUntil"),
                    "isEnabled": bool(rule.get("isEnabled", 1)),
                }
            )

    return json.dumps({"rules": snapshots}, indent=2, default=str)


@mcp.tool()
def burnbar_spend_forecast(
    credential_account_id: str | None = None,
    project_name: str | None = None,
    horizon_days: int = 30,
) -> str:
    """
    Linear forecast for spend over the next horizon_days based on the trailing 7-day average.
    Returns trailingDailyAverageUSD and projectedTotalUSD per matched scope.
    """
    horizon = max(1, min(int(horizon_days), 365))
    path = _default_db_path()
    with _connect_ro(path) as conn:
        conn.row_factory = sqlite3.Row
        clauses: list[str] = ["startTime >= datetime('now', '-7 days')"]
        args: list[Any] = []
        if credential_account_id:
            clauses.append("providerAccountID = ?")
            args.append(credential_account_id)
        if project_name:
            clauses.append("projectName = ?")
            args.append(project_name)
        where_sql = "WHERE " + " AND ".join(clauses)
        row = conn.execute(
            # S608: where_sql is assembled only from fixed clauses with bound parameters.
            f"SELECT COALESCE(SUM(cost), 0) AS total FROM token_usage {where_sql}",  # noqa: S608
            args,
        ).fetchone()
        trailing_total = row["total"] if row else 0
        daily_avg = trailing_total / 7
        projected = daily_avg * horizon

    return json.dumps(
        {
            "credentialAccountID": credential_account_id,
            "projectName": project_name,
            "horizonDays": horizon,
            "trailingDailyAverageUSD": round(daily_avg, 4),
            "projectedTotalUSD": round(projected, 4),
        },
        indent=2,
    )


@mcp.tool()
def burnbar_budget_audit(rule_id: str | None = None, limit: int = 50) -> str:
    """Recent audit events from budget_events (warnings, blocks, overrides, rule mutations)."""
    lim = max(1, min(int(limit), 500))
    path = _default_db_path()
    with _connect_ro(path) as conn:
        conn.row_factory = sqlite3.Row
        sql = "SELECT * FROM budget_events"
        args: list[Any] = []
        if rule_id:
            sql += " WHERE ruleID = ?"
            args.append(rule_id)
        sql += " ORDER BY occurredAt DESC LIMIT ?"
        args.append(lim)
        rows = [dict(r) for r in conn.execute(sql, args).fetchall()]
    return json.dumps({"events": rows}, indent=2, default=str)


@mcp.tool()
def burnbar_set_budget_limit(
    scope: str,
    amount_usd: float,
    period: str = "month",
    behavior: str = "warnThenBlock",
    rule_id: str | None = None,
    provider_id: str | None = None,
    account_id: str | None = None,
    project_name: str | None = None,
    label: str | None = None,
    enabled: bool = True,
) -> str:
    """
    Create or update a budget rule. Returns the persisted row.

    scope: `credential`, `project`, `global`, or `organization`.
    For credential scope, supply provider_id (and optionally account_id).
    For project scope, supply project_name.
    """
    if scope not in _BUDGET_SCOPES:
        return json.dumps({"error": f"scope must be one of {sorted(_BUDGET_SCOPES)}"})
    if period not in _BUDGET_PERIODS:
        return json.dumps({"error": f"period must be one of {sorted(_BUDGET_PERIODS)}"})
    if behavior not in _BUDGET_BEHAVIORS:
        return json.dumps({"error": f"behavior must be one of {sorted(_BUDGET_BEHAVIORS)}"})
    if amount_usd <= 0:
        return json.dumps({"error": "amount_usd must be > 0"})

    import uuid

    now = datetime.now(UTC).isoformat(sep=" ", timespec="milliseconds")
    rid = rule_id or str(uuid.uuid4())
    path = _default_db_path()
    with _connect_rw(path) as conn:
        conn.execute(
            """
            INSERT INTO budget_rules (
                id, scope, identifier, providerID, accountID, projectName, label,
                amountUSD, period, behavior, fallbackCredentialIDsJSON, pausedUntil,
                createdAt, updatedAt, syncedAt, sourceDeviceID, isEnabled
            ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET
                scope = excluded.scope,
                providerID = excluded.providerID,
                accountID = excluded.accountID,
                projectName = excluded.projectName,
                label = excluded.label,
                amountUSD = excluded.amountUSD,
                period = excluded.period,
                behavior = excluded.behavior,
                pausedUntil = NULL,
                updatedAt = excluded.updatedAt,
                syncedAt = NULL,
                isEnabled = excluded.isEnabled
            """,
            (
                rid,
                scope,
                None,
                provider_id,
                account_id,
                project_name,
                label,
                amount_usd,
                period,
                behavior,
                None,
                None,
                now,
                now,
                None,
                "mcp_tool",
                1 if enabled else 0,
            ),
        )
        conn.execute(
            """
            INSERT INTO budget_events (
                id, ruleID, kind, source, amountAtEvent, limitAtEvent,
                detailJSON, occurredAt, syncedAt, sourceDeviceID
            ) VALUES (?,?,?,?,?,?,?,?,?,?)
            """,
            (
                str(uuid.uuid4()),
                rid,
                "ruleCreated" if not rule_id else "ruleUpdated",
                "mcp_tool",
                0.0,
                amount_usd,
                json.dumps({"label": label or "", "period": period, "scope": scope}),
                now,
                None,
                "mcp_tool",
            ),
        )
        conn.commit()
    return json.dumps(
        {"ruleID": rid, "scope": scope, "amountUSD": amount_usd, "period": period, "behavior": behavior}, indent=2
    )


@mcp.tool()
def burnbar_pause_budget_gate(rule_id: str, until_iso: str) -> str:
    """
    Pause a rule until until_iso (ISO 8601, e.g. "2026-05-26T09:00:00Z").
    The gate short-circuits to .paused for matching requests until that time.
    """
    try:
        parsed = datetime.fromisoformat(until_iso.replace("Z", "+00:00"))
    except ValueError:
        return json.dumps({"error": "until_iso must be ISO 8601 (e.g. 2026-05-26T09:00:00Z)"})

    now = datetime.now(UTC).isoformat(sep=" ", timespec="milliseconds")
    until_str = parsed.isoformat(sep=" ", timespec="milliseconds")

    path = _default_db_path()
    with _connect_rw(path) as conn:
        rule_row = conn.execute("SELECT amountUSD FROM budget_rules WHERE id = ?", (rule_id,)).fetchone()
        if rule_row is None:
            return json.dumps({"error": f"no rule with id {rule_id}"})
        conn.execute(
            "UPDATE budget_rules SET pausedUntil = ?, updatedAt = ?, syncedAt = NULL WHERE id = ?",
            (until_str, now, rule_id),
        )
        import uuid

        conn.execute(
            """
            INSERT INTO budget_events (
                id, ruleID, kind, source, amountAtEvent, limitAtEvent,
                detailJSON, occurredAt, syncedAt, sourceDeviceID
            ) VALUES (?,?,?,?,?,?,?,?,?,?)
            """,
            (
                str(uuid.uuid4()),
                rule_id,
                "pause",
                "mcp_tool",
                0.0,
                float(rule_row[0]) if rule_row[0] is not None else 0.0,
                json.dumps({"pausedUntil": until_str}),
                now,
                None,
                "mcp_tool",
            ),
        )
        conn.commit()
    return json.dumps({"ruleID": rule_id, "pausedUntil": until_str}, indent=2)


@mcp.tool()
def burnbar_resume_budget_gate(rule_id: str) -> str:
    """Cancel an active pause on a rule. Resumes enforcement immediately."""
    now = datetime.now(UTC).isoformat(sep=" ", timespec="milliseconds")
    path = _default_db_path()
    with _connect_rw(path) as conn:
        rule_row = conn.execute("SELECT amountUSD FROM budget_rules WHERE id = ?", (rule_id,)).fetchone()
        if rule_row is None:
            return json.dumps({"error": f"no rule with id {rule_id}"})
        conn.execute(
            "UPDATE budget_rules SET pausedUntil = NULL, updatedAt = ?, syncedAt = NULL WHERE id = ?",
            (now, rule_id),
        )
        import uuid

        conn.execute(
            """
            INSERT INTO budget_events (
                id, ruleID, kind, source, amountAtEvent, limitAtEvent,
                detailJSON, occurredAt, syncedAt, sourceDeviceID
            ) VALUES (?,?,?,?,?,?,?,?,?,?)
            """,
            (
                str(uuid.uuid4()),
                rule_id,
                "resume",
                "mcp_tool",
                0.0,
                float(rule_row[0]) if rule_row[0] is not None else 0.0,
                None,
                now,
                None,
                "mcp_tool",
            ),
        )
        conn.commit()
    return json.dumps({"ruleID": rule_id, "resumed": True}, indent=2)


@mcp.tool()
def burnbar_org_spend(
    period: str = "month",
    group_by: str = "user",
    limit: int = 50,
) -> str:
    """
    Enterprise cross-seat spend rollup.

    Reads from the local copy of `token_usage` (which `CloudSyncService` already syncs
    from every seat — fields `sourceDeviceID` and `sourceDeviceName` are present per
    row). Groups by user (sourceDeviceID), project, credential, or provider.

    group_by: one of `user`, `project`, `credential`, `provider`.
    period:   one of `day`, `week`, `month`, `allTime`.

    Note: full org-publish of shared rules across seats (sync of `budget_rules` /
    `budget_events`) is a follow-up — each seat currently configures rules locally.
    Per-seat spend reporting is fully functional.
    """
    if period not in _BUDGET_PERIODS:
        return json.dumps({"error": f"period must be one of {sorted(_BUDGET_PERIODS)}"})
    org_groups = {"user", "project", "credential", "provider"}
    if group_by not in org_groups:
        return json.dumps({"error": f"group_by must be one of {sorted(org_groups)}"})

    column_map = {
        "user": "COALESCE(sourceDeviceName, sourceDeviceID, 'local')",
        "project": "projectName",
        "credential": "COALESCE(providerAccountLabel, providerAccountID, 'default')",
        "provider": "provider",
    }
    column = column_map[group_by]
    window = _budget_period_window_start(period)

    clauses = []
    if window:
        clauses.append(f"startTime >= {window}")
    where_sql = ("WHERE " + " AND ".join(clauses)) if clauses else ""
    # S608: column comes from column_map and where_sql uses only fixed period clauses.
    sql = f"""
        SELECT {column} AS label,
               COALESCE(SUM(cost), 0) AS totalCost,
               COALESCE(SUM(totalTokens), 0) AS totalTokens,
               COUNT(DISTINCT sessionId) AS sessionCount,
               COUNT(DISTINCT COALESCE(sourceDeviceID, 'local')) AS deviceCount
        FROM token_usage
        {where_sql}
        GROUP BY {column}
        ORDER BY totalCost DESC
        LIMIT ?
    """

    lim = max(1, min(int(limit), 500))
    path = _default_db_path()
    with _connect_ro(path) as conn:
        conn.row_factory = sqlite3.Row
        rows = [dict(r) for r in conn.execute(sql, [lim]).fetchall()]

    return json.dumps(
        {"groupBy": group_by, "period": period, "rows": rows},
        indent=2,
        default=str,
    )


@mcp.tool()
def burnbar_list_resumable_conversations(
    provider: str | None = None,
    project: str | None = None,
    since: str | None = None,
    limit: int = 20,
    offset: int = 0,
) -> str:
    """
    List recent OpenBurnBar conversations that can be resumed.

    Returns rows with both the stable composite id and the raw provider session id.
    `can_resume_native` is true only when the source provider is native-eligible
    and the source CLI's on-disk handle validates locally.
    """
    try:
        payload = list_resumable_conversations(
            provider=provider,
            project=project,
            since=since,
            limit=limit,
            offset=offset,
        )
    except Exception as exc:
        payload = {
            "kind": "error",
            "code": "resume_list_failed",
            "recovery": str(exc),
        }
    return json.dumps(payload, indent=2, default=str)


@mcp.tool()
def burnbar_resume_conversation(
    session_id: str,
    target_harness: str | None = None,
    target_model: str | None = None,
    max_tokens: int = 8000,
    print_only: bool = True,
) -> str:
    """
    Compose a BurnBar Resume plan for a prior conversation.

    Returns one of three stable response shapes: `native`, `ported`, or `error`.
    The default is emit-only and keeps plaintext on-device. A 0600 temp briefing
    file is created only when `print_only` is false.
    """
    try:
        payload = dispatch_resume(
            session_id,
            target_harness=target_harness,
            target_model=target_model,
            max_tokens=max_tokens,
            print_only=print_only,
        )
    except Exception as exc:
        payload = {
            "kind": "error",
            "code": "resume_failed",
            "session_id": session_id,
            "recovery": str(exc),
        }
    return json.dumps(payload, indent=2, default=str)


@mcp.tool()
def burnbar_spawn_resume(
    session_id: str,
    target_harness: str | None = None,
    target_model: str | None = None,
    max_tokens: int = 8000,
    cleanup_after_seconds: int = 600,
) -> str:
    """
    Spawn a native or cross-ported resume target as a detached local process.

    This is intentionally separate from `burnbar_resume_conversation` so the
    Phase A emit-only default stays stable for existing MCP clients.
    """
    try:
        payload = spawn_resume(
            session_id,
            target_harness=target_harness,
            target_model=target_model,
            max_tokens=max_tokens,
            cleanup_after_seconds=cleanup_after_seconds,
        )
    except Exception as exc:
        payload = {
            "kind": "error",
            "code": "resume_spawn_failed",
            "session_id": session_id,
            "recovery": str(exc),
        }
    return json.dumps(payload, indent=2, default=str)


def main() -> None:
    mcp.run()


if __name__ == "__main__":
    main()
