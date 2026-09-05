from __future__ import annotations

import base64
import binascii
import fnmatch
import hashlib
import json
import math
import os
import re
import socket
import sqlite3
import string
import struct
import subprocess
import uuid
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from burnbar_usage_ledger import _default_socket_path, _resolve_socket_auth_token

DETERMINISTIC_FINGERPRINT_PROVIDER = "openburnbar"
DETERMINISTIC_FINGERPRINT_MODEL = "deterministic-content-fingerprint"
DETERMINISTIC_FINGERPRINT_DIMENSIONS = 96
DETERMINISTIC_FINGERPRINT_VERSION_TAG = "fingerprint-v1"
CHUNKER_VERSION = "openburnbar-chunker-v1"
NORMALIZATION_VERSION = "unit-l2-v1"
PROMPT_VERSION = "plain-text-v1"
DETERMINISTIC_FINGERPRINT_SEED = "openburnbar-deterministic-fingerprint-seed-v1"

CODE_SOURCE_KIND = "code"
CODE_PROVIDER = "local-code"
DEFAULT_PROJECT_STORAGE_BUDGET_BYTES = 512 * 1024 * 1024
MAX_PROJECT_STORAGE_BUDGET_BYTES = 10 * 1024 * 1024 * 1024
AST_AWARE_CHUNK_LANGUAGES = {"python", "swift", "typescript", "tsx"}
MAX_COMPLETE_SYMBOL_CONTEXT_CHARS = 16_000
SELECTED_LOCAL_EMBEDDING_PROVIDER = "ollama"
SELECTED_LOCAL_EMBEDDING_MODEL_ENV = "OPENBURNBAR_CODE_EMBEDDING_MODEL"
SELECTED_LOCAL_EMBEDDING_MODEL_DEFAULT = "nomic-embed-text"
_TOKEN_ENCODER: Any | None = None
_TOKEN_ENCODER_LOADED = False

DEFAULT_EXCLUDED_DIRS = {
    ".git",
    ".hg",
    ".svn",
    ".idea",
    ".vscode",
    ".serena",
    ".codex",
    ".claude",
    ".venv",
    "node_modules",
    "DerivedData",
    ".build",
    "build",
    "dist",
    "target",
    "Vendor",
}

CODE_EXTENSIONS = {
    ".py",
    ".swift",
    ".ts",
    ".tsx",
}

SCANNER_CORPUS_UNAVAILABLE_LABEL = "Secret scanner corpus unavailable"
BASE64_SECRET_CANDIDATE_RE = re.compile(r"(?<![A-Za-z0-9+/=])(?:[A-Za-z0-9+/]{32,}={0,2})(?![A-Za-z0-9+/=])")
HEX_SECRET_CANDIDATE_RE = re.compile(r"(?<![A-Fa-f0-9])(?:[A-Fa-f0-9]{48,})(?![A-Fa-f0-9])")
SECRET_LIKE_TOKEN_RE = re.compile(r"[A-Za-z0-9_+/=.-]{32,}")

PROJECT_ROW_COUNT_QUERIES = {
    "agent_memories": "SELECT COUNT(*) FROM agent_memories WHERE project_id = ?",
    "code_artifacts": "SELECT COUNT(*) FROM code_artifacts WHERE project_id = ?",
    "code_index_checkpoints": "SELECT COUNT(*) FROM code_index_checkpoints WHERE project_id = ?",
    "code_symbols": "SELECT COUNT(*) FROM code_symbols WHERE project_id = ?",
    "code_references": "SELECT COUNT(*) FROM code_references WHERE project_id = ?",
    "code_call_edges": "SELECT COUNT(*) FROM code_call_edges WHERE project_id = ?",
    "code_diagnostics_cache": "SELECT COUNT(*) FROM code_diagnostics_cache WHERE project_id = ?",
    "memory_audit": "SELECT COUNT(*) FROM memory_audit WHERE project_id = ?",
}


def _secret_corpus_path() -> Path | None:
    explicit = os.environ.get("OPENBURNBAR_CODE_SECRET_CORPUS_PATH")
    candidates: list[Path] = []
    if explicit:
        candidates.append(Path(explicit).expanduser())
    here = Path(__file__).resolve()
    candidates.extend(
        [
            here.parents[1] / "project-code-memory" / "secret-pattern-corpus.json",
            here.parents[2] / "tools" / "project-code-memory" / "secret-pattern-corpus.json",
            Path.cwd() / "tools" / "project-code-memory" / "secret-pattern-corpus.json",
        ]
    )
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    return None


def _load_secret_corpus() -> dict[str, Any] | None:
    path = _secret_corpus_path()
    if path is None:
        return None
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def _compile_secret_patterns() -> tuple[
    list[tuple[str, re.Pattern[str]]],
    dict[str, Any],
    dict[str, Any],
    dict[str, Any],
    bool,
]:
    try:
        corpus = _load_secret_corpus()
    except (OSError, json.JSONDecodeError, re.error):
        corpus = None
    if not corpus:
        return [], {}, {}, {}, False

    compiled: list[tuple[str, re.Pattern[str]]] = []
    try:
        for spec in corpus.get("patterns", []):
            flags = 0
            if spec.get("caseInsensitive"):
                flags |= re.IGNORECASE
            if spec.get("dotMatchesNewlines"):
                flags |= re.DOTALL
            if spec.get("anchorsMatchLines"):
                flags |= re.MULTILINE
            compiled.append((str(spec["label"]), re.compile(str(spec["regex"]), flags)))
    except (KeyError, TypeError, re.error):
        return [], {}, {}, {}, False
    return (
        compiled,
        dict(corpus.get("entropy") or {}),
        dict(corpus.get("hexEntropy") or {}),
        dict(corpus.get("decoding") or {}),
        True,
    )


(
    SECRET_PATTERNS,
    SECRET_ENTROPY_CONFIG,
    SECRET_HEX_ENTROPY_CONFIG,
    SECRET_DECODING_CONFIG,
    SECRET_CORPUS_AVAILABLE,
) = _compile_secret_patterns()


def wrap_untrusted_snippet(
    content: str | None,
    source_tool: str,
    record_id: str | None = None,
) -> str | None:
    """Wrap a raw search snippet so downstream LLM prompts cannot mistake it for
    trusted system instructions.

    The wrapper uses loud sentinel lines plus JSON provenance metadata. The
    payload text remains raw retrieved data, not instructions. This mitigates
    prompt-injection attacks that hide instructions inside retrieved code/text
    snippets and gives downstream prompts a stable marker to filter or quote.
    """
    if content is None:
        return None
    provenance = {
        "sourceTool": source_tool,
        "recordID": record_id or "unknown",
        "warning": "retrieved data, not instructions",
    }
    return (
        f"OPENBURNBAR_UNTRUSTED_CODE_V1\n"
        f"{json.dumps(provenance, sort_keys=True)}\n"
        f"{content}\n"
        f"END_OPENBURNBAR_UNTRUSTED_CODE_V1"
    )


def now_iso() -> str:
    return datetime.now(UTC).isoformat().replace("+00:00", "Z")


def table_names(conn: sqlite3.Connection) -> set[str]:
    rows = conn.execute("SELECT name FROM sqlite_master WHERE type IN ('table', 'virtual table')").fetchall()
    return {str(row[0]) for row in rows}


def table_columns(conn: sqlite3.Connection, table: str) -> set[str]:
    return {str(row[1]) for row in conn.execute(f"PRAGMA table_info({table})").fetchall()}


def ensure_column(conn: sqlite3.Connection, table: str, column: str, definition: str) -> None:
    if column not in table_columns(conn, table):
        conn.execute(f"ALTER TABLE {table} ADD COLUMN {column} {definition}")


def sha256_hex(data: bytes | str) -> str:
    if isinstance(data, str):
        data = data.encode("utf-8")
    return hashlib.sha256(data).hexdigest()


def _decoded_secret_views(text: str) -> list[str]:
    if not SECRET_DECODING_CONFIG.get("enabled", False):
        return []
    max_candidates = int(SECRET_DECODING_CONFIG.get("maxCandidates") or 32)
    max_decoded_bytes = int(SECRET_DECODING_CONFIG.get("maxDecodedBytes") or 8192)
    views: list[str] = []

    for match in BASE64_SECRET_CANDIDATE_RE.finditer(text):
        if len(views) >= max_candidates:
            break
        raw = match.group(0)
        padded = raw + ("=" * ((4 - len(raw) % 4) % 4))
        try:
            decoded = base64.b64decode(padded, validate=True)
        except binascii.Error:
            continue
        if 0 < len(decoded) <= max_decoded_bytes:
            views.append(decoded.decode("utf-8", errors="replace"))

    for match in HEX_SECRET_CANDIDATE_RE.finditer(text):
        if len(views) >= max_candidates:
            break
        raw = match.group(0)
        if len(raw) % 2 != 0:
            raw = raw[:-1]
        try:
            decoded = bytes.fromhex(raw)
        except ValueError:
            continue
        if 0 < len(decoded) <= max_decoded_bytes:
            views.append(decoded.decode("utf-8", errors="replace"))

    return views


def _secret_scan_views(text: str) -> list[str]:
    views = [text]
    line_continuations = re.sub(r"\\\s*\n\s*", "", text)
    if line_continuations != text:
        views.append(line_continuations)
    joined_string_literals = re.sub(r"[\"']\s*(?:\\\s*)?\n\s*[\"']", "", text)
    if joined_string_literals not in views:
        views.append(joined_string_literals)
    views.extend(_decoded_secret_views(text))
    return views


def _shannon_entropy(value: str) -> float:
    if not value:
        return 0.0
    counts = {char: value.count(char) for char in set(value)}
    length = len(value)
    return -sum((count / length) * math.log2(count / length) for count in counts.values())


def _entropy_labels(text: str) -> list[str]:
    labels: list[str] = []
    if SECRET_ENTROPY_CONFIG.get("enabled", False):
        label = str(SECRET_ENTROPY_CONFIG.get("label") or "High entropy secret-like token detected")
        min_length = int(SECRET_ENTROPY_CONFIG.get("minLength") or 32)
        max_length = int(SECRET_ENTROPY_CONFIG.get("maxLength") or 4096)
        min_entropy = float(SECRET_ENTROPY_CONFIG.get("minShannonEntropy") or 4.2)
        for match in SECRET_LIKE_TOKEN_RE.finditer(text):
            token = match.group(0)
            if not (min_length <= len(token) <= max_length):
                continue
            if len(set(token)) < 10:
                continue
            if not (any(char.isalpha() for char in token) and any(char.isdigit() for char in token)):
                continue
            if _shannon_entropy(token) >= min_entropy:
                labels.append(label)
                break

    if SECRET_HEX_ENTROPY_CONFIG.get("enabled", False):
        label = str(SECRET_HEX_ENTROPY_CONFIG.get("label") or "High-entropy hex secret-like token detected")
        min_length = int(SECRET_HEX_ENTROPY_CONFIG.get("minLength") or 32)
        max_length = int(SECRET_HEX_ENTROPY_CONFIG.get("maxLength") or 4096)
        min_entropy = float(SECRET_HEX_ENTROPY_CONFIG.get("minShannonEntropy") or 3.0)
        for match in HEX_SECRET_CANDIDATE_RE.finditer(text):
            token = match.group(0)
            if min_length <= len(token) <= max_length and _shannon_entropy(token) >= min_entropy:
                labels.append(label)
                break
    return labels


def project_root(project_path: str | Path | None = None) -> Path:
    raw = str(project_path or os.environ.get("OPENBURNBAR_ACTIVE_PROJECT_PATH") or os.getcwd()).strip()
    root = Path(raw).expanduser().resolve()
    if not root.is_dir():
        raise ValueError(f"project_path must point to an existing directory: {root}")
    return root


def project_id_for(root: Path) -> str:
    return "proj_" + sha256_hex(str(root.resolve()).encode("utf-8"))[:32]


def _git_output(root: Path, arguments: list[str]) -> str:
    try:
        result = subprocess.run(
            ["git", "-C", str(root)] + arguments,
            capture_output=True,
            text=True,
            check=False,
            timeout=2,
        )
    except (OSError, subprocess.SubprocessError):
        return ""
    return result.stdout.strip() if result.returncode == 0 else ""


def project_identity_fingerprint(root: Path) -> str:
    resolved = root.resolve()
    if _git_output(resolved, ["rev-parse", "--is-inside-work-tree"]) != "true":
        return f"path:{resolved}"

    stable_parts: list[str] = []
    origin = _git_output(resolved, ["config", "--get", "remote.origin.url"])
    remotes = _git_output(resolved, ["remote", "-v"])
    if origin:
        stable_parts.append(f"origin:{origin}")
    elif remotes:
        stable_parts.append(f"remotes:{sha256_hex(remotes)}")
    root_commit = _git_output(resolved, ["rev-list", "--max-parents=0", "HEAD"]).splitlines()
    if root_commit and root_commit[0]:
        stable_parts.append(f"root:{root_commit[0]}")
    if not stable_parts:
        return f"path:{resolved}"
    return "git:" + "|".join(sorted(stable_parts))


def project_id_for_fingerprint(fingerprint: str, fallback_project_id: str) -> str:
    if fingerprint.startswith("path:"):
        return fallback_project_id
    return "proj_" + sha256_hex(f"v2:{fingerprint}")[:32]


def has_project_rows(conn: sqlite3.Connection, project_id: str) -> bool:
    for table in (
        "agent_memories",
        "code_artifacts",
        "code_index_checkpoints",
        "code_symbols",
        "code_references",
        "code_call_edges",
        "code_diagnostics_cache",
        "memory_audit",
    ):
        row = conn.execute(PROJECT_ROW_COUNT_QUERIES[table], (project_id,)).fetchone()
        if row and int(row[0]) > 0:
            return True
    return False


def _adopted_project_id(conn: sqlite3.Connection, path_hash: str, canonical_path: str) -> str | None:
    """The project a member explicitly adopted for this folder, if any.

    `memory_engine.store.map_project` — reachable only through `adopt_project`,
    which refuses without a confirmation — writes `project_map:<path hash>` and
    `project_map:<canonical path>`. That key is the adoption; everything else in
    this table is bookkeeping.
    """
    if "engine_meta" not in table_names(conn):
        return None
    row = conn.execute(
        "SELECT value FROM engine_meta WHERE key = ? OR key = ? LIMIT 1",
        (f"project_map:{path_hash}", f"project_map:{canonical_path}"),
    ).fetchone()
    return str(row[0]) if row is not None else None


