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
from datetime import datetime, timezone
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
OPENBURNBAR_STOPWORDS = {
    "the", "and", "for", "with", "that", "this", "from", "how", "what", "where",
    "when", "why", "are", "was", "were", "you", "your", "have", "has", "had",
    "into", "onto", "can", "could", "should", "would",
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
        raise ValueError(
            "BURNBAR_DB_PATH basename must match [A-Za-z0-9._-]+\\.sqlite[0-9]?"
        )
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


def fts5_safe_query(user_input: str) -> str:
    """
    Natural-language friendly FTS5 query builder, matching BurnBarFTSQueryBuilder.naturalLanguage().
    Uses OR for longer queries to improve recall; AND for short precision queries.
    Strips common English stopwords from NL queries.
    """
    # Common English stopwords
    stopwords = {
        "a", "an", "the", "and", "or", "but", "if", "then", "else", "when", "where", "why", "how",
        "what", "who", "which", "is", "are", "was", "were", "be", "been", "being", "to", "of", "in",
        "on", "for", "with", "about", "into", "from", "at", "by", "as", "it", "its", "this", "that",
        "these", "those", "i", "you", "we", "they", "he", "she", "my", "your", "our", "their", "me",
        "him", "her", "them", "do", "does", "did", "have", "has", "had", "can", "could", "would",
        "should", "will", "just", "not", "no", "yes", "so", "very", "too", "also", "only", "even",
        "there", "here", "some", "any", "all", "each", "every", "both", "few", "more", "most", "other",
        "such", "than", "up", "out", "off", "over", "under", "again", "once", "ever", "please", "tell",
        "give", "show", "find", "search", "look", "get", "got", "make", "made", "using", "use", "used"
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
        "ization", "ations", "ation", "ments", "ment", "ingly", "edly",
        "ing", "ies", "ied", "ers", "er", "ed", "s",
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


def _aesgcm_open(nonce: bytes, ciphertext_and_tag: bytes, key: bytes) -> bytes:
    try:
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    except ImportError as exc:
        raise RuntimeError("install cryptography to decrypt OpenBurnBar cloud search hits") from exc
    return AESGCM(key).decrypt(nonce, ciphertext_and_tag, None)


def _open_cloud_sealed_text(envelope: dict[str, Any], vault_key: bytes) -> str:
    if envelope.get("algorithm") != "AES-256-GCM":
        raise ValueError("unsupported sealed text algorithm")
    nonce = base64.b64decode(str(envelope["nonce"]))
    ciphertext = base64.b64decode(str(envelope["ciphertext"]))
    tag = base64.b64decode(str(envelope["tag"]))
    return _aesgcm_open(nonce, ciphertext + tag, vault_key).decode("utf-8")


def _open_cloud_blob_envelope(envelope: dict[str, Any], vault_key: bytes) -> bytes:
    if envelope.get("algorithm") != "AES-256-GCM":
        raise ValueError("unsupported blob algorithm")
    combined = base64.b64decode(str(envelope["sealedBoxBase64"]))
    if len(combined) <= 28:
        raise ValueError("encrypted blob envelope is too short")
    plaintext = _aesgcm_open(combined[:12], combined[12:], vault_key)
    expected = str(envelope.get("plaintextSHA256", ""))
    actual = hashlib.sha256(plaintext).hexdigest()
    if actual != expected:
        raise ValueError("encrypted blob SHA-256 mismatch")
    return plaintext


def _table_names(conn: sqlite3.Connection) -> set[str]:
    rows = conn.execute(
        "SELECT name FROM sqlite_master WHERE type IN ('table', 'virtual table')"
    ).fetchall()
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
        return sum(float(l) * float(r) for l, r in zip(lhs, rhs))
    if metric == "euclidean":
        return -math.sqrt(sum((float(l) - float(r)) ** 2 for l, r in zip(lhs, rhs)))

    dot = 0.0
    lhs_norm = 0.0
    rhs_norm = 0.0
    for l_value, r_value in zip(lhs, rhs):
        l = float(l_value)
        r = float(r_value)
        dot += l * r
        lhs_norm += l * l
        rhs_norm += r * r
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
        cur = conn.execute(
            "SELECT DISTINCT provider FROM conversations ORDER BY provider"
        )
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
        for hit in (raw_hits if isinstance(raw_hits, list) else []):
            if not isinstance(hit, dict):
                continue
            try:
                title = _open_cloud_sealed_text(hit["sealedTitle"], vault_key)
                snippet = _open_cloud_sealed_text(hit["sealedSnippet"], vault_key)
            except (KeyError, TypeError, ValueError, RuntimeError):
                continue
            hits.append({
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
                "indexVersion": hit.get("indexVersion"),
                "semanticHashVersion": hit.get("semanticHashVersion"),
            })
    except RuntimeError as exc:
        return _json_unavailable("CLOUD_SEARCH_FAILED", "hosted encrypted search failed", error=str(exc))

    return json.dumps({
        "status": "ok",
        "query": query,
        "results": hits,
        "privacy": "query plaintext and vault key stayed local; Firebase received only keyed token/semantic hashes",
    }, indent=2, default=str)


@mcp.tool()
def burnbar_cloud_get_conversation_body(
    storage_path: str,
    body_hash: str,
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
        plaintext = _open_cloud_blob_envelope(envelope, config["vaultKey"])
        actual_hash = hashlib.sha256(plaintext).hexdigest()
        if actual_hash != body_hash:
            raise RuntimeError("decrypted body hash did not match the search hit")
        full_text = plaintext.decode("utf-8")
    except (RuntimeError, urllib.error.URLError, json.JSONDecodeError, ValueError) as exc:
        return _json_unavailable("CLOUD_BODY_DECRYPT_FAILED", "hosted encrypted body could not be decrypted", error=str(exc))

    truncated = False
    max_chars = max(1, min(int(max_full_text_chars), 500_000))
    if len(full_text) > max_chars:
        full_text = full_text[: max_chars // 2] + "\n… [truncated] …\n" + full_text[-max_chars // 2 :]
        truncated = True
    return json.dumps({
        "status": "ok",
        "storagePath": storage_path,
        "bodyHash": body_hash,
        "fullText": full_text,
        "fullTextTruncated": truncated,
    }, indent=2)


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
        recorded_at = datetime.now(timezone.utc)

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


def main() -> None:
    mcp.run()


if __name__ == "__main__":
    main()