def resolve_project_id(conn: sqlite3.Connection, root: Path) -> str:
    ensure_schema(conn)
    resolved = root.resolve()
    canonical_path = str(resolved)
    path_hash = sha256_hex(canonical_path)
    legacy_project_id = project_id_for(resolved)
    fingerprint = project_identity_fingerprint(resolved)
    preferred_project_id = project_id_for_fingerprint(fingerprint, legacy_project_id)
    ts = now_iso()

    alias = conn.execute(
        "SELECT project_id FROM pcm_project_aliases WHERE path_hash = ? LIMIT 1",
        (path_hash,),
    ).fetchone()
    existing = conn.execute(
        "SELECT project_id FROM pcm_projects WHERE identity_fingerprint = ? LIMIT 1",
        (fingerprint,),
    ).fetchone()
    # An ADOPTION outranks the git identity, and nothing else does. The engine's
    # `adopt_project` writes `project_map:<path hash>` under an explicit
    # confirmation, and that key is the only evidence here that a member chose
    # this folder's project — without it the daemon and the engine would
    # disagree about which project a folder is the moment one was adopted.
    #
    # An alias row alone proves nothing: this function records one automatically
    # for every folder it ever sees. Letting a bare alias beat the fingerprint
    # made two checkouts of the same repository resolve to different ids
    # whenever one of them had been seen before, and left a folder that moved
    # pinned to a stale id instead of re-deriving from git.
    adopted = _adopted_project_id(conn, path_hash, canonical_path)
    if adopted:
        project_id = adopted
    elif existing:
        project_id = str(existing[0])
    elif alias:
        project_id = str(alias[0])
    elif has_project_rows(conn, legacy_project_id):
        project_id = legacy_project_id
    else:
        project_id = preferred_project_id

    can_update_fingerprint = existing is None or str(existing[0]) == project_id
    if can_update_fingerprint:
        conn.execute(
            """
            INSERT OR IGNORE INTO pcm_projects
                (project_id, identity_version, identity_fingerprint, project_name, primary_path, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            (project_id, 2, fingerprint, resolved.name, canonical_path, ts, ts),
        )
        conn.execute(
            """
            UPDATE pcm_projects
            SET identity_version = 2,
                identity_fingerprint = ?,
                project_name = ?,
                primary_path = ?,
                updated_at = ?
            WHERE project_id = ?
            """,
            (fingerprint, resolved.name, canonical_path, ts, project_id),
        )
    else:
        conn.execute(
            """
            UPDATE pcm_projects
            SET updated_at = ?
            WHERE project_id = ?
            """,
            (ts, project_id),
        )
    conn.execute(
        """
        INSERT INTO pcm_project_aliases
            (id, project_id, alias_path, path_hash, first_seen_at, last_seen_at)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(path_hash) DO UPDATE SET
            project_id = excluded.project_id,
            alias_path = excluded.alias_path,
            last_seen_at = excluded.last_seen_at
        """,
        ("alias_" + sha256_hex(path_hash)[:32], project_id, canonical_path, path_hash, ts, ts),
    )
    conn.execute(
        "UPDATE code_index_checkpoints SET project_root = ? WHERE project_id = ?",
        (canonical_path, project_id),
    )
    return project_id


def project_payload(root: Path, project_id: str | None = None) -> dict[str, str]:
    return {"projectID": project_id or project_id_for(root), "projectRoot": str(root), "projectName": root.name}


def normalized_storage_budget_bytes(value: int | None) -> int:
    requested = DEFAULT_PROJECT_STORAGE_BUDGET_BYTES if value is None else int(value)
    return max(1, min(requested, MAX_PROJECT_STORAGE_BUDGET_BYTES))


def _context_token_encoder() -> Any | None:
    global _TOKEN_ENCODER, _TOKEN_ENCODER_LOADED
    if _TOKEN_ENCODER_LOADED:
        return _TOKEN_ENCODER
    _TOKEN_ENCODER_LOADED = True
    try:
        import tiktoken  # type: ignore[import-not-found]

        _TOKEN_ENCODER = tiktoken.get_encoding("cl100k_base")
    except Exception:
        _TOKEN_ENCODER = None
    return _TOKEN_ENCODER


def token_estimator_name() -> str:
    return "tiktoken:cl100k_base" if _context_token_encoder() is not None else "heuristic:v2"


def estimate_context_tokens(text: str) -> int:
    encoder = _context_token_encoder()
    if encoder is not None:
        return max(1, len(encoder.encode(text)))

    words = len(re.findall(r"[A-Za-z0-9_]+", text))
    punctuation = len(re.findall(r"[^\w\s]", text, flags=re.UNICODE))
    whitespace_groups = len(re.findall(r"\s+", text))
    non_ascii_bytes = sum(max(0, len(char.encode("utf-8")) - 1) for char in text if ord(char) >= 128)
    byte_floor = math.ceil(len(text.encode("utf-8")) / 6)
    structured = math.ceil(words * 1.25 + punctuation * 0.5 + whitespace_groups * 0.2 + non_ascii_bytes / 2)
    return max(1, byte_floor, structured)


def _utf8_len(value: str) -> int:
    return len(value.encode("utf-8"))


def estimated_code_storage_byte_count(
    *,
    source_bytes: int,
    chunks: list[tuple[int, int, str]],
    file_path: str,
    project_id: str,
    provider: str = CODE_PROVIDER,
    vector_bytes_per_chunk: int = DETERMINISTIC_FINGERPRINT_DIMENSIONS * 4,
) -> int:
    chunk_text_bytes = sum(_utf8_len(body) for _, _, body in chunks)
    fts_mirror_bytes = sum(
        _utf8_len(body) + _utf8_len(file_path) + _utf8_len(project_id) + _utf8_len(provider) for _, _, body in chunks
    )
    return source_bytes + chunk_text_bytes + fts_mirror_bytes + (len(chunks) * vector_bytes_per_chunk)


def project_code_storage_byte_count(conn: sqlite3.Connection, project_id: str) -> int:
    source_bytes = int(
        conn.execute(
            "SELECT COALESCE(SUM(byte_count), 0) FROM code_artifacts WHERE project_id = ?",
            (project_id,),
        ).fetchone()[0]
    )
    chunk_text_bytes = int(
        conn.execute(
            """
            SELECT COALESCE(SUM(length(CAST(c.text AS BLOB))), 0)
            FROM search_chunks AS c
            JOIN code_artifacts AS a ON a.id = c.sourceID
            WHERE c.sourceKind = ? AND a.project_id = ?
            """,
            (CODE_SOURCE_KIND, project_id),
        ).fetchone()[0]
    )
    fts_metadata_bytes = _utf8_len(project_id) + _utf8_len(CODE_PROVIDER)
    fts_mirror_bytes = int(
        conn.execute(
            """
            SELECT COALESCE(SUM(
                length(CAST(c.text AS BLOB))
                + length(CAST(COALESCE(c.sectionPath, '') AS BLOB))
                + ?
            ), 0)
            FROM search_chunks AS c
            JOIN code_artifacts AS a ON a.id = c.sourceID
            WHERE c.sourceKind = ? AND a.project_id = ?
            """,
            (fts_metadata_bytes, CODE_SOURCE_KIND, project_id),
        ).fetchone()[0]
    )
    vector_bytes = int(
        conn.execute(
            """
            SELECT COALESCE(SUM(length(e.vectorBlob)), 0)
            FROM chunk_embeddings AS e
            JOIN search_chunks AS c ON c.id = e.chunkID
            JOIN code_artifacts AS a ON a.id = c.sourceID
            WHERE c.sourceKind = ? AND a.project_id = ?
            """,
            (CODE_SOURCE_KIND, project_id),
        ).fetchone()[0]
    )
    return source_bytes + chunk_text_bytes + fts_mirror_bytes + vector_bytes


def should_compact_sqlite(*, freelist_count: int, page_count: int, page_size: int) -> bool:
    if freelist_count <= 0 or page_count <= 0 or page_size <= 0:
        return False
    reclaimable_bytes = freelist_count * page_size
    if freelist_count >= 32:
        return True
    if reclaimable_bytes >= 1_048_576:
        return True
    return freelist_count >= 4 and (freelist_count / page_count) >= 0.10


def sqlite_compaction_decision(conn: sqlite3.Connection) -> dict[str, int | bool]:
    page_count = int(conn.execute("PRAGMA page_count").fetchone()[0])
    freelist_count = int(conn.execute("PRAGMA freelist_count").fetchone()[0])
    page_size = int(conn.execute("PRAGMA page_size").fetchone()[0])
    return {
        "shouldCompact": should_compact_sqlite(
            freelist_count=freelist_count,
            page_count=page_count,
            page_size=page_size,
        ),
        "pageCount": page_count,
        "freelistCount": freelist_count,
        "pageSize": page_size,
        "reclaimableBytes": freelist_count * page_size,
    }


def scan_secrets(text: str) -> list[str]:
    if not SECRET_CORPUS_AVAILABLE:
        return [SCANNER_CORPUS_UNAVAILABLE_LABEL]
    labels: list[str] = []
    for view in _secret_scan_views(text):
        matched_explicit_pattern = False
        for label, pattern in SECRET_PATTERNS:
            if pattern.search(view):
                labels.append(label)
                matched_explicit_pattern = True
        if not matched_explicit_pattern:
            labels.extend(_entropy_labels(view))
    return sorted(set(labels))


def redact_for_memory(text: str) -> tuple[str, list[str]]:
    if not SECRET_CORPUS_AVAILABLE:
        return text, [SCANNER_CORPUS_UNAVAILABLE_LABEL]
    labels: list[str] = []
    out = text
    for label, pattern in SECRET_PATTERNS:
        if pattern.search(out):
            labels.append(label)
            out = pattern.sub(f"[REDACTED: {label}]", out)
    for view in _secret_scan_views(text):
        if view == text:
            continue
        matched_explicit_pattern = False
        for label, pattern in SECRET_PATTERNS:
            if pattern.search(view):
                labels.append(label)
                matched_explicit_pattern = True
        if not matched_explicit_pattern:
            labels.extend(_entropy_labels(view))
    return out, sorted(set(labels))


def make_blob_sha(data: bytes) -> str:
    header = f"blob {len(data)}\0".encode()
    return hashlib.sha1(header + data).hexdigest()


def current_commit(root: Path) -> str:
    return _git_output(root, ["rev-parse", "HEAD"])


def ensure_schema(conn: sqlite3.Connection) -> None:
    conn.execute("PRAGMA foreign_keys=ON")
    conn.execute("PRAGMA auto_vacuum=INCREMENTAL")
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS search_documents (
            id TEXT PRIMARY KEY,
            sourceKind TEXT NOT NULL,
            sourceID TEXT NOT NULL,
            sourceVersionID TEXT NOT NULL DEFAULT '',
            provider TEXT,
            projectName TEXT,
            title TEXT NOT NULL,
            subtitle TEXT,
            bodyPreview TEXT,
            sourceUpdatedAt TEXT,
            indexedAt TEXT NOT NULL,
            contentHash TEXT,
            createdAt TEXT NOT NULL,
            updatedAt TEXT NOT NULL
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS search_chunks (
            id TEXT PRIMARY KEY,
            documentID TEXT NOT NULL,
            sourceKind TEXT NOT NULL,
            sourceID TEXT NOT NULL,
            sourceVersionID TEXT NOT NULL DEFAULT '',
            ordinal INTEGER NOT NULL,
            startOffset INTEGER NOT NULL,
            endOffset INTEGER NOT NULL,
            messageStartOffset INTEGER,
            messageEndOffset INTEGER,
            sectionPath TEXT,
            text TEXT NOT NULL,
            contentHash TEXT,
            createdAt TEXT NOT NULL,
            updatedAt TEXT NOT NULL
        )
        """
    )
    if "contentHash" not in table_columns(conn, "search_chunks"):
        conn.execute("ALTER TABLE search_chunks ADD COLUMN contentHash TEXT")
    conn.execute(
        """
        CREATE VIRTUAL TABLE IF NOT EXISTS search_chunks_fts USING fts5(
            chunkID UNINDEXED,
            documentID UNINDEXED,
            title,
            chunkText,
            projectName,
            provider,
            tokenize='porter unicode61'
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS embedding_models (
            id TEXT PRIMARY KEY,
            provider TEXT NOT NULL,
            modelName TEXT NOT NULL,
            dimensions INTEGER NOT NULL,
            distanceMetric TEXT NOT NULL,
            createdAt TEXT NOT NULL,
            updatedAt TEXT NOT NULL
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS embedding_versions (
            id TEXT PRIMARY KEY,
            modelID TEXT NOT NULL,
            versionTag TEXT NOT NULL,
            chunkerVersion TEXT NOT NULL,
            normalizationVersion TEXT NOT NULL,
            promptVersion TEXT NOT NULL,
            isActive INTEGER NOT NULL,
            createdAt TEXT NOT NULL,
            updatedAt TEXT NOT NULL
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS chunk_embeddings (
            chunkID TEXT NOT NULL,
            embeddingVersionID TEXT NOT NULL,
            vectorBlob BLOB NOT NULL,
            createdAt TEXT NOT NULL,
            updatedAt TEXT NOT NULL,
            PRIMARY KEY (chunkID, embeddingVersionID)
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS agent_memories (
            id TEXT PRIMARY KEY,
            project_id TEXT NOT NULL,
            kind TEXT NOT NULL,
            scope TEXT NOT NULL,
            confidence REAL NOT NULL,
            body_ref TEXT NOT NULL,
            body_redacted TEXT NOT NULL,
            tags_json TEXT NOT NULL,
            source_path TEXT,
            valid_from TEXT NOT NULL,
            valid_to TEXT,
            superseded_by TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        )
        """
    )
    conn.execute(
        "CREATE INDEX IF NOT EXISTS agent_memories_project_idx ON agent_memories(project_id, scope, updated_at)"
    )
    # agent_memories_fts was a vestigial body-search index that can never be populated:
    # the redacted-index invariant (test_direct_memory_helpers_keep_plaintext_out_of_agent_index)
    # keeps memory bodies OUT of the agent index entirely — they live only in
    # project_memory_snapshots, which recall scans (bounded by per-project memory count).
    # Drop it rather than ship a dead index that implies FTS coverage it cannot provide.
    conn.execute("DROP TABLE IF EXISTS agent_memories_fts")
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS memory_audit (
            seq INTEGER PRIMARY KEY AUTOINCREMENT,
            ts TEXT NOT NULL,
            actor TEXT NOT NULL,
            action TEXT NOT NULL,
            domain TEXT NOT NULL,
            project_id TEXT,
            subject_id TEXT,
            labels_json TEXT NOT NULL,
            prev_hash TEXT,
            hash TEXT NOT NULL
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS pcm_projects (
            project_id TEXT PRIMARY KEY,
            identity_version INTEGER NOT NULL,
            identity_fingerprint TEXT NOT NULL,
            project_name TEXT NOT NULL,
            primary_path TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        )
        """
    )
    conn.execute("CREATE UNIQUE INDEX IF NOT EXISTS pcm_projects_fingerprint_idx ON pcm_projects(identity_fingerprint)")
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS pcm_project_aliases (
            id TEXT PRIMARY KEY,
            project_id TEXT NOT NULL,
            alias_path TEXT NOT NULL,
            path_hash TEXT NOT NULL,
            first_seen_at TEXT NOT NULL,
            last_seen_at TEXT NOT NULL,
            FOREIGN KEY(project_id) REFERENCES pcm_projects(project_id) ON DELETE CASCADE
        )
        """
    )
    conn.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS pcm_project_aliases_path_hash_idx ON pcm_project_aliases(path_hash)"
    )
    conn.execute("CREATE INDEX IF NOT EXISTS pcm_project_aliases_project_idx ON pcm_project_aliases(project_id)")
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS code_artifacts (
            id TEXT PRIMARY KEY,
            project_id TEXT NOT NULL,
            file_path TEXT NOT NULL,
            blob_sha TEXT NOT NULL,
            content_hash TEXT,
            commit_sha TEXT,
            lang TEXT,
            byte_count INTEGER NOT NULL,
            mtime REAL NOT NULL,
            indexed_at TEXT NOT NULL
        )
        """
    )
    ensure_column(conn, "code_artifacts", "content_hash", "TEXT")
    conn.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS code_artifacts_project_path_idx ON code_artifacts(project_id, file_path)"
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS pcm_file_manifest (
            id TEXT PRIMARY KEY,
            project_id TEXT NOT NULL,
            file_path TEXT NOT NULL,
            artifact_id TEXT,
            blob_sha TEXT,
            content_hash TEXT,
            byte_count INTEGER NOT NULL DEFAULT 0,
            mtime REAL NOT NULL DEFAULT 0,
            lang TEXT,
            ignored_reason TEXT,
            secret_labels_json TEXT NOT NULL DEFAULT '[]',
            parser_tier TEXT,
            indexed_at TEXT NOT NULL,
            last_seen_at TEXT NOT NULL
        )
        """
    )
    conn.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS pcm_file_manifest_project_path_idx ON pcm_file_manifest(project_id, file_path)"
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS code_symbols (
            id TEXT PRIMARY KEY,
            project_id TEXT NOT NULL,
            artifact_id TEXT NOT NULL,
            blob_sha TEXT NOT NULL,
            name TEXT NOT NULL,
            kind TEXT NOT NULL,
            range_json TEXT NOT NULL,
            confidence_tier TEXT NOT NULL,
            tier_evidence_json TEXT,
            indexed_at TEXT NOT NULL
        )
        """
    )
    ensure_column(conn, "code_symbols", "tier_evidence_json", "TEXT")
    conn.execute("CREATE INDEX IF NOT EXISTS code_symbols_project_name_idx ON code_symbols(project_id, name)")
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS code_references (
            id TEXT PRIMARY KEY,
            project_id TEXT NOT NULL,
            from_artifact_id TEXT NOT NULL,
            to_symbol_id TEXT NOT NULL,
            range_json TEXT NOT NULL,
            blob_sha TEXT NOT NULL,
            confidence_tier TEXT NOT NULL,
            indexed_at TEXT NOT NULL
        )
        """
    )
    conn.execute("CREATE INDEX IF NOT EXISTS code_references_symbol_idx ON code_references(project_id, to_symbol_id)")
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS code_call_edges (
            id TEXT PRIMARY KEY,
            project_id TEXT NOT NULL,
            caller_symbol_id TEXT NOT NULL,
            callee_symbol_id TEXT NOT NULL,
            confidence_tier TEXT NOT NULL,
            indexed_at TEXT NOT NULL
        )
        """
    )
    conn.execute(
        "CREATE INDEX IF NOT EXISTS code_call_edges_project_idx ON code_call_edges(project_id, caller_symbol_id)"
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS code_diagnostics_cache (
            id TEXT PRIMARY KEY,
            project_id TEXT NOT NULL,
            file_path TEXT NOT NULL,
            tool TEXT NOT NULL,
            payload_json TEXT NOT NULL,
            blob_sha TEXT,
            cached_at TEXT NOT NULL
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS code_index_checkpoints (
            project_id TEXT PRIMARY KEY,
            project_root TEXT NOT NULL,
            last_commit_sha TEXT,
            indexed_at TEXT NOT NULL,
            artifact_count INTEGER NOT NULL,
            chunk_count INTEGER NOT NULL,
            rejected_count INTEGER NOT NULL,
            storage_byte_count INTEGER NOT NULL DEFAULT 0,
            storage_budget_bytes INTEGER NOT NULL DEFAULT 0,
            vacuumed_at TEXT
        )
        """
    )
    ensure_column(conn, "code_index_checkpoints", "storage_byte_count", "INTEGER NOT NULL DEFAULT 0")
    ensure_column(conn, "code_index_checkpoints", "storage_budget_bytes", "INTEGER NOT NULL DEFAULT 0")
    ensure_column(conn, "code_index_checkpoints", "vacuumed_at", "TEXT")
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS project_memory_snapshots (
            projectSlug TEXT PRIMARY KEY,
            projectDisplayName TEXT NOT NULL,
            snapshotJSON TEXT NOT NULL,
            contentHash TEXT NOT NULL,
            sourceSessionCount INTEGER NOT NULL DEFAULT 0,
            sourceConversationCount INTEGER NOT NULL DEFAULT 0,
            generatedAt TEXT NOT NULL,
            schemaVersion INTEGER NOT NULL,
            updatedAt TEXT NOT NULL
        )
        """
    )
    conn.execute(
        "CREATE INDEX IF NOT EXISTS project_memory_snapshots_updated_idx ON project_memory_snapshots(updatedAt)"
    )
    ensure_embedding_version(conn)
    migrate_legacy_plaintext_agent_memories(conn)


def ensure_embedding_version(conn: sqlite3.Connection) -> str:
    ts = now_iso()
    model_id = "openburnbar-deterministic-fingerprint"
    version_id = "openburnbar-deterministic-fingerprint-v1"
    conn.execute(
        """
        INSERT OR IGNORE INTO embedding_models
            (id, provider, modelName, dimensions, distanceMetric, createdAt, updatedAt)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
        (
            model_id,
            DETERMINISTIC_FINGERPRINT_PROVIDER,
            DETERMINISTIC_FINGERPRINT_MODEL,
            DETERMINISTIC_FINGERPRINT_DIMENSIONS,
            "cosine",
            ts,
            ts,
        ),
    )
    conn.execute(
        """
        INSERT OR IGNORE INTO embedding_versions
            (id, modelID, versionTag, chunkerVersion, normalizationVersion, promptVersion, isActive, createdAt, updatedAt)
        VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?)
        """,
        (
            version_id,
            model_id,
            DETERMINISTIC_FINGERPRINT_VERSION_TAG,
            CHUNKER_VERSION,
            NORMALIZATION_VERSION,
            PROMPT_VERSION,
            ts,
            ts,
        ),
    )
    return version_id


def deterministic_fingerprint_vector(text: str, dimensions: int = DETERMINISTIC_FINGERPRINT_DIMENSIONS) -> list[float]:
    """Stable content fingerprint used for tests/dedupe only.

    This is intentionally not a semantic embedding and must not affect production
    code-search ranking.
    """
    normalized = text.replace("\r\n", "\n").strip().lower()
    split_re = "[" + re.escape(string.whitespace + string.punctuation) + "]+"
    tokens = [token for token in re.split(split_re, normalized) if token]
    source_tokens = tokens if tokens else [normalized]
    vector = [0.0] * max(1, int(dimensions))
    for position, token in enumerate(source_tokens):
        digest = hashlib.sha256(f"{DETERMINISTIC_FINGERPRINT_SEED}|{position}|{token}".encode()).hexdigest()
        byte_values = digest.encode("utf-8")
        weight = 1.0 / float(max(1, position + 1))
        for lane in range(min(16, len(byte_values))):
            value = byte_values[lane]
            index = (int(value) + lane * 131) % len(vector)
            sign = 1.0 if lane % 2 == 0 else -1.0
            magnitude = (float(value % 31) / 30.0) + 0.15
            vector[index] += sign * magnitude * weight
    norm = math.sqrt(sum(value * value for value in vector))
    return [value / norm for value in vector] if norm > 0 and math.isfinite(norm) else vector


# Compatibility alias for old tests/importers. Do not use this for ranking.
deterministic_embedding = deterministic_fingerprint_vector


def vector_blob(vector: list[float]) -> bytes:
    return struct.pack("<" + "f" * len(vector), *vector)


def decode_vector(blob: bytes) -> list[float] | None:
    if not blob or len(blob) % 4 != 0:
        return None
    try:
        return list(struct.unpack("<" + "f" * (len(blob) // 4), blob))
    except struct.error:
        return None


def cosine(lhs: list[float], rhs: list[float]) -> float:
    if len(lhs) != len(rhs):
        return float("-inf")
    denom = math.sqrt(sum(v * v for v in lhs)) * math.sqrt(sum(v * v for v in rhs))
    if denom <= 0:
        return float("-inf")
    return sum(a * b for a, b in zip(lhs, rhs, strict=False)) / denom


def fts_query(query: str) -> str:
    tokens = re.findall(r"[A-Za-z0-9_./:-]{2,}", query.lower())
    if not tokens:
        return ""
    unique = sorted(set(tokens))[:16]
    return " OR ".join(f'"{token.replace(chr(34), chr(34) + chr(34))}"' for token in unique)


def chunk_text(text: str, max_chars: int = 2400, overlap: int = 240) -> list[tuple[int, int, str]]:
    if len(text) <= max_chars:
        return [(0, len(text), text)]
    chunks: list[tuple[int, int, str]] = []
    start = 0
    while start < len(text):
        end = min(len(text), start + max_chars)
        if end < len(text):
            newline = text.rfind("\n", start + max_chars // 2, end)
            if newline > start:
                end = newline + 1
        chunks.append((start, end, text[start:end]))
        if end >= len(text):
            break
        start = max(0, end - overlap)
    return chunks


def _range_offsets(text: str, range_payload: dict[str, Any]) -> tuple[int, int] | None:
    byte_start = range_payload.get("byteStart")
    byte_end = range_payload.get("byteEnd")
    if isinstance(byte_start, int) and isinstance(byte_end, int):
        start = max(0, min(len(text), byte_start))
        end = max(start, min(len(text), byte_end))
        return (start, end) if end > start else None

    start_line = range_payload.get("startLine")
    end_line = range_payload.get("endLine")
    if not isinstance(start_line, int):
        start = range_payload.get("start")
        start_line = start.get("line") if isinstance(start, dict) else None
    if not isinstance(end_line, int):
        end = range_payload.get("end")
        end_line = end.get("line") if isinstance(end, dict) else start_line
    if not isinstance(start_line, int) or not isinstance(end_line, int):
        return None

    starts = line_start_offsets(text)
    start_index = max(0, min(len(starts) - 1, start_line - 1))
    end_index = max(start_index, min(len(starts) - 1, end_line))
    start = starts[start_index]
    end = starts[end_index] if end_index < len(starts) else len(text)
    if end_line >= len(starts):
        end = len(text)
    return (start, end) if end > start else None


def ast_aware_chunks(
    text: str,
    symbols: list[dict[str, Any]],
    max_chars: int = 2400,
    overlap: int = 240,
) -> list[tuple[int, int, str]]:
    symbol_ranges: list[tuple[int, int]] = []
    for symbol in symbols:
        range_payload = symbol.get("range") if isinstance(symbol.get("range"), dict) else {}
        offsets = _range_offsets(text, range_payload)
        if offsets:
            symbol_ranges.append(offsets)
    if not symbol_ranges:
        return chunk_text(text, max_chars=max_chars, overlap=overlap)

    merged: list[tuple[int, int]] = []
    for start, end in sorted(symbol_ranges):
        if not merged or start >= merged[-1][1]:
            merged.append((start, end))
            continue
        prev_start, prev_end = merged[-1]
        merged[-1] = (prev_start, max(prev_end, end))

    chunks: list[tuple[int, int, str]] = []

    def append_window(start: int, end: int) -> None:
        if end <= start:
            return
        body = text[start:end]
        if len(body) <= max_chars:
            chunks.append((start, end, body))
            return
        for rel_start, rel_end, rel_body in chunk_text(body, max_chars=max_chars, overlap=overlap):
            chunks.append((start + rel_start, start + rel_end, rel_body))

    cursor = 0
    for start, end in merged:
        append_window(cursor, start)
        append_window(start, end)
        cursor = max(cursor, end)
    append_window(cursor, len(text))
    return chunks


def audit_event(
    conn: sqlite3.Connection,
    *,
    action: str,
    domain: str,
    project_id: str | None,
    subject_id: str | None,
    labels: list[str] | None = None,
    actor: str = "local-mcp",
) -> None:
    ensure_schema(conn)
    row = conn.execute("SELECT seq, hash FROM memory_audit ORDER BY seq DESC LIMIT 1").fetchone()
    prev_hash = str(row[1]) if row else ""
    seq = int(row[0]) + 1 if row else 1
    ts = now_iso()
    labels_json = json.dumps(sorted(set(labels or [])), separators=(",", ":"))
    core = {
        "schema": "openburnbar.memory_audit.v2",
        "seq": seq,
        "ts": ts,
        "actor": actor,
        "action": action,
        "domain": domain,
        "projectID": project_id,
        "subjectID": subject_id,
        "labels": json.loads(labels_json),
        "prevHash": prev_hash,
    }
    digest = sha256_hex(json.dumps(core, sort_keys=True, separators=(",", ":")))
    conn.execute(
        """
        INSERT INTO memory_audit
            (ts, actor, action, domain, project_id, subject_id, labels_json, prev_hash, hash)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (ts, actor, action, domain, project_id, subject_id, labels_json, prev_hash or None, digest),
    )


AGENT_MEMORY_PAGE_ID = "agent-notes"


def project_memory_slug(project_id: str) -> str:
    return f"agent-{project_id}"


def memory_body_reference(memory_id: str, project_id: str) -> str:
    return f"Project Memory snapshot ref:{project_memory_slug(project_id)}#{memory_id}"


def project_memory_base_snapshot(project_id: str, project_display_name: str, ts: str) -> dict[str, Any]:
    return {
        "projectSlug": project_memory_slug(project_id),
        "projectDisplayName": project_display_name,
        "generatedAt": ts,
        "sourceSessionIDs": [],
        "sourceConversationIDs": [],
        "sourceWindowStart": None,
        "sourceWindowEnd": None,
        "keyFiles": [],
        "keyCommands": [],
        "usageSummary": "Agent-maintained project memory notes.",
        "freshness": "fresh",
        "contentHash": "",
        "schemaVersion": 1,
        "pages": [agent_memory_page([])],
        "visuals": [],
    }


def agent_memory_page(sections: list[dict[str, Any]]) -> dict[str, Any]:
    return {
        "id": AGENT_MEMORY_PAGE_ID,
        "title": "Agent Notes",
        "summary": f"{len(sections)} agent-maintained notes with provenance metadata.",
        "sections": sections,
        "visualIDs": [],
    }


def memory_section_title(kind: str, scope: str, tags: list[str]) -> str:
    base = f"{kind.capitalize()} / {scope}"
    first_tag = next((tag for tag in tags if tag), None)
    return f"{base} / {first_tag}" if first_tag else base


def memory_citations(memory_id: str, source_path: str | None, ts: str) -> list[dict[str, Any]]:
    if not source_path:
        return []
    return [
        {
            "id": f"cite_{sha256_hex(f'{memory_id}:{source_path}'.encode())[:16]}",
            "sourceID": source_path,
            "sourceKind": "code",
            "title": source_path,
            "snippet": "Agent-supplied source path for this memory.",
            "createdAt": ts,
        }
    ]


def load_project_memory_snapshot(
    conn: sqlite3.Connection, project_id: str, project_display_name: str, ts: str
) -> dict[str, Any]:
    row = conn.execute(
        "SELECT snapshotJSON FROM project_memory_snapshots WHERE projectSlug = ? LIMIT 1",
        (project_memory_slug(project_id),),
    ).fetchone()
    if row and row[0]:
        try:
            decoded = json.loads(str(row[0]))
            if isinstance(decoded, dict):
                return decoded
        except json.JSONDecodeError:
            pass
    return project_memory_base_snapshot(project_id, project_display_name, ts)


def write_project_memory_snapshot(
    conn: sqlite3.Connection, project_id: str, project_display_name: str, snapshot: dict[str, Any], ts: str
) -> None:
    updated = dict(snapshot)
    updated["projectSlug"] = project_memory_slug(project_id)
    updated["projectDisplayName"] = str(updated.get("projectDisplayName") or project_display_name)
    updated["schemaVersion"] = 1
    updated["updatedAt"] = ts
    updated.setdefault("generatedAt", ts)
    hash_payload = dict(updated)
    hash_payload["contentHash"] = ""
    content_hash = sha256_hex(json.dumps(hash_payload, sort_keys=True, separators=(",", ":")).encode("utf-8"))
    updated["contentHash"] = content_hash
    snapshot_json = json.dumps(updated, sort_keys=True, separators=(",", ":"))
    source_session_count = len(
        updated.get("sourceSessionIDs") if isinstance(updated.get("sourceSessionIDs"), list) else []
    )
    source_conversation_count = len(
        updated.get("sourceConversationIDs") if isinstance(updated.get("sourceConversationIDs"), list) else []
    )
    conn.execute(
        """
        INSERT INTO project_memory_snapshots
            (projectSlug, projectDisplayName, snapshotJSON, contentHash, sourceSessionCount, sourceConversationCount, generatedAt, schemaVersion, updatedAt)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(projectSlug) DO UPDATE SET
            projectDisplayName = excluded.projectDisplayName,
            snapshotJSON = excluded.snapshotJSON,
            contentHash = excluded.contentHash,
            sourceSessionCount = excluded.sourceSessionCount,
            sourceConversationCount = excluded.sourceConversationCount,
            generatedAt = excluded.generatedAt,
            schemaVersion = excluded.schemaVersion,
            updatedAt = excluded.updatedAt
        """,
        (
            project_memory_slug(project_id),
            updated["projectDisplayName"],
            snapshot_json,
            content_hash,
            source_session_count,
            source_conversation_count,
            str(updated.get("generatedAt") or ts),
            1,
            ts,
        ),
    )


def upsert_project_memory_section(
    conn: sqlite3.Connection,
    *,
    project_id: str,
    project_display_name: str,
    memory_id: str,
    body: str,
    kind: str,
    scope: str,
    tags: list[str],
    source_path: str | None,
    ts: str,
) -> None:
    snapshot = load_project_memory_snapshot(conn, project_id, project_display_name, ts)
    pages = snapshot.get("pages") if isinstance(snapshot.get("pages"), list) else []
    section = {
        "id": memory_id,
        "title": memory_section_title(kind, scope, tags),
        "body": body,
        "citations": memory_citations(memory_id, source_path, ts),
    }
    for page in pages:
        if isinstance(page, dict) and page.get("id") == AGENT_MEMORY_PAGE_ID:
            sections = page.get("sections") if isinstance(page.get("sections"), list) else []
            sections = [item for item in sections if not (isinstance(item, dict) and item.get("id") == memory_id)]
            sections.append(section)
            sections.sort(key=lambda item: str(item.get("id") if isinstance(item, dict) else ""))
            page["sections"] = sections
            page["summary"] = f"{len(sections)} agent-maintained notes with provenance metadata."
            break
    else:
        pages.append(agent_memory_page([section]))
    snapshot["pages"] = pages
    if source_path:
        key_files = snapshot.get("keyFiles") if isinstance(snapshot.get("keyFiles"), list) else []
        if source_path not in key_files:
            key_files.append(source_path)
        snapshot["keyFiles"] = key_files[:24]
    write_project_memory_snapshot(conn, project_id, project_display_name, snapshot, ts)


def remove_project_memory_section(
    conn: sqlite3.Connection, *, project_id: str, project_display_name: str, memory_id: str, ts: str
) -> None:
    snapshot = load_project_memory_snapshot(conn, project_id, project_display_name, ts)
    pages = snapshot.get("pages") if isinstance(snapshot.get("pages"), list) else []
    changed = False
    for page in pages:
        if not isinstance(page, dict) or page.get("id") != AGENT_MEMORY_PAGE_ID:
            continue
        sections = page.get("sections") if isinstance(page.get("sections"), list) else []
        filtered = [item for item in sections if not (isinstance(item, dict) and item.get("id") == memory_id)]
        changed = changed or len(filtered) != len(sections)
        page["sections"] = filtered
        page["summary"] = f"{len(filtered)} agent-maintained notes with provenance metadata."
    if changed:
        snapshot["pages"] = pages
        write_project_memory_snapshot(conn, project_id, project_display_name, snapshot, ts)


def project_memory_section_body(conn: sqlite3.Connection, project_id: str, memory_id: str) -> str | None:
    row = conn.execute(
        "SELECT snapshotJSON FROM project_memory_snapshots WHERE projectSlug = ? LIMIT 1",
        (project_memory_slug(project_id),),
    ).fetchone()
    if not row or not row[0]:
        return None
    try:
        snapshot = json.loads(str(row[0]))
    except json.JSONDecodeError:
        return None
    pages = snapshot.get("pages") if isinstance(snapshot, dict) else None
    if not isinstance(pages, list):
        return None
    for page in pages:
        sections = page.get("sections") if isinstance(page, dict) else None
        if not isinstance(sections, list):
            continue
        for section in sections:
            if isinstance(section, dict) and section.get("id") == memory_id and isinstance(section.get("body"), str):
                return section["body"]
    return None


def migrate_legacy_plaintext_agent_memories(conn: sqlite3.Connection) -> None:
    rows = conn.execute(
        """
        SELECT id, project_id, kind, scope, body_redacted, tags_json, source_path, updated_at
        FROM agent_memories
        WHERE body_redacted NOT LIKE 'Project Memory snapshot ref:%'
        """
    ).fetchall()
    for row in rows:
        memory_id = str(row[0])
        project_id = str(row[1])
        tags = json.loads(row[5] or "[]")
        ts = str(row[7] or now_iso())
        upsert_project_memory_section(
            conn,
            project_id=project_id,
            project_display_name=project_id,
            memory_id=memory_id,
            body=str(row[4]),
            kind=str(row[2]),
            scope=str(row[3]),
            tags=tags if isinstance(tags, list) else [],
            source_path=row[6],
            ts=ts,
        )
        conn.execute(
            "UPDATE agent_memories SET body_redacted = ?, updated_at = ? WHERE id = ?",
            (memory_body_reference(memory_id, project_id), ts, memory_id),
        )


def call_daemon(method: str, params: dict[str, Any], timeout_seconds: float = 1.5) -> dict[str, Any]:
    socket_path = _default_socket_path()
    if not socket_path.exists():
        raise RuntimeError(f"daemon socket not reachable at {socket_path}")
    request: dict[str, Any] = {"id": str(uuid.uuid4()), "method": method, "params": params}
    token = _resolve_socket_auth_token()
    if token:
        request["authToken"] = token
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.settimeout(timeout_seconds)
        sock.connect(str(socket_path))
        sock.sendall((json.dumps(request) + "\n").encode("utf-8"))
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = sock.recv(8192)
            if not chunk:
                break
            buf += chunk
    if not buf:
        raise RuntimeError("daemon returned an empty response")
    envelope = json.loads(buf.decode("utf-8").rstrip("\n"))
    if envelope.get("error"):
        err = envelope["error"]
        raise RuntimeError(f"daemon rejected {method}: code={err.get('code')} message={err.get('message')!r}")
    result = envelope.get("result")
    if not isinstance(result, dict):
        raise RuntimeError(f"daemon returned invalid {method} result")
    return result


def write_authority(method: str, params: dict[str, Any]) -> dict[str, Any]:
    try:
        return {"mode": "daemon", "result": call_daemon(method, params)}
    except Exception as exc:
        if str(exc).startswith("daemon rejected"):
            return {
                "status": "denied",
                "code": "DAEMON_WRITE_REJECTED",
                "method": method,
                "reason": str(exc),
            }
        return {
            "status": "denied",
            "code": "DAEMON_WRITE_REQUIRED",
            "method": method,
            "reason": str(exc),
        }


def insert_fts(
    conn: sqlite3.Connection, chunk_id: str, document_id: str, title: str, text: str, project_name: str, provider: str
) -> None:
    cols = table_columns(conn, "search_chunks_fts")
    if "provider" in cols:
        conn.execute(
            """
            INSERT INTO search_chunks_fts (chunkID, documentID, title, chunkText, projectName, provider)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            (chunk_id, document_id, title, text, project_name, provider),
        )
    else:
        conn.execute(
            """
            INSERT INTO search_chunks_fts (chunkID, documentID, title, chunkText, projectName)
            VALUES (?, ?, ?, ?, ?)
            """,
            (chunk_id, document_id, title, text, project_name),
        )


def delete_search_document(conn: sqlite3.Connection, document_id: str) -> None:
    conn.execute("DELETE FROM search_chunks_fts WHERE documentID = ?", (document_id,))
    chunk_ids = [
        str(row[0]) for row in conn.execute("SELECT id FROM search_chunks WHERE documentID = ?", (document_id,))
    ]
    if chunk_ids:
        conn.executemany("DELETE FROM chunk_embeddings WHERE chunkID = ?", [(chunk_id,) for chunk_id in chunk_ids])
    conn.execute("DELETE FROM search_chunks WHERE documentID = ?", (document_id,))
    conn.execute("DELETE FROM search_documents WHERE id = ?", (document_id,))


def delete_code_artifact(conn: sqlite3.Connection, artifact_id: str) -> None:
    doc_ids = {
        str(row[0])
        for row in conn.execute(
            "SELECT id FROM search_documents WHERE sourceKind = ? AND sourceID = ?",
            (CODE_SOURCE_KIND, artifact_id),
        ).fetchall()
    }
    doc_ids.update(
        str(row[0])
        for row in conn.execute(
            "SELECT DISTINCT documentID FROM search_chunks WHERE sourceKind = ? AND sourceID = ?",
            (CODE_SOURCE_KIND, artifact_id),
        ).fetchall()
    )
    for doc_id in doc_ids:
        delete_search_document(conn, doc_id)
    conn.execute(
        """
        DELETE FROM code_call_edges
        WHERE caller_symbol_id IN (SELECT id FROM code_symbols WHERE artifact_id = ?)
           OR callee_symbol_id IN (SELECT id FROM code_symbols WHERE artifact_id = ?)
        """,
        (artifact_id, artifact_id),
    )
    conn.execute(
        """
        DELETE FROM code_references
        WHERE from_artifact_id = ?
           OR to_symbol_id IN (SELECT id FROM code_symbols WHERE artifact_id = ?)
        """,
        (artifact_id, artifact_id),
    )
    conn.execute("DELETE FROM code_symbols WHERE artifact_id = ?", (artifact_id,))
    conn.execute(
        "DELETE FROM code_diagnostics_cache WHERE blob_sha IN (SELECT blob_sha FROM code_artifacts WHERE id = ?)",
        (artifact_id,),
    )
    conn.execute("DELETE FROM code_artifacts WHERE id = ?", (artifact_id,))


def upsert_file_manifest(
    conn: sqlite3.Connection,
    *,
    project_id: str,
    file_path: str,
    artifact_id: str | None,
    blob_sha: str | None,
    content_hash: str | None,
    byte_count: int,
    mtime: float,
    lang: str | None,
    ignored_reason: str | None,
    secret_labels: list[str],
    parser_tier: str | None,
    ts: str,
) -> None:
    manifest_id = "manifest_" + sha256_hex(f"{project_id}:{file_path}".encode())[:32]
    labels_json = json.dumps(sorted(set(secret_labels)), separators=(",", ":"))
    conn.execute(
        """
        INSERT INTO pcm_file_manifest
            (id, project_id, file_path, artifact_id, blob_sha, content_hash, byte_count, mtime,
             lang, ignored_reason, secret_labels_json, parser_tier, indexed_at, last_seen_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(project_id, file_path) DO UPDATE SET
            artifact_id = excluded.artifact_id,
            blob_sha = excluded.blob_sha,
            content_hash = excluded.content_hash,
            byte_count = excluded.byte_count,
            mtime = excluded.mtime,
            lang = excluded.lang,
            ignored_reason = excluded.ignored_reason,
            secret_labels_json = excluded.secret_labels_json,
            parser_tier = excluded.parser_tier,
            indexed_at = excluded.indexed_at,
            last_seen_at = excluded.last_seen_at
        """,
        (
            manifest_id,
            project_id,
            file_path,
            artifact_id,
            blob_sha,
            content_hash,
            byte_count,
            mtime,
            lang,
            ignored_reason,
            labels_json,
            parser_tier,
            ts,
            ts,
        ),
    )


def active_embedding_version(conn: sqlite3.Connection) -> str:
    ensure_schema(conn)
    row = conn.execute(
        """
        SELECT v.id
        FROM embedding_versions AS v
        JOIN embedding_models AS m ON m.id = v.modelID
        WHERE v.isActive = 1
          AND m.provider = ?
          AND m.modelName = ?
          AND m.dimensions = ?
          AND v.versionTag = ?
          AND v.chunkerVersion = ?
          AND v.normalizationVersion = ?
          AND v.promptVersion = ?
        ORDER BY v.updatedAt DESC
        LIMIT 1
        """,
        (
            DETERMINISTIC_FINGERPRINT_PROVIDER,
            DETERMINISTIC_FINGERPRINT_MODEL,
            DETERMINISTIC_FINGERPRINT_DIMENSIONS,
            DETERMINISTIC_FINGERPRINT_VERSION_TAG,
            CHUNKER_VERSION,
            NORMALIZATION_VERSION,
            PROMPT_VERSION,
        ),
    ).fetchone()
    return str(row[0]) if row else ensure_embedding_version(conn)


def remember(
    conn: sqlite3.Connection,
    text: str,
    project_path: str | None,
    kind: str,
    scope: str,
    tags: list[str],
    confidence: float,
    source_path: str | None,
) -> dict[str, Any]:
    ensure_schema(conn)
    root = project_root(project_path)
    project_id = resolve_project_id(conn, root)
    cleaned, labels = redact_for_memory(text.strip())
    if not cleaned:
        return {"status": "unavailable", "code": "EMPTY_MEMORY", "reason": "memory text is empty"}
    if labels:
        audit_event(
            conn,
            action="memory.secret_rejected",
            domain="memory",
            project_id=project_id,
            subject_id=None,
            labels=labels,
        )
        return {"status": "rejected", "code": "SECRET_DETECTED", "labels": labels, **project_payload(root, project_id)}
    ts = now_iso()
    body_ref = sha256_hex(cleaned)
    memory_id = f"mem_{sha256_hex((project_id + body_ref).encode('utf-8'))[:32]}"
    tags_json = json.dumps(sorted(set(tags)), separators=(",", ":"))
    upsert_project_memory_section(
        conn,
        project_id=project_id,
        project_display_name=root.name,
        memory_id=memory_id,
        body=cleaned,
        kind=kind,
        scope=scope,
        tags=json.loads(tags_json),
        source_path=source_path,
        ts=ts,
    )
    conn.execute(
        """
        INSERT INTO agent_memories
            (id, project_id, kind, scope, confidence, body_ref, body_redacted, tags_json, source_path, valid_from, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            kind = excluded.kind,
            scope = excluded.scope,
            confidence = excluded.confidence,
            body_redacted = excluded.body_redacted,
            tags_json = excluded.tags_json,
            source_path = excluded.source_path,
            updated_at = excluded.updated_at
        """,
        (
            memory_id,
            project_id,
            kind,
            scope,
            float(confidence),
            body_ref,
            memory_body_reference(memory_id, project_id),
            tags_json,
            source_path,
            ts,
            ts,
            ts,
        ),
    )
    audit_event(conn, action="memory.remember", domain="memory", project_id=project_id, subject_id=memory_id, labels=[])
    return {
        "status": "ok",
        "memoryID": memory_id,
        "storageMode": "project_memory_snapshot_ref",
        **project_payload(root, project_id),
    }


def recall(
    conn: sqlite3.Connection,
    query: str,
    project_path: str | None,
    limit: int,
    scope: str = "all",
    include_cross_project: bool = False,
) -> dict[str, Any]:
    ensure_schema(conn)
    root = project_root(project_path)
    project_id = resolve_project_id(conn, root)
    tokens = [token for token in re.split(r"[^a-zA-Z0-9_]+", query.lower()) if token]
    if not tokens and not query.strip():
        return {"status": "unavailable", "code": "EMPTY_QUERY", "reason": "query produced no searchable tokens"}
    lim = max(1, min(int(limit), 50))
    # Recall scans the per-project index then resolves bodies from the snapshot. The
    # body is deliberately not indexed (redacted-index invariant: bodies live only in
    # project_memory_snapshots), so ranking is a token-overlap over the resolved body;
    # per-project memory counts are small enough that the bounded scan is correct here.
    if include_cross_project and scope == "all":
        rows = conn.execute(
            """
            SELECT
                m.id, m.project_id, m.kind, m.scope, m.confidence, m.body_redacted,
                m.tags_json, m.source_path, m.valid_from, m.updated_at
            FROM agent_memories AS m
            ORDER BY m.updated_at DESC
            LIMIT 1000
            """
        ).fetchall()
    elif include_cross_project:
        rows = conn.execute(
            """
            SELECT
                m.id, m.project_id, m.kind, m.scope, m.confidence, m.body_redacted,
                m.tags_json, m.source_path, m.valid_from, m.updated_at
            FROM agent_memories AS m
            WHERE m.scope = ?
            ORDER BY m.updated_at DESC
            LIMIT 1000
            """,
            [scope],
        ).fetchall()
    elif scope == "all":
        rows = conn.execute(
            """
            SELECT
                m.id, m.project_id, m.kind, m.scope, m.confidence, m.body_redacted,
                m.tags_json, m.source_path, m.valid_from, m.updated_at
            FROM agent_memories AS m
            WHERE m.project_id = ?
            ORDER BY m.updated_at DESC
            LIMIT 1000
            """,
            [project_id],
        ).fetchall()
    else:
        rows = conn.execute(
            """
            SELECT
                m.id, m.project_id, m.kind, m.scope, m.confidence, m.body_redacted,
                m.tags_json, m.source_path, m.valid_from, m.updated_at
            FROM agent_memories AS m
            WHERE m.project_id = ? AND m.scope = ?
            ORDER BY m.updated_at DESC
            LIMIT 1000
            """,
            [project_id, scope],
        ).fetchall()
    results = []
    for row in rows:
        body = project_memory_section_body(conn, str(row[1]), str(row[0]))
        if body is None:
            continue
        tags = json.loads(row[6] or "[]")
        searchable = " ".join([body, " ".join(tags if isinstance(tags, list) else []), str(row[7] or "")]).lower()
        needles = tokens or [query.lower()]
        matches = sum(1 for token in needles if token and token in searchable)
        if matches <= 0:
            continue
        snippet = body[:240]
        for token in needles:
            idx = body.lower().find(token)
            if idx >= 0:
                snippet = ("..." if idx > 80 else "") + body[max(0, idx - 80) : min(len(body), idx + 160)]
                if idx + 160 < len(body):
                    snippet += "..."
                break
        results.append(
            {
                "memoryID": row[0],
                "projectID": row[1],
                "kind": row[2],
                "scope": row[3],
                "confidence": row[4],
                "snippet": snippet,
                "body": body,
                "tags": tags if isinstance(tags, list) else [],
                "sourcePath": row[7],
                "validFrom": row[8],
                "updatedAt": row[9],
                "rank": len(needles) - matches,
            }
        )
    results.sort(key=lambda item: (int(item.get("rank") or 0), str(item.get("updatedAt") or "")))
    results = results[:lim]
    return {
        "status": "ok",
        "query": query,
        "results": results,
        "crossProject": include_cross_project,
        **project_payload(root, project_id),
    }


def forget(conn: sqlite3.Connection, memory_id: str, project_path: str | None) -> dict[str, Any]:
    ensure_schema(conn)
    root = project_root(project_path)
    project_id = resolve_project_id(conn, root)
    row = conn.execute(
        "SELECT id FROM agent_memories WHERE id = ? AND project_id = ?", (memory_id, project_id)
    ).fetchone()
    if row is None:
        return {"status": "not_found", "memoryID": memory_id, **project_payload(root, project_id)}
    remove_project_memory_section(
        conn, project_id=project_id, project_display_name=root.name, memory_id=memory_id, ts=now_iso()
    )
    conn.execute("DELETE FROM agent_memories WHERE id = ?", (memory_id,))
    audit_event(
        conn,
        action="memory.forget",
        domain="memory",
        project_id=project_id,
        subject_id=memory_id,
        labels=["local hard delete"],
    )
    # Local row deleted + snapshot section removed; the snapshot is the only cloud
    # presence (synced as a sealed blob), so its removal is the cross-tier reconciliation.
    return {
        "status": "ok",
        "memoryID": memory_id,
        "cloudDelete": "local_and_snapshot_reconciled",
        **project_payload(root),
    }


def audit_trail(conn: sqlite3.Connection, project_path: str | None, limit: int) -> dict[str, Any]:
    ensure_schema(conn)
    root = project_root(project_path)
    project_id = resolve_project_id(conn, root)
    rows = conn.execute(
        """
        SELECT seq, ts, actor, action, domain, project_id, subject_id, labels_json, prev_hash, hash
        FROM memory_audit
        WHERE project_id = ? OR project_id IS NULL
        ORDER BY seq DESC
        LIMIT ?
        """,
        (project_id, max(1, min(int(limit), 200))),
    ).fetchall()
    events = [
        {
            "seq": row[0],
            "ts": row[1],
            "actor": row[2],
            "action": row[3],
            "domain": row[4],
            "projectID": row[5],
            "subjectID": row[6],
            "labels": json.loads(row[7] or "[]"),
            "prevHash": row[8],
            "hash": row[9],
        }
        for row in rows
    ]
    return {"status": "ok", "events": events, **project_payload(root, project_id)}


def memory_analytics(conn: sqlite3.Connection, project_path: str | None) -> dict[str, Any]:
    ensure_schema(conn)
    root = project_root(project_path)
    project_id = resolve_project_id(conn, root)
    by_kind = {
        str(row[0]): int(row[1])
        for row in conn.execute(
            "SELECT kind, COUNT(*) FROM agent_memories WHERE project_id = ? GROUP BY kind", (project_id,)
        )
    }
    by_scope = {
        str(row[0]): int(row[1])
        for row in conn.execute(
            "SELECT scope, COUNT(*) FROM agent_memories WHERE project_id = ? GROUP BY scope", (project_id,)
        )
    }
    total = sum(by_kind.values())
    return {"status": "ok", "total": total, "byKind": by_kind, "byScope": by_scope, **project_payload(root, project_id)}


def gitignore_patterns(root: Path) -> list[str]:
    path = root / ".gitignore"
    if not path.is_file():
        return []
    patterns: list[str] = []
    try:
        for line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
            stripped = line.strip()
            if stripped and not stripped.startswith("#") and not stripped.startswith("!"):
                patterns.append(stripped)
    except OSError:
        return []
    return patterns


def ignored(rel: str, is_dir: bool, patterns: list[str]) -> bool:
    parts = Path(rel).parts
    if any(part in DEFAULT_EXCLUDED_DIRS for part in parts):
        return True
    if any(part.startswith(".") and part not in {".github"} for part in parts):
        return True
    for pattern in patterns:
        p = pattern.strip("/")
        if not p:
            continue
        if (
            pattern.endswith("/")
            and is_dir
            and (fnmatch.fnmatch(rel, p) or any(fnmatch.fnmatch(part, p) for part in parts))
        ):
            return True
        if fnmatch.fnmatch(rel, p) or fnmatch.fnmatch(Path(rel).name, p) or fnmatch.fnmatch(rel, f"*/{p}"):
            return True
    return False


def git_ignored_paths(root: Path) -> set[str]:
    if not (root / ".git").exists():
        return set()
    try:
        result = subprocess.run(
            ["git", "-C", str(root), "status", "--ignored", "--porcelain=v1", "-z", "--untracked-files=all"],
            capture_output=True,
            check=False,
            timeout=5,
        )
    except (OSError, subprocess.SubprocessError):
        return set()
    if result.returncode != 0:
        return set()
    ignored_paths: set[str] = set()
    for raw in result.stdout.split(b"\0"):
        if not raw.startswith(b"!! "):
            continue
        rel = raw[3:].decode("utf-8", errors="ignore").strip("/")
        if rel:
            ignored_paths.add(rel)
    return ignored_paths


def git_ignored(rel: str, is_dir: bool, ignored_paths: set[str]) -> bool:
    if not ignored_paths:
        return False
    normalized = rel.strip("/")
    if normalized in ignored_paths or (is_dir and f"{normalized}/" in ignored_paths):
        return True
    cursor = normalized
    while "/" in cursor:
        cursor = cursor.rsplit("/", 1)[0]
        if cursor in ignored_paths or f"{cursor}/" in ignored_paths:
            return True
    return False


def language_for(path: Path) -> str:
    ext = path.suffix.lower()
    return {
        ".swift": "swift",
        ".ts": "typescript",
        ".tsx": "tsx",
        ".js": "javascript",
        ".jsx": "javascript",
        ".py": "python",
        ".rs": "rust",
        ".kt": "kotlin",
        ".kts": "kotlin",
        ".java": "java",
        ".go": "go",
        ".rb": "ruby",
        ".sh": "shell",
    }.get(ext, ext.lstrip(".") or "text")


def iter_project_files(root: Path, max_files: int, max_file_bytes: int) -> list[Path]:
    patterns = gitignore_patterns(root)
    git_ignored_set = git_ignored_paths(root)
    use_git_ignore = (root / ".git").exists()
    files: list[Path] = []
    for dirpath, dirnames, filenames in os.walk(root):
        current = Path(dirpath)
        rel_dir = str(current.relative_to(root)) if current != root else ""
        dirnames[:] = [
            name
            for name in dirnames
            if not git_ignored(str(Path(rel_dir) / name) if rel_dir else name, True, git_ignored_set)
            and not (not use_git_ignore and ignored(str(Path(rel_dir) / name) if rel_dir else name, True, patterns))
        ]
        for name in filenames:
            path = current / name
            try:
                resolved = path.resolve()
                rel = str(resolved.relative_to(root))
            except (OSError, ValueError):
                continue
            if git_ignored(rel, False, git_ignored_set) or (not use_git_ignore and ignored(rel, False, patterns)):
                continue
            if path.suffix.lower() not in CODE_EXTENSIONS:
                continue
            try:
                stat = path.stat()
            except OSError:
                continue
            if stat.st_size <= 0:
                continue
            files.append(path)
            if len(files) >= max_files:
                return files
    return files


SYMBOL_PATTERNS: dict[str, re.Pattern[str]] = {
    "swift": re.compile(
        r"(?m)^\s*(?:public|private|internal|fileprivate|open|static|\s)*\b(class|struct|enum|protocol|actor|func|var|let)\s+([A-Za-z_][A-Za-z0-9_]*)"
    ),
    "typescript": re.compile(
        r"(?m)^\s*(?:export\s+)?(?:async\s+)?(?:function|class|interface|type|const|let|var)\s+([A-Za-z_][A-Za-z0-9_]*)"
    ),
    "tsx": re.compile(
        r"(?m)^\s*(?:export\s+)?(?:async\s+)?(?:function|class|interface|type|const|let|var)\s+([A-Za-z_][A-Za-z0-9_]*)"
    ),
    "javascript": re.compile(
        r"(?m)^\s*(?:export\s+)?(?:async\s+)?(?:function|class|const|let|var)\s+([A-Za-z_][A-Za-z0-9_]*)"
    ),
    "python": re.compile(r"(?m)^\s*(class|def)\s+([A-Za-z_][A-Za-z0-9_]*)"),
    "rust": re.compile(r"(?m)^\s*(?:pub\s+)?(?:fn|struct|enum|trait|impl)\s+([A-Za-z_][A-Za-z0-9_]*)"),
    "kotlin": re.compile(
        r"(?m)^\s*(?:public|private|internal|protected|data|sealed|open|\s)*\b(class|interface|object|fun|val|var)\s+([A-Za-z_][A-Za-z0-9_]*)"
    ),
    "java": re.compile(
        r"(?m)^\s*(?:public|private|protected|static|final|\s)*\b(class|interface|enum|void|[A-Za-z_][A-Za-z0-9_<>, ?]*)\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?:\(|\{)"
    ),
    "go": re.compile(r"(?m)^\s*(?:func|type)\s+(?:\([^)]+\)\s*)?([A-Za-z_][A-Za-z0-9_]*)"),
}


def static_parser_path() -> str | None:
    candidates: list[str] = []
    configured = os.environ.get("OPENBURNBAR_CODE_STATIC_PARSER_PATH")
    if configured:
        candidates.append(configured)
    root = Path.cwd()
    candidates.extend(
        [
            str(root / "crates/project-code-static-parser/target/release/project-code-static-parser"),
            str(root / "crates/project-code-static-parser/target/debug/project-code-static-parser"),
            str(root.parent / "crates/project-code-static-parser/target/release/project-code-static-parser"),
            str(root.parent / "crates/project-code-static-parser/target/debug/project-code-static-parser"),
        ]
    )
    return next((candidate for candidate in candidates if os.access(candidate, os.X_OK)), None)


def code_helper_timeout_seconds() -> float:
    raw = (
        os.environ.get("OPENBURNBAR_CODE_HELPER_TIMEOUT_MS")
        or os.environ.get("OPENBURNBAR_CODE_LSP_TIMEOUT_MS")
        or "5000"
    )
    try:
        milliseconds = int(raw)
    except ValueError:
        milliseconds = 5000
    return float(max(250, min(milliseconds, 30_000))) / 1000.0


def code_helper_max_output_bytes() -> int:
    raw = (
        os.environ.get("OPENBURNBAR_CODE_HELPER_MAX_OUTPUT_BYTES")
        or os.environ.get("OPENBURNBAR_CODE_LSP_MAX_RESPONSE_BYTES")
        or "2097152"
    )
    try:
        value = int(raw)
    except ValueError:
        value = 2 * 1024 * 1024
    return max(16 * 1024, min(value, 8 * 1024 * 1024))


def tier_evidence_json(evidence: dict[str, Any]) -> str:
    return json.dumps(evidence, sort_keys=True, separators=(",", ":"))


def decode_tier_evidence(raw: Any) -> dict[str, Any] | None:
    if not raw:
        return None
    try:
        decoded = json.loads(str(raw))
    except json.JSONDecodeError:
        return None
    return decoded if isinstance(decoded, dict) else None


def lexical_tier_evidence_json(lang: str, blob_sha: str) -> str:
    return tier_evidence_json(
        {
            "parser": "regex",
            "language": lang or None,
            "blobSHA": blob_sha,
            # Lexical fallback performs no parse and verifies no blob hash, so it must
            # not claim a SHA match — that would falsely elevate confidence in the
            # evidence. Only the tree-sitter / LSP tiers can earn shaMatch=True.
            "shaMatch": False,
            "lspResponded": False,
            "details": {"fallback": "static parser unavailable or unsupported"},
        }
    )


def static_tree_sitter_symbols(
    text: str,
    lang: str,
    rel: str,
    project_id: str,
    artifact_id: str,
    blob_sha: str,
    root: Path | None = None,
) -> list[dict[str, Any]] | None:
    if lang not in {"swift", "typescript", "tsx", "python"}:
        return None
    helper = static_parser_path()
    if not helper:
        return None
    payload = json.dumps(
        {
            "requestId": artifact_id,
            "filePath": rel,
            "language": lang,
            "blobSha": blob_sha,
            "text": text,
            "rootPath": str(root) if root else None,
            "operation": "symbols",
        },
        separators=(",", ":"),
    )
    try:
        completed = subprocess.run(
            [helper],
            input=payload + "\n",
            capture_output=True,
            text=True,
            check=False,
            timeout=code_helper_timeout_seconds(),
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if completed.returncode != 0:
        return None
    if len(completed.stdout.encode("utf-8", errors="ignore")) > code_helper_max_output_bytes():
        return None
    first_line = next((line for line in completed.stdout.splitlines() if line.strip()), "")
    try:
        response = json.loads(first_line)
    except json.JSONDecodeError:
        return None
    if (
        not response.get("ok")
        or response.get("blobSha") != blob_sha
        or response.get("filePath") != rel
        or response.get("errors")
    ):
        return None
    symbols: list[dict[str, Any]] = []
    starts = line_start_offsets(text)
    for symbol in response.get("symbols") or []:
        if not isinstance(symbol, dict) or not symbol.get("name"):
            continue
        start_line = max(1, int(symbol.get("startLine") or 1))
        end_line = max(start_line, int(symbol.get("endLine") or start_line))
        byte_start = starts[start_line - 1] if start_line - 1 < len(starts) else 0
        byte_end = starts[end_line] - 1 if end_line < len(starts) else len(text)
        name = str(symbol["name"])
        evidence = symbol.get("evidence") if isinstance(symbol.get("evidence"), dict) else {}
        symbols.append(
            {
                "id": f"sym_{sha256_hex(f'{project_id}:{artifact_id}:{name}:{start_line}'.encode())[:32]}",
                "project_id": project_id,
                "artifact_id": artifact_id,
                "blob_sha": blob_sha,
                "name": name,
                "kind": str(symbol.get("kind") or "symbol"),
                "range": {
                    "start": line_col(text, byte_start),
                    "end": line_col(text, byte_end),
                    "byteStart": byte_start,
                    "byteEnd": byte_end,
                    "filePath": rel,
                    "startLine": start_line,
                    "endLine": end_line,
                },
                "confidence_tier": str(symbol.get("confidenceTier") or "static_tree_sitter"),
                "tier_evidence_json": tier_evidence_json(
                    {
                        "parser": evidence.get("parser") or "tree-sitter",
                        "language": evidence.get("language") or response.get("language") or lang,
                        "blobSHA": evidence.get("blobSha") or response.get("blobSha") or blob_sha,
                        # Default False: a tier is only claimed when earned. A missing
                        # shaMatch key (malformed helper response, future parser variant)
                        # must never silently elevate to "verified" — only an explicit
                        # True from the helper counts.
                        "shaMatch": bool(evidence.get("shaMatch", False)),
                        "lspResponded": bool(evidence.get("lspResponded", False)),
                        "details": {
                            "helper": "project-code-static-parser",
                            "operation": "documentSymbol" if evidence.get("parser") == "lsp" else "tree-sitter",
                            "parseError": "true" if response.get("hasParseError") else "false",
                        },
                    }
                ),
            }
        )
    return symbols


def line_col(text: str, offset: int) -> dict[str, int]:
    prefix = text[:offset]
    line = prefix.count("\n") + 1
    last = prefix.rfind("\n")
    col = offset + 1 if last < 0 else offset - last
    return {"line": line, "column": col}


def line_start_offsets(text: str) -> list[int]:
    offsets = [0]
    for match in re.finditer("\n", text):
        offsets.append(match.end())
    return offsets


def extract_symbols(
    text: str, lang: str, rel: str, project_id: str, artifact_id: str, blob_sha: str, root: Path | None = None
) -> list[dict[str, Any]]:
    static_symbols = static_tree_sitter_symbols(text, lang, rel, project_id, artifact_id, blob_sha, root=root)
    if static_symbols:
        return static_symbols
    pattern = SYMBOL_PATTERNS.get(lang)
    if pattern is None:
        return []
    symbols: list[dict[str, Any]] = []
    matches = list(pattern.finditer(text))
    for idx, match in enumerate(matches):
        if lang in {"typescript", "tsx", "javascript", "rust", "go"}:
            kind = "symbol"
            name = match.group(1)
        else:
            kind = match.group(1)
            name = match.group(2)
        start = match.start()
        end = matches[idx + 1].start() if idx + 1 < len(matches) else len(text)
        if end <= start:
            end = match.end()
        range_json = {
            "start": line_col(text, start),
            "end": line_col(text, end),
            "byteStart": start,
            "byteEnd": end,
            "filePath": rel,
            "startLine": line_col(text, start)["line"],
            "endLine": line_col(text, end)["line"],
        }
        symbols.append(
            {
                "id": f"sym_{sha256_hex(f'{project_id}:{artifact_id}:{name}:{start}'.encode())[:32]}",
                "project_id": project_id,
                "artifact_id": artifact_id,
                "blob_sha": blob_sha,
                "name": name,
                "kind": kind,
                "range": range_json,
                "confidence_tier": "lexical_fallback",
                "tier_evidence_json": lexical_tier_evidence_json(lang, blob_sha),
            }
        )
    return symbols


def produce_code_diagnostics(
    conn: sqlite3.Connection,
    *,
    project_id: str,
    file_path: str,
    lang: str | None,
    text: str,
    blob_sha: str,
    ts: str,
) -> None:
    tool = "python.compile" if lang == "python" else "static-parser"
    diagnostics_payload: dict[str, Any] = {
        "schema": "openburnbar.project_code_diagnostics.v1",
        "producer": tool,
        "diagnostics": [],
    }
    if lang == "python":
        try:
            compile(text, file_path, "exec")
        except SyntaxError as error:
            diagnostics_payload["diagnostics"].append(
                {
                    "severity": "error",
                    "message": error.msg,
                    "line": error.lineno,
                    "column": error.offset,
                    "endLine": error.end_lineno,
                    "endColumn": error.end_offset,
                }
            )
    else:
        # Static-parser diagnostics are currently summarized by parse tiers and
        # availability. Exact compiler/LSP diagnostics are added only when a
        # bounded producer exists for that ecosystem.
        return

    diagnostic_id = "diag_" + sha256_hex(f"{project_id}:{file_path}:{tool}".encode())[:32]
    conn.execute(
        """
        INSERT INTO code_diagnostics_cache
            (id, project_id, file_path, tool, payload_json, blob_sha, cached_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            payload_json = excluded.payload_json,
            blob_sha = excluded.blob_sha,
            cached_at = excluded.cached_at
        """,
        (
            diagnostic_id,
            project_id,
            file_path,
            tool,
            json.dumps(diagnostics_payload, sort_keys=True, separators=(",", ":")),
            blob_sha,
            ts,
        ),
    )


SCIP_DEFINITION_ROLE = 1


def _scip_role_value(raw: Any) -> int:
    if isinstance(raw, int):
        return raw
    if isinstance(raw, list):
        value = 0
        for item in raw:
            if isinstance(item, int):
                value |= item
            elif isinstance(item, str) and item.lower() in {"definition", "symbolrole_definition"}:
                value |= SCIP_DEFINITION_ROLE
        return value
    if isinstance(raw, str) and raw.lower() in {"definition", "symbolrole_definition"}:
        return SCIP_DEFINITION_ROLE
    return 0


def _scip_range(raw: Any, file_path: str) -> dict[str, Any] | None:
    if not isinstance(raw, list) or len(raw) not in {3, 4}:
        return None
    try:
        start_line = int(raw[0]) + 1
        start_column = int(raw[1]) + 1
        if len(raw) == 3:
            end_line = start_line
            end_column = int(raw[2]) + 1
        else:
            end_line = int(raw[2]) + 1
            end_column = int(raw[3]) + 1
    except (TypeError, ValueError):
        return None
    return {
        "start": {"line": start_line, "column": start_column},
        "end": {"line": max(start_line, end_line), "column": end_column},
        "filePath": file_path,
        "startLine": start_line,
        "endLine": max(start_line, end_line),
    }


def _scip_symbol_name(symbol: str, symbol_info: dict[str, Any] | None) -> str:
    if symbol_info:
        for key in ("displayName", "display_name", "name"):
            value = symbol_info.get(key)
            if isinstance(value, str) and value.strip():
                return value.strip()
    parts = [part for part in re.split(r"[/#.`\s]+", symbol) if part]
    return parts[-1] if parts else symbol


def import_scip_json(
    conn: sqlite3.Connection,
    project_path: str | None,
    scip_json_path: str,
    ecosystem: str = "typescript",
) -> dict[str, Any]:
    ensure_schema(conn)
    root = project_root(project_path)
    project_id = resolve_project_id(conn, root)
    path = Path(scip_json_path).expanduser()
    payload = json.loads(path.read_text(encoding="utf-8"))
    documents = payload.get("documents")
    if not isinstance(documents, list):
        raise ValueError("SCIP JSON import requires a documents array")

    symbol_info_by_id: dict[str, dict[str, Any]] = {}
    for info in payload.get("externalSymbols") or payload.get("external_symbols") or []:
        if isinstance(info, dict) and isinstance(info.get("symbol"), str):
            symbol_info_by_id[str(info["symbol"])] = info
    for document in documents:
        if not isinstance(document, dict):
            continue
        for info in document.get("symbols") or []:
            if isinstance(info, dict) and isinstance(info.get("symbol"), str):
                symbol_info_by_id[str(info["symbol"])] = info

    imported_symbols = 0
    imported_references = 0
    skipped_documents = 0
    ts = now_iso()
    symbol_id_by_scip: dict[str, str] = {}

    with conn:
        for document in documents:
            if not isinstance(document, dict):
                continue
            rel = document.get("relativePath") or document.get("relative_path")
            if not isinstance(rel, str) or not rel:
                skipped_documents += 1
                continue
            artifact = conn.execute(
                "SELECT id, blob_sha, lang FROM code_artifacts WHERE project_id = ? AND file_path = ? LIMIT 1",
                (project_id, rel),
            ).fetchone()
            if artifact is None:
                skipped_documents += 1
                continue
            artifact_id = str(artifact[0])
            blob_sha = str(artifact[1])
            lang = str(artifact[2] or ecosystem)
            occurrences = document.get("occurrences") or []
            if not isinstance(occurrences, list):
                continue
            for occurrence in occurrences:
                if not isinstance(occurrence, dict):
                    continue
                symbol = occurrence.get("symbol")
                if not isinstance(symbol, str) or not symbol:
                    continue
                range_payload = _scip_range(occurrence.get("range"), rel)
                if range_payload is None:
                    continue
                role_value = _scip_role_value(
                    occurrence.get("symbolRoles") if "symbolRoles" in occurrence else occurrence.get("symbol_roles")
                )
                if role_value & SCIP_DEFINITION_ROLE:
                    info = symbol_info_by_id.get(symbol)
                    name = _scip_symbol_name(symbol, info)
                    kind = str((info or {}).get("kind") or "symbol")
                    symbol_id = "scip_sym_" + sha256_hex(f"{project_id}:{artifact_id}:{symbol}".encode())[:32]
                    symbol_id_by_scip[symbol] = symbol_id
                    conn.execute(
                        """
                        INSERT OR REPLACE INTO code_symbols
                            (id, project_id, artifact_id, blob_sha, name, kind, range_json,
                             confidence_tier, tier_evidence_json, indexed_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        (
                            symbol_id,
                            project_id,
                            artifact_id,
                            blob_sha,
                            name,
                            kind,
                            json.dumps(range_payload, separators=(",", ":")),
                            "scip_index",
                            tier_evidence_json(
                                {
                                    "parser": "scip",
                                    "language": lang,
                                    "blobSHA": blob_sha,
                                    "shaMatch": True,
                                    "lspResponded": False,
                                    "details": {
                                        "ecosystem": ecosystem,
                                        "source": str(path.name),
                                        "symbol": symbol,
                                    },
                                }
                            ),
                            ts,
                        ),
                    )
                    imported_symbols += 1
            for occurrence in occurrences:
                if not isinstance(occurrence, dict):
                    continue
                symbol = occurrence.get("symbol")
                if not isinstance(symbol, str) or not symbol:
                    continue
                role_value = _scip_role_value(
                    occurrence.get("symbolRoles") if "symbolRoles" in occurrence else occurrence.get("symbol_roles")
                )
                if role_value & SCIP_DEFINITION_ROLE:
                    continue
                target_id = symbol_id_by_scip.get(symbol)
                if not target_id:
                    continue
                range_payload = _scip_range(occurrence.get("range"), rel)
                if range_payload is None:
                    continue
                reference_id = (
                    "scip_ref_"
                    + sha256_hex(f"{project_id}:{artifact_id}:{symbol}:{occurrence.get('range')}".encode())[:32]
                )
                conn.execute(
                    """
                    INSERT OR REPLACE INTO code_references
                        (id, project_id, from_artifact_id, to_symbol_id, range_json,
                         blob_sha, confidence_tier, indexed_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        reference_id,
                        project_id,
                        artifact_id,
                        target_id,
                        json.dumps(range_payload, separators=(",", ":")),
                        blob_sha,
                        "scip_index",
                        ts,
                    ),
                )
                imported_references += 1
    return {
        "status": "ok",
        "projectID": project_id,
        "ecosystem": ecosystem,
        "importedSymbols": imported_symbols,
        "importedReferences": imported_references,
        "skippedDocuments": skipped_documents,
        "confidenceTier": "scip_index",
    }


def exact_lsp_references_for_symbol(
    conn: sqlite3.Connection,
    symbol_name: str,
    project_id: str,
    root: Path,
    limit: int,
) -> list[dict[str, Any]]:
    helper = static_parser_path()
    if not helper:
        return []
    row = conn.execute(
        """
        SELECT s.id, s.range_json, s.blob_sha, a.file_path, a.lang
        FROM code_symbols AS s
        JOIN code_artifacts AS a ON a.id = s.artifact_id
        WHERE s.project_id = ? AND s.name = ?
        ORDER BY
            CASE WHEN s.confidence_tier = 'exact_lsp' THEN 0
                 WHEN s.confidence_tier = 'static_tree_sitter' THEN 1
                 ELSE 2 END,
            a.file_path ASC
        LIMIT 1
        """,
        (project_id, symbol_name),
    ).fetchone()
    if row is None:
        return []
    _symbol_id, range_raw, blob_sha, rel, lang = row
    if not artifact_is_current(conn, f"code_{sha256_hex(f'{project_id}:{rel}'.encode())[:32]}", str(blob_sha)):
        return []
    path = root / str(rel)
    try:
        text = path.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        return []
    try:
        symbol_range = json.loads(str(range_raw))
    except json.JSONDecodeError:
        return []
    start = symbol_range.get("start") if isinstance(symbol_range.get("start"), dict) else {}
    start_line = int(symbol_range.get("startLine") or start.get("line") or 1)
    start_column = int(start.get("column") or 1)
    payload = json.dumps(
        {
            "requestId": f"refs:{symbol_name}",
            "filePath": str(rel),
            "language": str(lang or ""),
            "blobSha": str(blob_sha),
            "text": text,
            "rootPath": str(root),
            "operation": "references",
            "position": {"line": max(0, start_line - 1), "character": max(0, start_column - 1)},
        },
        separators=(",", ":"),
    )
    try:
        completed = subprocess.run(
            [helper],
            input=payload + "\n",
            capture_output=True,
            text=True,
            check=False,
            timeout=code_helper_timeout_seconds(),
        )
    except (OSError, subprocess.SubprocessError):
        return []
    if completed.returncode != 0:
        return []
    if len(completed.stdout.encode("utf-8", errors="ignore")) > code_helper_max_output_bytes():
        return []
    first_line = next((line for line in completed.stdout.splitlines() if line.strip()), "")
    try:
        response = json.loads(first_line)
    except json.JSONDecodeError:
        return []
    if not response.get("ok") or response.get("blobSha") != blob_sha or response.get("errors"):
        return []
    refs: list[dict[str, Any]] = []
    for idx, ref in enumerate(response.get("references") or []):
        if not isinstance(ref, dict):
            continue
        file_path = str(ref.get("filePath") or "")
        if not file_path:
            continue
        evidence = ref.get("evidence") if isinstance(ref.get("evidence"), dict) else {}
        try:
            ref_blob = make_blob_sha((root / file_path).read_bytes())
        except OSError:
            ref_blob = str(blob_sha)
        refs.append(
            {
                "referenceID": f"lsp_ref_{sha256_hex(f'{project_id}:{symbol_name}:{file_path}:{idx}:{ref}'.encode())[:32]}",
                "symbol": symbol_name,
                "range": {
                    "start": {
                        "line": int(ref.get("startLine") or 1),
                        "column": int(ref.get("startCharacter") or 0) + 1,
                    },
                    "end": {
                        "line": int(ref.get("endLine") or ref.get("startLine") or 1),
                        "column": int(ref.get("endCharacter") or 0) + 1,
                    },
                    "filePath": file_path,
                    "startLine": int(ref.get("startLine") or 1),
                    "endLine": int(ref.get("endLine") or ref.get("startLine") or 1),
                },
                "confidenceTier": str(ref.get("confidenceTier") or "exact_lsp"),
                "filePath": file_path,
                "blobSHA": ref_blob,
                "tierEvidence": {
                    "parser": evidence.get("parser") or "lsp",
                    "language": evidence.get("language") or lang,
                    "blobSHA": evidence.get("blobSha") or blob_sha,
                    "shaMatch": bool(evidence.get("shaMatch", False)),
                    "lspResponded": bool(evidence.get("lspResponded", True)),
                    "details": {"helper": "project-code-static-parser", "operation": "textDocument/references"},
                },
                "stale": False,
            }
        )
        if len(refs) >= limit:
            break
    return refs


def index_project(
    conn: sqlite3.Connection,
    project_path: str | None,
    max_files: int = 2500,
    max_file_bytes: int = 512_000,
    storage_budget_bytes: int | None = None,
) -> dict[str, Any]:
    ensure_schema(conn)
    root = project_root(project_path)
    project_id = resolve_project_id(conn, root)
    commit_sha = current_commit(root)
    version_id = active_embedding_version(conn)
    ts = now_iso()
    max_file_bytes_limit = max(4096, int(max_file_bytes))
    files = iter_project_files(root, max(1, int(max_files)), max_file_bytes_limit)
    # Age-aware budget eviction: index newest-first so a project larger than its storage
    # budget keeps the most-recently-modified (most relevant) files and the over-budget
    # rejections are the oldest — deterministic, not filesystem-walk order.
    files = sorted(files, key=lambda candidate: candidate.stat().st_mtime if candidate.exists() else 0.0, reverse=True)
    budget = normalized_storage_budget_bytes(storage_budget_bytes)
    rejected: list[dict[str, Any]] = []
    indexed = 0
    chunk_count = 0
    storage_byte_count = 0
    compaction_decision: dict[str, int | bool] = {"shouldCompact": False}

    with conn:
        existing_artifacts = {
            str(row[1]): str(row[0])
            for row in conn.execute(
                "SELECT id, file_path FROM code_artifacts WHERE project_id = ?",
                (project_id,),
            ).fetchall()
        }
        conn.execute("DELETE FROM code_call_edges WHERE project_id = ?", (project_id,))
        conn.execute("DELETE FROM code_references WHERE project_id = ?", (project_id,))
        seen_artifact_ids: set[str] = set()
        for file_path in files:
            rel = str(file_path.resolve().relative_to(root))
            artifact_id = f"code_{sha256_hex(f'{project_id}:{rel}'.encode())[:32]}"
            lang = language_for(file_path)
            try:
                stat = file_path.stat()
            except OSError:
                upsert_file_manifest(
                    conn,
                    project_id=project_id,
                    file_path=rel,
                    artifact_id=None,
                    blob_sha=None,
                    content_hash=None,
                    byte_count=0,
                    mtime=0,
                    lang=lang,
                    ignored_reason="unreadable_or_non_utf8",
                    secret_labels=[],
                    parser_tier=None,
                    ts=ts,
                )
                continue
            try:
                data = file_path.read_bytes()
            except OSError:
                upsert_file_manifest(
                    conn,
                    project_id=project_id,
                    file_path=rel,
                    artifact_id=None,
                    blob_sha=None,
                    content_hash=None,
                    byte_count=stat.st_size,
                    mtime=stat.st_mtime,
                    lang=lang,
                    ignored_reason="unreadable_or_non_utf8",
                    secret_labels=[],
                    parser_tier=None,
                    ts=ts,
                )
                continue
            if len(data) > max_file_bytes_limit:
                upsert_file_manifest(
                    conn,
                    project_id=project_id,
                    file_path=rel,
                    artifact_id=None,
                    blob_sha=None,
                    content_hash=None,
                    byte_count=len(data),
                    mtime=stat.st_mtime,
                    lang=lang,
                    ignored_reason="max_file_bytes",
                    secret_labels=[],
                    parser_tier=None,
                    ts=ts,
                )
                continue
            if b"\x00" in data[:4096]:
                upsert_file_manifest(
                    conn,
                    project_id=project_id,
                    file_path=rel,
                    artifact_id=None,
                    blob_sha=None,
                    content_hash=None,
                    byte_count=len(data),
                    mtime=stat.st_mtime,
                    lang=lang,
                    ignored_reason="binary",
                    secret_labels=[],
                    parser_tier=None,
                    ts=ts,
                )
                continue
            text = data.decode("utf-8", errors="ignore")
            blob_sha = make_blob_sha(data)
            content_hash = sha256_hex(data)
            labels = scan_secrets(text)
            lang = language_for(file_path)
            document_id = artifact_id
            if labels:
                rejected.append({"filePath": rel, "labels": labels})
                upsert_file_manifest(
                    conn,
                    project_id=project_id,
                    file_path=rel,
                    artifact_id=None,
                    blob_sha=blob_sha,
                    content_hash=content_hash,
                    byte_count=len(data),
                    mtime=stat.st_mtime,
                    lang=lang,
                    ignored_reason="secret_rejected",
                    secret_labels=labels,
                    parser_tier=None,
                    ts=ts,
                )
                audit_event(
                    conn,
                    action="code.secret_rejected",
                    domain="code",
                    project_id=project_id,
                    subject_id=artifact_id,
                    labels=labels,
                )
                continue
            symbols = extract_symbols(text, lang, rel, project_id, artifact_id, blob_sha, root=root)
            chunks = ast_aware_chunks(text, symbols) if lang in AST_AWARE_CHUNK_LANGUAGES else chunk_text(text)
            candidate_storage_byte_count = estimated_code_storage_byte_count(
                source_bytes=len(data),
                chunks=chunks,
                file_path=rel,
                project_id=project_id,
            )
            if storage_byte_count + candidate_storage_byte_count > budget:
                rejected.append({"filePath": rel, "labels": ["Storage budget cap reached"]})
                upsert_file_manifest(
                    conn,
                    project_id=project_id,
                    file_path=rel,
                    artifact_id=None,
                    blob_sha=None,
                    content_hash=None,
                    byte_count=len(data),
                    mtime=stat.st_mtime,
                    lang=lang,
                    ignored_reason="storage_budget",
                    secret_labels=["Storage budget cap reached"],
                    parser_tier=None,
                    ts=ts,
                )
                audit_event(
                    conn,
                    action="code.storage_rejected",
                    domain="code",
                    project_id=project_id,
                    subject_id=artifact_id,
                    labels=["storage budget cap reached"],
                )
                continue
            existing = conn.execute(
                "SELECT blob_sha, content_hash FROM code_artifacts WHERE id = ? LIMIT 1",
                (artifact_id,),
            ).fetchone()
            if existing and str(existing[0]) == blob_sha and str(existing[1] or content_hash) == content_hash:
                seen_artifact_ids.add(artifact_id)
                indexed += 1
                storage_byte_count += candidate_storage_byte_count
                chunk_count += int(
                    conn.execute("SELECT COUNT(*) FROM search_chunks WHERE sourceID = ?", (artifact_id,)).fetchone()[0]
                )
                upsert_file_manifest(
                    conn,
                    project_id=project_id,
                    file_path=rel,
                    artifact_id=artifact_id,
                    blob_sha=blob_sha,
                    content_hash=content_hash,
                    byte_count=len(data),
                    mtime=stat.st_mtime,
                    lang=lang,
                    ignored_reason=None,
                    secret_labels=[],
                    parser_tier=None,
                    ts=ts,
                )
                continue

            delete_code_artifact(conn, artifact_id)
            conn.execute(
                """
                INSERT INTO code_artifacts
                    (id, project_id, file_path, blob_sha, content_hash, commit_sha, lang, byte_count, mtime, indexed_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (artifact_id, project_id, rel, blob_sha, content_hash, commit_sha, lang, len(data), stat.st_mtime, ts),
            )
            upsert_file_manifest(
                conn,
                project_id=project_id,
                file_path=rel,
                artifact_id=artifact_id,
                blob_sha=blob_sha,
                content_hash=content_hash,
                byte_count=len(data),
                mtime=stat.st_mtime,
                lang=lang,
                ignored_reason=None,
                secret_labels=[],
                parser_tier=None,
                ts=ts,
            )
            conn.execute(
                """
                INSERT INTO search_documents
                    (id, sourceKind, sourceID, sourceVersionID, provider, projectName, title, subtitle,
                     bodyPreview, sourceUpdatedAt, indexedAt, contentHash, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    document_id,
                    CODE_SOURCE_KIND,
                    artifact_id,
                    blob_sha,
                    CODE_PROVIDER,
                    project_id,
                    rel,
                    lang,
                    text[:500],
                    ts,
                    ts,
                    content_hash,
                    ts,
                    ts,
                ),
            )
            for ordinal, (start, end, body) in enumerate(chunks):
                chunk_id = f"chunk_{sha256_hex(f'{artifact_id}:{ordinal}:{sha256_hex(body)}'.encode())[:32]}"
                conn.execute(
                    """
                    INSERT INTO search_chunks
                        (id, documentID, sourceKind, sourceID, sourceVersionID, ordinal,
                         startOffset, endOffset, sectionPath, text, contentHash, createdAt, updatedAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        chunk_id,
                        document_id,
                        CODE_SOURCE_KIND,
                        artifact_id,
                        blob_sha,
                        ordinal,
                        start,
                        end,
                        rel,
                        body,
                        sha256_hex(body),
                        ts,
                        ts,
                    ),
                )
                insert_fts(conn, chunk_id, document_id, rel, body, project_id, CODE_PROVIDER)
                conn.execute(
                    """
                    INSERT OR REPLACE INTO chunk_embeddings
                        (chunkID, embeddingVersionID, vectorBlob, createdAt, updatedAt)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                    (chunk_id, version_id, vector_blob(deterministic_fingerprint_vector(body)), ts, ts),
                )
                chunk_count += 1
            for symbol in symbols:
                conn.execute(
                    """
                    INSERT INTO code_symbols
                        (id, project_id, artifact_id, blob_sha, name, kind, range_json, confidence_tier, tier_evidence_json, indexed_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        symbol["id"],
                        project_id,
                        artifact_id,
                        blob_sha,
                        symbol["name"],
                        symbol["kind"],
                        json.dumps(symbol["range"], separators=(",", ":")),
                        symbol["confidence_tier"],
                        symbol.get("tier_evidence_json"),
                        ts,
                    ),
                )
            produce_code_diagnostics(
                conn,
                project_id=project_id,
                file_path=rel,
                lang=lang,
                text=text,
                blob_sha=blob_sha,
                ts=ts,
            )
            indexed += 1
            storage_byte_count += candidate_storage_byte_count
            seen_artifact_ids.add(artifact_id)
        for artifact_id in existing_artifacts.values():
            if artifact_id not in seen_artifact_ids:
                delete_code_artifact(conn, artifact_id)
        conn.execute(
            """
            DELETE FROM pcm_file_manifest
            WHERE project_id = ?
              AND artifact_id IS NOT NULL
              AND artifact_id NOT IN (SELECT id FROM code_artifacts WHERE project_id = ?)
            """,
            (project_id, project_id),
        )
        build_references(conn, project_id, root, ts)
        previous_vacuumed_at_row = conn.execute(
            "SELECT vacuumed_at FROM code_index_checkpoints WHERE project_id = ? LIMIT 1",
            (project_id,),
        ).fetchone()
        previous_vacuumed_at = previous_vacuumed_at_row[0] if previous_vacuumed_at_row else None
        compaction_decision = sqlite_compaction_decision(conn)
        conn.execute(
            """
            INSERT INTO code_index_checkpoints
                (project_id, project_root, last_commit_sha, indexed_at, artifact_count, chunk_count,
                 rejected_count, storage_byte_count, storage_budget_bytes, vacuumed_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(project_id) DO UPDATE SET
                project_root = excluded.project_root,
                last_commit_sha = excluded.last_commit_sha,
                indexed_at = excluded.indexed_at,
                artifact_count = excluded.artifact_count,
                chunk_count = excluded.chunk_count,
                rejected_count = excluded.rejected_count,
                storage_byte_count = excluded.storage_byte_count,
                storage_budget_bytes = excluded.storage_budget_bytes,
                vacuumed_at = excluded.vacuumed_at
            """,
            (
                project_id,
                str(root),
                commit_sha,
                ts,
                indexed,
                chunk_count,
                len(rejected),
                storage_byte_count,
                budget,
                previous_vacuumed_at,
            ),
        )
        audit_event(
            conn,
            action="code.index",
            domain="code",
            project_id=project_id,
            subject_id=str(root),
            labels=[f"indexed:{indexed}", f"rejected:{len(rejected)}"],
        )
    if compaction_decision.get("shouldCompact"):
        try:
            pages = max(1, min(int(compaction_decision.get("freelistCount") or 1), 1024))
            conn.execute(f"PRAGMA incremental_vacuum({pages})")
            conn.execute(
                "UPDATE code_index_checkpoints SET vacuumed_at = ? WHERE project_id = ?",
                (ts, project_id),
            )
            conn.commit()
        except sqlite3.DatabaseError:
            pass
    return {
        "status": "ok",
        "localOnly": True,
        "indexedFiles": indexed,
        "chunkCount": chunk_count,
        "rejectedFiles": rejected,
        "commitSHA": commit_sha,
        "storageByteCount": storage_byte_count,
        "storageBudgetBytes": budget,
        **project_payload(root, project_id),
    }


def build_references(conn: sqlite3.Connection, project_id: str, root: Path, ts: str) -> None:
    symbols = conn.execute(
        "SELECT id, artifact_id, name, range_json FROM code_symbols WHERE project_id = ?",
        (project_id,),
    ).fetchall()
    by_name: dict[str, list[tuple[str, str, dict[str, Any]]]] = {}
    for sym_id, artifact_id, name, range_raw in symbols:
        by_name.setdefault(str(name), []).append((str(sym_id), str(artifact_id), json.loads(str(range_raw))))
    if not by_name:
        return
    artifacts = conn.execute(
        "SELECT id, file_path, blob_sha FROM code_artifacts WHERE project_id = ?",
        (project_id,),
    ).fetchall()
    symbol_ranges_by_artifact: dict[str, list[tuple[int, str]]] = {}
    for sym_id, artifact_id, _name, range_raw in symbols:
        symbol_ranges_by_artifact.setdefault(str(artifact_id), []).append(
            (int(json.loads(str(range_raw)).get("byteStart", 0)), str(sym_id))
        )
    for values in symbol_ranges_by_artifact.values():
        values.sort()
    for artifact_id, rel, blob_sha in artifacts:
        path = root / str(rel)
        try:
            text = path.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        line_start = 0
        for line in text.splitlines(keepends=True):
            for match in re.finditer(r"\b[A-Za-z_][A-Za-z0-9_]{2,}\b", line):
                name = match.group(0)
                target_symbols = by_name.get(name)
                if not target_symbols:
                    continue
                start = line_start + match.start()
                end = line_start + match.end()
                range_json = {
                    "start": line_col(text, start),
                    "end": line_col(text, end),
                    "byteStart": start,
                    "byteEnd": end,
                    "filePath": str(rel),
                }
                caller = enclosing_symbol(symbol_ranges_by_artifact.get(str(artifact_id), []), start)
                for target_id, _target_artifact, target_range in target_symbols:
                    if target_range.get("filePath") == str(rel) and int(
                        target_range.get("byteStart", -1)
                    ) <= start <= int(target_range.get("byteEnd", -1)):
                        continue
                    ref_id = f"ref_{sha256_hex(f'{project_id}:{artifact_id}:{target_id}:{start}'.encode())[:32]}"
                    conn.execute(
                        """
                        INSERT OR IGNORE INTO code_references
                            (id, project_id, from_artifact_id, to_symbol_id, range_json, blob_sha, confidence_tier, indexed_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        (
                            ref_id,
                            project_id,
                            artifact_id,
                            target_id,
                            json.dumps(range_json, separators=(",", ":")),
                            blob_sha,
                            "lexical_fallback",
                            ts,
                        ),
                    )
                    if caller and caller != target_id:
                        edge_id = f"edge_{sha256_hex(f'{project_id}:{caller}:{target_id}'.encode())[:32]}"
                        conn.execute(
                            """
                            INSERT OR IGNORE INTO code_call_edges
                                (id, project_id, caller_symbol_id, callee_symbol_id, confidence_tier, indexed_at)
                            VALUES (?, ?, ?, ?, ?, ?)
                            """,
                            (edge_id, project_id, caller, target_id, "lexical_fallback", ts),
                        )
            line_start += len(line)


def enclosing_symbol(symbol_starts: list[tuple[int, str]], offset: int) -> str | None:
    current: str | None = None
    for start, sym_id in symbol_starts:
        if start > offset:
            break
        current = sym_id
    return current


def current_blob_for(conn: sqlite3.Connection, artifact_id: str) -> str | None:
    row = conn.execute("SELECT project_id, file_path FROM code_artifacts WHERE id = ?", (artifact_id,)).fetchone()
    if row is None:
        return None
    checkpoint = conn.execute(
        "SELECT project_root FROM code_index_checkpoints WHERE project_id = ?", (row[0],)
    ).fetchone()
    if checkpoint is None:
        return None
    path = Path(str(checkpoint[0])) / str(row[1])
    try:
        return make_blob_sha(path.read_bytes())
    except OSError:
        return None


class ArtifactFreshnessCache:
    def __init__(self, conn: sqlite3.Connection):
        self.conn = conn
        self._values: dict[tuple[str, str], bool] = {}

    def is_current(self, artifact_id: str, blob_sha: str) -> bool:
        key = (artifact_id, blob_sha)
        if key not in self._values:
            current_blob = current_blob_for(self.conn, artifact_id)
            self._values[key] = bool(current_blob and current_blob == blob_sha)
        return self._values[key]


def artifact_is_current(
    conn: sqlite3.Connection,
    artifact_id: str,
    blob_sha: str,
    cache: ArtifactFreshnessCache | None = None,
) -> bool:
    if cache is not None:
        return cache.is_current(artifact_id, blob_sha)
    current_blob = current_blob_for(conn, artifact_id)
    return bool(current_blob and current_blob == blob_sha)


def index_age_seconds(conn: sqlite3.Connection, project_id: str) -> float | None:
    row = conn.execute(
        "SELECT indexed_at FROM code_index_checkpoints WHERE project_id = ? LIMIT 1",
        (project_id,),
    ).fetchone()
    if row is None or not row[0]:
        return None
    raw = str(row[0])
    try:
        indexed_at = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        return None
    return max(0.0, (datetime.now(UTC) - indexed_at).total_seconds())


def stale_degradation_payload(
    conn: sqlite3.Connection,
    project_id: str,
    stale_candidate_count: int,
    total_candidate_count: int,
) -> dict[str, Any] | None:
    if total_candidate_count <= 0 or stale_candidate_count * 2 < total_candidate_count:
        return None
    return {
        "code": "STALE_INDEX",
        "message": "At least half of the candidate rows point at files whose current blob no longer matches the indexed blob.",
        "staleCandidateCount": stale_candidate_count,
        "totalCandidateCount": total_candidate_count,
        "indexAgeSeconds": index_age_seconds(conn, project_id),
        "reindexHint": "Run burnbar_index_project for this project before relying on code-memory results.",
    }


def search_code(conn: sqlite3.Connection, query: str, project_path: str | None, limit: int) -> dict[str, Any]:
    ensure_schema(conn)
    root = project_root(project_path)
    project_id = resolve_project_id(conn, root)
    q = fts_query(query)
    if not q:
        return {"status": "unavailable", "code": "EMPTY_QUERY", "reason": "query produced no searchable tokens"}
    lim = max(1, min(int(limit), 50))
    lexical: dict[str, dict[str, Any]] = {}
    try:
        rows = conn.execute(
            """
            SELECT
                c.id, c.documentID, c.text, c.ordinal, c.startOffset, c.endOffset,
                d.title, d.sourceVersionID, a.file_path, a.lang, a.id,
                bm25(search_chunks_fts) AS rank,
                snippet(search_chunks_fts, 3, '<b>', '</b>', '...', 18) AS snippet
            FROM search_chunks_fts
            JOIN search_chunks AS c ON c.id = search_chunks_fts.chunkID
            JOIN search_documents AS d ON d.id = c.documentID
            JOIN code_artifacts AS a ON a.id = d.sourceID
            WHERE search_chunks_fts MATCH ?
              AND d.sourceKind = ?
              AND a.project_id = ?
            ORDER BY rank ASC
            LIMIT ?
            """,
            (q, CODE_SOURCE_KIND, project_id, lim * 3),
        ).fetchall()
    except sqlite3.OperationalError:
        rows = conn.execute(
            """
            SELECT c.id, c.documentID, c.text, c.ordinal, c.startOffset, c.endOffset,
                   d.title, d.sourceVersionID, a.file_path, a.lang, a.id, 0.0 AS rank, c.text AS snippet
            FROM search_chunks AS c
            JOIN search_documents AS d ON d.id = c.documentID
            JOIN code_artifacts AS a ON a.id = d.sourceID
            WHERE d.sourceKind = ? AND a.project_id = ? AND c.text LIKE ?
            LIMIT ?
            """,
            (CODE_SOURCE_KIND, project_id, f"%{query}%", lim * 3),
        ).fetchall()
    for idx, row in enumerate(rows):
        lexical[str(row[0])] = {
            "chunkID": row[0],
            "documentID": row[1],
            "text": row[2],
            "ordinal": row[3],
            "startOffset": row[4],
            "endOffset": row[5],
            "title": row[6],
            "blobSHA": row[7],
            "filePath": row[8],
            "language": row[9],
            "artifactID": row[10],
            "rank": float(row[11] or 0.0),
            "snippet": row[12],
            "lexicalRank": idx + 1,
        }
    freshness = ArtifactFreshnessCache(conn)
    results = []
    stale_candidates = 0
    for _chunk_id, item in lexical.items():
        if not artifact_is_current(conn, str(item["artifactID"]), str(item["blobSHA"]), freshness):
            stale_candidates += 1
            continue
        record_id = str(item["chunkID"] or item["documentID"] or "unknown")
        score = 1.0 / (60.0 + float(item.get("lexicalRank") or 1))
        rank_features = {
            "ftsBM25": float(item.get("rank") or 0.0),
            "lexicalRank": float(item.get("lexicalRank") or 0),
            "score": score,
        }
        results.append(
            {
                "chunkID": item["chunkID"],
                "filePath": item["filePath"],
                "language": item["language"],
                "snippet": wrap_untrusted_snippet(
                    item["snippet"],
                    source_tool="burnbar_search_code",
                    record_id=record_id,
                ),
                "score": score,
                "rankFeatures": rank_features,
                "confidenceTier": "lexical_fallback",
                "blobSHA": item["blobSHA"],
                "stale": False,
                "source": {"kind": CODE_SOURCE_KIND, "documentID": item["documentID"], "chunkOrdinal": item["ordinal"]},
            }
        )
    results.sort(key=lambda item: (-float(item["score"]), str(item["filePath"])))
    total_candidates = len(lexical)
    degradation = stale_degradation_payload(conn, project_id, stale_candidates, total_candidates)
    semantic_status = semantic_retrieval_status(conn, project_id)
    return {
        "status": "degraded" if degradation else "ok",
        "code": "STALE_INDEX" if degradation else None,
        "query": query,
        "results": results[:lim],
        **semantic_status,
        "degradation": degradation,
        "localOnly": True,
        "trustSignal": {
            "untrustedContentWrapped": True,
            "wrappedCount": len(results[:lim]),
            "sourceTool": "burnbar_search_code",
        },
        **project_payload(root, project_id),
    }


def semantic_retrieval_status(conn: sqlite3.Connection, project_id: str) -> dict[str, Any]:
    configured_provider = os.environ.get("OPENBURNBAR_CODE_EMBEDDING_PROVIDER", "").strip().lower()
    configured_model = os.environ.get(
        SELECTED_LOCAL_EMBEDDING_MODEL_ENV, SELECTED_LOCAL_EMBEDDING_MODEL_DEFAULT
    ).strip()
    if configured_provider != SELECTED_LOCAL_EMBEDDING_PROVIDER:
        return {
            "semanticAvailable": False,
            "embeddingProvider": SELECTED_LOCAL_EMBEDDING_PROVIDER,
            "embeddingModel": configured_model,
            "embeddingVersion": None,
            "semanticFallbackReason": (
                "OPENBURNBAR_CODE_EMBEDDING_PROVIDER must be set to ollama before dense retrieval can run."
            ),
        }

    row = conn.execute(
        """
        SELECT ev.id, em.provider, em.modelName
        FROM embedding_versions ev
        JOIN embedding_models em ON em.id = ev.modelID
        WHERE ev.isActive = 1
        LIMIT 1
        """
    ).fetchone()
    if row is None or str(row[1]) == DETERMINISTIC_FINGERPRINT_PROVIDER:
        return {
            "semanticAvailable": False,
            "embeddingProvider": SELECTED_LOCAL_EMBEDDING_PROVIDER,
            "embeddingModel": configured_model,
            "embeddingVersion": None,
            "semanticFallbackReason": "active embeddings are fingerprints, not learned local code embeddings",
        }

    total_chunks = int(
        conn.execute(
            """
            SELECT COUNT(*)
            FROM search_chunks c
            JOIN search_documents d ON d.id = c.documentID
            JOIN code_artifacts a ON a.id = d.sourceID
            WHERE d.sourceKind = ? AND a.project_id = ?
            """,
            (CODE_SOURCE_KIND, project_id),
        ).fetchone()[0]
    )
    vector_chunks = int(
        conn.execute(
            """
            SELECT COUNT(*)
            FROM chunk_embeddings ce
            JOIN search_chunks c ON c.id = ce.chunkID
            JOIN search_documents d ON d.id = c.documentID
            JOIN code_artifacts a ON a.id = d.sourceID
            WHERE d.sourceKind = ? AND a.project_id = ? AND ce.embeddingVersionID = ?
            """,
            (CODE_SOURCE_KIND, project_id, str(row[0])),
        ).fetchone()[0]
    )
    if total_chunks == 0 or vector_chunks < total_chunks:
        return {
            "semanticAvailable": False,
            "embeddingProvider": str(row[1]),
            "embeddingModel": str(row[2]),
            "embeddingVersion": str(row[0]),
            "semanticFallbackReason": "dense retrieval disabled until every current chunk has the active embedding version",
        }
    return {
        "semanticAvailable": True,
        "embeddingProvider": str(row[1]),
        "embeddingModel": str(row[2]),
        "embeddingVersion": str(row[0]),
        "semanticFallbackReason": None,
    }


def _chunk_context_row(conn: sqlite3.Connection, chunk_id: str) -> sqlite3.Row | tuple[Any, ...] | None:
    return conn.execute(
        """
        SELECT c.text, c.startOffset, c.endOffset, c.sourceID, a.file_path, a.blob_sha, c.contentHash
        FROM search_chunks c
        JOIN search_documents d ON d.id = c.documentID
        JOIN code_artifacts a ON a.id = d.sourceID
        WHERE c.id = ?
        LIMIT 1
        """,
        (chunk_id,),
    ).fetchone()


def complete_symbol_context(
    conn: sqlite3.Connection,
    *,
    root: Path,
    project_id: str,
    chunk_id: str,
) -> dict[str, Any] | None:
    row = _chunk_context_row(conn, chunk_id)
    if row is None:
        return None
    chunk_text_value = str(row[0])
    chunk_start = int(row[1] or 0)
    chunk_end = int(row[2] or chunk_start)
    artifact_id = str(row[3])
    file_path = str(row[4])
    blob_sha = str(row[5])
    content_hash = str(row[6] or sha256_hex(chunk_text_value))
    try:
        text = (root / file_path).read_text(encoding="utf-8", errors="ignore")
    except OSError:
        return {
            "text": chunk_text_value,
            "contentKind": "chunk",
            "symbolName": None,
            "confidenceTier": "lexical_fallback",
            "filePath": file_path,
            "blobSHA": blob_sha,
            "contentHash": content_hash,
        }

    candidates = conn.execute(
        """
        SELECT name, kind, range_json, confidence_tier
        FROM code_symbols
        WHERE project_id = ? AND artifact_id = ? AND blob_sha = ?
        """,
        (project_id, artifact_id, blob_sha),
    ).fetchall()
    best: tuple[int, int, str, str, str] | None = None
    for name, kind, range_raw, confidence_tier in candidates:
        try:
            range_payload = json.loads(str(range_raw))
        except json.JSONDecodeError:
            continue
        offsets = _range_offsets(text, range_payload)
        if offsets is None:
            continue
        start, end = offsets
        overlaps = start < chunk_end and end > chunk_start
        if not overlaps:
            continue
        length = end - start
        if length <= 0 or length > MAX_COMPLETE_SYMBOL_CONTEXT_CHARS:
            continue
        if best is None or length < (best[1] - best[0]):
            best = (start, end, str(name), str(kind), str(confidence_tier))
    if best is None:
        return {
            "text": chunk_text_value,
            "contentKind": "chunk",
            "symbolName": None,
            "confidenceTier": "lexical_fallback",
            "filePath": file_path,
            "blobSHA": blob_sha,
            "contentHash": content_hash,
        }
    start, end, symbol_name, kind, confidence_tier = best
    symbol_text = text[start:end]
    return {
        "text": symbol_text,
        "contentKind": "complete_symbol",
        "symbolName": symbol_name,
        "symbolKind": kind,
        "confidenceTier": confidence_tier,
        "filePath": file_path,
        "blobSHA": blob_sha,
        "contentHash": sha256_hex(symbol_text),
    }


def context_pack(
    conn: sqlite3.Connection, query: str, project_path: str | None, token_budget: int, limit: int
) -> dict[str, Any]:
    payload = search_code(conn, query, project_path, limit)
    if payload.get("status") not in {"ok", "degraded"}:
        return payload
    root = project_root(project_path)
    project_id = str(payload["projectID"])
    budget = max(500, min(int(token_budget), 24_000))
    used = 0
    sections: list[str] = []
    estimator = token_estimator_name()
    for hit in payload["results"]:
        context = complete_symbol_context(conn, root=root, project_id=project_id, chunk_id=str(hit["chunkID"]))
        text = str(context["text"]) if context else ""
        content_kind = str(context.get("contentKind") if context else "chunk")
        confidence_tier = str(context.get("confidenceTier") if context else hit["confidenceTier"])
        symbol_name = context.get("symbolName") if context else None
        wrapped_text = wrap_untrusted_snippet(
            text,
            source_tool="burnbar_context_pack",
            record_id=str(hit.get("chunkID") or "unknown"),
        )
        symbol_attr = f' symbol="{symbol_name}"' if symbol_name else ""
        section = (
            f'<file path="{hit["filePath"]}" tier="{confidence_tier}" '
            f'contentKind="{content_kind}"{symbol_attr}>\n{wrapped_text}\n</file>'
        )
        approx_tokens = estimate_context_tokens(section)
        if used + approx_tokens > budget:
            break
        used += approx_tokens
        sections.append(section)
    context_pack_text = "\n".join(sections)
    return {
        **payload,
        "tokenBudget": budget,
        "estimatedTokens": estimate_context_tokens(context_pack_text),
        "tokenEstimator": estimator,
        "contextPack": context_pack_text,
    }


def get_symbol(conn: sqlite3.Connection, name: str, project_path: str | None, limit: int) -> dict[str, Any]:
    ensure_schema(conn)
    root = project_root(project_path)
    project_id = resolve_project_id(conn, root)
    rows = conn.execute(
        """
        SELECT s.id, s.name, s.kind, s.range_json, s.blob_sha, s.confidence_tier,
               a.file_path, a.id, s.tier_evidence_json
        FROM code_symbols AS s
        JOIN code_artifacts AS a ON a.id = s.artifact_id
        WHERE s.project_id = ? AND (s.name = ? OR s.name LIKE ?)
        ORDER BY CASE WHEN s.name = ? THEN 0 ELSE 1 END,
                 CASE s.confidence_tier
                     WHEN 'exact_lsp' THEN 0
                     WHEN 'scip_index' THEN 1
                     WHEN 'static_tree_sitter' THEN 2
                     ELSE 3
                 END,
                 s.name ASC
        LIMIT ?
        """,
        (project_id, name, f"%{name}%", name, max(1, min(int(limit), 50))),
    ).fetchall()
    freshness = ArtifactFreshnessCache(conn)
    symbols = []
    stale_candidates = 0
    for row in rows:
        if not artifact_is_current(conn, str(row[7]), str(row[4]), freshness):
            stale_candidates += 1
            continue
        symbols.append(
            {
                "symbolID": row[0],
                "name": row[1],
                "kind": row[2],
                "range": json.loads(row[3]),
                "blobSHA": row[4],
                "confidenceTier": row[5],
                "filePath": row[6],
                "tierEvidence": decode_tier_evidence(row[8]),
                "stale": False,
            }
        )
    degradation = stale_degradation_payload(conn, project_id, stale_candidates, len(rows))
    return {
        "status": "degraded" if degradation else "ok",
        "degradation": degradation,
        "symbols": symbols,
        **project_payload(root, project_id),
    }


def find_references(conn: sqlite3.Connection, symbol_name: str, project_path: str | None, limit: int) -> dict[str, Any]:
    ensure_schema(conn)
    root = project_root(project_path)
    project_id = resolve_project_id(conn, root)
    lim = max(1, min(int(limit), 200))
    exact_refs = exact_lsp_references_for_symbol(conn, symbol_name, project_id, root, lim)
    if exact_refs:
        return {
            "status": "ok",
            "references": exact_refs,
            "confidenceTier": "exact_lsp",
            **project_payload(root, project_id),
        }
    rows = conn.execute(
        """
        SELECT r.id, target.name, r.range_json, r.confidence_tier, a.file_path,
               r.blob_sha, a.id, target.tier_evidence_json
        FROM code_references AS r
        JOIN code_symbols AS target ON target.id = r.to_symbol_id
        JOIN code_artifacts AS a ON a.id = r.from_artifact_id
        WHERE r.project_id = ? AND target.name = ?
        ORDER BY a.file_path ASC
        LIMIT ?
        """,
        (project_id, symbol_name, lim),
    ).fetchall()
    freshness = ArtifactFreshnessCache(conn)
    refs = []
    stale_candidates = 0
    for row in rows:
        if not artifact_is_current(conn, str(row[6]), str(row[5]), freshness):
            stale_candidates += 1
            continue
        refs.append(
            {
                "referenceID": row[0],
                "symbol": row[1],
                "range": json.loads(row[2]),
                "confidenceTier": row[3],
                "filePath": row[4],
                "blobSHA": row[5],
                "tierEvidence": decode_tier_evidence(row[7]),
                "stale": False,
            }
        )
    degradation = stale_degradation_payload(conn, project_id, stale_candidates, len(rows))
    return {
        "status": "degraded" if degradation else "ok",
        "degradation": degradation,
        "references": refs,
        **project_payload(root, project_id),
    }


def call_graph(
    conn: sqlite3.Connection, symbol_name: str, project_path: str | None, depth: int, limit: int
) -> dict[str, Any]:
    ensure_schema(conn)
    root = project_root(project_path)
    project_id = resolve_project_id(conn, root)
    effective_depth = max(1, min(int(depth), 3))
    edge_limit = max(1, min(int(limit), 200))

    # Seed set: the query symbol appears as either caller or callee.
    seed_rows = conn.execute(
        """
        SELECT caller.name, callee.name, caller_art.file_path, callee_art.file_path, e.confidence_tier,
               caller_art.id, caller.blob_sha, callee_art.id, callee.blob_sha,
               caller.tier_evidence_json, callee.tier_evidence_json
        FROM code_call_edges AS e
        JOIN code_symbols AS caller ON caller.id = e.caller_symbol_id
        JOIN code_symbols AS callee ON callee.id = e.callee_symbol_id
        JOIN code_artifacts AS caller_art ON caller_art.id = caller.artifact_id
        JOIN code_artifacts AS callee_art ON callee_art.id = callee.artifact_id
        WHERE e.project_id = ? AND (caller.name = ? OR callee.name = ?)
        ORDER BY caller.name, callee.name
        """,
        (project_id, symbol_name, symbol_name),
    ).fetchall()
    freshness = ArtifactFreshnessCache(conn)

    def _is_current(row: tuple[Any, ...]) -> bool:
        return artifact_is_current(conn, str(row[5]), str(row[6]), freshness) and artifact_is_current(
            conn, str(row[7]), str(row[8]), freshness
        )

    def _edge_obj(row: tuple[Any, ...], hop: int) -> dict[str, Any]:
        return {
            "caller": row[0],
            "callee": row[1],
            "callerPath": row[2],
            "calleePath": row[3],
            "confidenceTier": row[4],
            "callerTierEvidence": decode_tier_evidence(row[9]),
            "calleeTierEvidence": decode_tier_evidence(row[10]),
            "hop": hop,
        }

    edges: list[dict[str, Any]] = []
    seen_edge_keys: set[tuple[str, str]] = set()
    visited_symbols: set[str] = set()
    stale_candidates = 0
    total_candidates = 0

    def _add_edges(rows: list[tuple[Any, ...]], hop: int) -> list[str]:
        nonlocal stale_candidates, total_candidates
        discovered: list[str] = []
        for row in rows:
            total_candidates += 1
            if not _is_current(row):
                stale_candidates += 1
                continue
            key = (str(row[0]), str(row[1]))
            if key in seen_edge_keys:
                continue
            seen_edge_keys.add(key)
            edges.append(_edge_obj(row, hop))
            for name in (str(row[0]), str(row[1])):
                if name not in visited_symbols:
                    visited_symbols.add(name)
                    discovered.append(name)
        return discovered

    frontier = _add_edges(seed_rows, hop=1)
    conn.execute("CREATE TEMP TABLE IF NOT EXISTS temp_code_call_frontier (name TEXT PRIMARY KEY)")

    # Multi-hop BFS: expand neighbors until depth is exhausted or edge limit reached.
    for hop in range(2, effective_depth + 1):
        if not frontier or len(edges) >= edge_limit:
            break
        conn.execute("DELETE FROM temp_code_call_frontier")
        conn.executemany(
            "INSERT OR IGNORE INTO temp_code_call_frontier (name) VALUES (?)",
            [(name,) for name in frontier],
        )
        hop_rows = conn.execute(
            """
            SELECT caller.name, callee.name, caller_art.file_path, callee_art.file_path, e.confidence_tier,
                   caller_art.id, caller.blob_sha, callee_art.id, callee.blob_sha,
                   caller.tier_evidence_json, callee.tier_evidence_json
            FROM code_call_edges AS e
            JOIN code_symbols AS caller ON caller.id = e.caller_symbol_id
            JOIN code_symbols AS callee ON callee.id = e.callee_symbol_id
            JOIN code_artifacts AS caller_art ON caller_art.id = caller.artifact_id
            JOIN code_artifacts AS callee_art ON callee_art.id = callee.artifact_id
            WHERE e.project_id = ?
              AND caller.name IN (SELECT name FROM temp_code_call_frontier)
            ORDER BY caller.name, callee.name
            """,
            (project_id,),
        ).fetchall()
        frontier = _add_edges(hop_rows, hop=hop)
        if len(edges) >= edge_limit:
            edges = edges[:edge_limit]
            break

    edges.sort(key=lambda item: (int(item["hop"]), str(item["caller"]), str(item["callee"])))
    degradation = stale_degradation_payload(conn, project_id, stale_candidates, total_candidates)
    return {
        "status": "degraded" if degradation else "ok",
        "degradation": degradation,
        "depth": effective_depth,
        "edges": edges[:edge_limit],
        "truncated": len(edges) >= edge_limit,
        **project_payload(root, project_id),
    }


def diagnostics(conn: sqlite3.Connection, project_path: str | None, tool: str | None, limit: int) -> dict[str, Any]:
    ensure_schema(conn)
    root = project_root(project_path)
    project_id = resolve_project_id(conn, root)
    if tool:
        rows = conn.execute(
            """
            SELECT file_path, tool, payload_json, blob_sha, cached_at
            FROM code_diagnostics_cache
            WHERE project_id = ? AND tool = ?
            ORDER BY cached_at DESC
            LIMIT ?
            """,
            (project_id, tool, max(1, min(int(limit), 100))),
        ).fetchall()
    else:
        rows = conn.execute(
            """
            SELECT file_path, tool, payload_json, blob_sha, cached_at
            FROM code_diagnostics_cache
            WHERE project_id = ?
            ORDER BY cached_at DESC
            LIMIT ?
            """,
            (project_id, max(1, min(int(limit), 100))),
        ).fetchall()
    return {
        "status": "ok",
        "diagnostics": [
            {"filePath": row[0], "tool": row[1], "payload": json.loads(row[2]), "blobSHA": row[3], "cachedAt": row[4]}
            for row in rows
        ],
        **project_payload(root, project_id),
    }


def index_status(conn: sqlite3.Connection, project_path: str | None) -> dict[str, Any]:
    ensure_schema(conn)
    root = project_root(project_path)
    project_id = resolve_project_id(conn, root)
    checkpoint = conn.execute(
        """
        SELECT indexed_at, artifact_count, chunk_count, rejected_count, last_commit_sha,
               storage_byte_count, storage_budget_bytes, vacuumed_at
        FROM code_index_checkpoints
        WHERE project_id = ?
        """,
        (project_id,),
    ).fetchone()
    pending_forgets = 0
    if "memory_audit" in table_names(conn):
        pending_forgets = int(
            conn.execute(
                "SELECT COUNT(*) FROM memory_audit WHERE project_id = ? AND action = 'memory.forget'",
                (project_id,),
            ).fetchone()[0]
        )
    storage_byte_count = project_code_storage_byte_count(conn, project_id)
    stored_budget = int(checkpoint[6]) if checkpoint else 0
    storage_budget = stored_budget if stored_budget > 0 else DEFAULT_PROJECT_STORAGE_BUDGET_BYTES
    parser_available = static_parser_path() is not None
    return {
        "status": "ok",
        "indexed": checkpoint is not None,
        "indexedAt": checkpoint[0] if checkpoint else None,
        "artifactCount": checkpoint[1] if checkpoint else 0,
        "chunkCount": checkpoint[2] if checkpoint else 0,
        "rejectedCount": checkpoint[3] if checkpoint else 0,
        "commitSHA": checkpoint[4] if checkpoint else None,
        "pendingCloudForgets": pending_forgets,
        "storageByteCount": storage_byte_count,
        "storageBudgetBytes": storage_budget,
        "storageWithinBudget": storage_byte_count <= storage_budget,
        "lastVacuumedAt": checkpoint[7] if checkpoint else None,
        "PROJECT_CODE_MEMORY_PRODUCTION_READY": False,
        "productionReady": False,
        "productionReadinessReasons": [
            "PROJECT_CODE_MEMORY_PRODUCTION_READY=false",
            "semanticAvailable=false until a real local embedding provider is configured",
            "Python direct helpers and daemon runtime are not fully canonicalized behind daemon RPC",
            "SQLCipher codec not linked; Project Code Memory release readiness is blocked",
            "databaseEncrypted=false; local Project Code Memory remains plaintext at rest in this helper",
            "hosted code tools remain disabled unless an explicit threat-model flag is enabled",
        ]
        + ([] if parser_available else ["static parser helper is unavailable"]),
        "parserAvailable": parser_available,
        "semanticAvailable": False,
        "databaseEncrypted": False,
        "hostedCodeToolsEnabled": False,
        "localOnly": True,
        **project_payload(root, project_id),
    }


def repo_map(conn: sqlite3.Connection, project_path: str | None, limit: int = 50) -> dict[str, Any]:
    ensure_schema(conn)
    root = project_root(project_path)
    project_id = resolve_project_id(conn, root)
    top_limit = max(1, min(int(limit), 500))
    top_files = [
        {"filePath": row[0], "lang": row[1], "symbolCount": int(row[2])}
        for row in conn.execute(
            """
            SELECT a.file_path, a.lang, COUNT(s.id) AS symbol_count
            FROM code_artifacts AS a
            LEFT JOIN code_symbols AS s ON s.artifact_id = a.id
            WHERE a.project_id = ?
            GROUP BY a.id
            ORDER BY symbol_count DESC, a.file_path ASC
            LIMIT ?
            """,
            (project_id, top_limit),
        ).fetchall()
    ]
    languages = [
        {"lang": str(row[0]), "fileCount": int(row[1]), "byteCount": int(row[2])}
        for row in conn.execute(
            """
            SELECT COALESCE(lang, 'unknown') AS lang, COUNT(*) AS file_count, COALESCE(SUM(byte_count), 0) AS byte_count
            FROM code_artifacts
            WHERE project_id = ?
            GROUP BY COALESCE(lang, 'unknown')
            ORDER BY file_count DESC, lang ASC
            """,
            (project_id,),
        ).fetchall()
    ]
    return {
        "artifactCount": int(
            conn.execute("SELECT COUNT(*) FROM code_artifacts WHERE project_id = ?", (project_id,)).fetchone()[0]
        ),
        "symbolCount": int(
            conn.execute("SELECT COUNT(*) FROM code_symbols WHERE project_id = ?", (project_id,)).fetchone()[0]
        ),
        "languages": languages,
        "topFiles": top_files,
        **project_payload(root, project_id),
    }


def explore(
    conn: sqlite3.Connection, query: str, project_path: str | None, token_budget: int, limit: int
) -> dict[str, Any]:
    status = index_status(conn, project_path)
    if not status.get("indexed"):
        index_project(conn, project_path)
    payload = context_pack(conn, query, project_path, token_budget, limit)
    return {**payload, "repoMap": repo_map(conn, project_path, limit)}
