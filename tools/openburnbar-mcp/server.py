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
import math
import os
import re
import shutil
import sqlite3
import string
import subprocess
import struct
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, UTC
from pathlib import Path
from typing import Any

from mcp.server.fastmcp import FastMCP
from domain_core_cloudvault import (
    _cloud_semantic_hashes,
    _cloud_token_hashes,
    _cloud_vault_aad_context,
    _cloud_vault_hmac_hex,
    _cloud_vault_project_memory_doc_id,
    _open_cloud_blob_envelope,
    _open_cloud_sealed_text,
    _seal_cloud_blob_envelope,
)

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
import project_code_memory as pcm  # noqa: E402
import memory_engine as me  # noqa: E402
import ministry as ministry_core  # noqa: E402
import castle as castle_core  # noqa: E402

mcp = FastMCP("openburnbar-local")

LOCAL_MCP_DEFAULT_PROFILE = "read_only"
LOCAL_MCP_ALLOWED_PROFILES = {"read_only", "operator"}
LOCAL_MCP_OPERATOR_CAPABILITIES = {
    "cloud_decrypt",
    "cloud_sync",
    "local_write",
    "memory_llm_extract",
    "memory_write",
    "sensitive_read",
    "spawn_process",
}
LOCAL_MCP_CAPABILITY_ENV = {
    "cloud_decrypt": "OPENBURNBAR_LOCAL_MCP_ENABLE_CLOUD_DECRYPT",
    "cloud_sync": "OPENBURNBAR_LOCAL_MCP_ENABLE_CLOUD_SYNC",
    "local_write": "OPENBURNBAR_LOCAL_MCP_ENABLE_LOCAL_WRITE",
    # A tool argument may only select an LLM extractor (claude / ollama) for
    # `burnbar_memorize` when this capability is on; the operator-configured
    # `OPENBURNBAR_MEMORY_EXTRACTOR` is user intent and needs no capability.
    "memory_llm_extract": "OPENBURNBAR_LOCAL_MCP_ENABLE_MEMORY_LLM_EXTRACT",
    "memory_write": "OPENBURNBAR_LOCAL_MCP_ENABLE_MEMORY_WRITE",
    "memory_secret_retain": "OPENBURNBAR_LOCAL_MCP_ENABLE_SECRET_RETAIN",
    "sensitive_read": "OPENBURNBAR_LOCAL_MCP_ENABLE_SENSITIVE_READ",
    "spawn_process": "OPENBURNBAR_LOCAL_MCP_ENABLE_SPAWN",
}
MEMORY_MIRROR_ENV = "OPENBURNBAR_MEMORY_MIRROR_TO_DAEMON"
LOCAL_MCP_RATE_LIMIT_BUCKETS: dict[tuple[str, str, int], int] = {}
LOCAL_MCP_RATE_LIMIT_WINDOW_SECONDS = 60


def _local_mcp_rate_limit_per_minute(family: str) -> int:
    raw = (
        os.environ.get(f"OPENBURNBAR_LOCAL_MCP_{family.upper()}_RATE_LIMIT_PER_MINUTE")
        or os.environ.get("OPENBURNBAR_LOCAL_MCP_RATE_LIMIT_PER_MINUTE")
        or "120"
    )
    try:
        value = int(raw)
    except ValueError:
        value = 120
    return max(1, min(value, 10_000))


def _local_mcp_rate_limit(tool: str, family: str) -> str | None:
    limit = _local_mcp_rate_limit_per_minute(family)
    window = int(time.monotonic() // LOCAL_MCP_RATE_LIMIT_WINDOW_SECONDS)
    key = (family, tool, window)
    stale = [bucket for bucket in LOCAL_MCP_RATE_LIMIT_BUCKETS if bucket[2] < window - 1]
    for bucket in stale:
        LOCAL_MCP_RATE_LIMIT_BUCKETS.pop(bucket, None)
    count = LOCAL_MCP_RATE_LIMIT_BUCKETS.get(key, 0) + 1
    LOCAL_MCP_RATE_LIMIT_BUCKETS[key] = count
    if count <= limit:
        return None
    return json.dumps(
        {
            "status": "unavailable",
            "code": "LOCAL_MCP_RATE_LIMITED",
            "tool": tool,
            "family": family,
            "limitPerMinute": limit,
            "retryAfterSeconds": LOCAL_MCP_RATE_LIMIT_WINDOW_SECONDS,
        },
        indent=2,
    )


def _reset_local_mcp_rate_limiter_for_tests() -> None:
    LOCAL_MCP_RATE_LIMIT_BUCKETS.clear()


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


# ---------------------------------------------------------------------------
# Read-only access to the shared store.
#
# The app keys openburnbar.sqlite with SQLCipher (mandatory since B-DATA-1), and
# stdlib `sqlite3` has no codec — a direct open of a production store raises
# "file is not a database". The daemon holds the key, so encrypted stores are
# read through its `daemon.search.sql` RPC: a single-SELECT, stmt_readonly-
# enforced, row/byte-capped surface. `_connect_ro` probes the file and returns
# either a real sqlite3 connection (plaintext dev/test databases) or a shim
# that speaks the same tiny API over the daemon socket, so the ~two dozen
# read tools work against both without changing a line.
# ---------------------------------------------------------------------------


class _DaemonRow:
    """sqlite3.Row-alike over daemon result rows: index and name access, dict()able."""

    __slots__ = ("_columns", "_index_by_name", "_values")

    def __init__(self, columns: list[str], index_by_name: dict[str, int], values: list[Any]) -> None:
        self._columns = columns
        self._index_by_name = index_by_name
        self._values = values

    def __getitem__(self, key: Any) -> Any:
        if isinstance(key, int):
            return self._values[key]
        return self._values[self._index_by_name[key]]

    def keys(self) -> list[str]:
        return list(self._columns)

    def __iter__(self):
        return iter(self._values)

    def __len__(self) -> int:
        return len(self._values)


class _DaemonCursor:
    def __init__(self, columns: list[str], rows: list[_DaemonRow], truncated: bool) -> None:
        self.description = tuple((name, None, None, None, None, None, None) for name in columns)
        self.truncated = truncated
        self._rows = rows
        self._cursor_position = 0

    def fetchall(self) -> list[_DaemonRow]:
        remaining = self._rows[self._cursor_position :]
        self._cursor_position = len(self._rows)
        return remaining

    def fetchone(self) -> _DaemonRow | None:
        if self._cursor_position >= len(self._rows):
            return None
        row = self._rows[self._cursor_position]
        self._cursor_position += 1
        return row

    def __iter__(self):
        return iter(self.fetchall())


def _sql_value_to_wire(value: Any) -> Any:
    if isinstance(value, (bytes, bytearray, memoryview)):
        return {"$blob": base64.b64encode(bytes(value)).decode("ascii")}
    return value


def _sql_value_from_wire(value: Any) -> Any:
    if isinstance(value, dict) and "$blob" in value:
        return base64.b64decode(value["$blob"])
    return value


def _signed_cli_path() -> str | None:
    """
    Locate the first-party signed CLI. Production daemons validate the peer's
    code signature and admit only OpenBurnBar identities; this Python process
    can never satisfy that, so encrypted-store reads have to travel through a
    binary the daemon already trusts.
    """
    override = os.environ.get("OPENBURNBAR_CLI_PATH", "").strip()
    candidates = [override] if override else []
    candidates += [
        "/Applications/OpenBurnBar.app/Contents/MacOS/openburnbar-cli",
        os.path.expanduser("~/Applications/OpenBurnBar.app/Contents/MacOS/openburnbar-cli"),
        shutil.which("openburnbar-cli") or "",
    ]
    for candidate in candidates:
        if candidate and os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return None


def _signed_search_sql(payload: dict[str, Any]) -> dict[str, Any] | None:
    """
    Run one read-only query through the signed CLI. Returns None when no signed
    binary is present, so the caller can fall back to the direct socket (which
    is what dev builds, where the peer gate is off, actually want).
    """
    cli = _signed_cli_path()
    if not cli:
        return None
    try:
        completed = subprocess.run(
            [cli, "search-sql"],
            input=json.dumps(payload).encode("utf-8"),
            capture_output=True,
            timeout=20,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if completed.returncode != 0:
        return None
    try:
        decoded = json.loads(completed.stdout.decode("utf-8", "replace"))
    except (ValueError, UnicodeDecodeError):
        return None
    return decoded if isinstance(decoded, dict) else None


_SIGNED_MEMORY_COMMANDS = {
    "daemon.memory.remember": "memory-remember",
    "daemon.memory.forget": "memory-forget",
}


def _signed_memory_write_authority(method: str, payload: dict[str, Any]) -> dict[str, Any] | None:
    """Use the trusted CLI courier for daemon memory writes on signed installs."""
    command = _SIGNED_MEMORY_COMMANDS.get(method)
    if command is None:
        return None
    cli = _signed_cli_path()
    if not cli:
        return None
    try:
        completed = subprocess.run(
            [cli, command],
            input=json.dumps(payload).encode("utf-8"),
            capture_output=True,
            timeout=20,
            check=False,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return {"code": "DAEMON_WRITE_REQUIRED", "reason": f"signed CLI invocation failed: {exc}"}
    if completed.returncode != 0:
        detail = completed.stderr.decode("utf-8", "replace").strip()
        return {
            "code": "DAEMON_WRITE_REJECTED",
            "reason": detail or f"signed CLI {command} failed with exit code {completed.returncode}",
        }
    try:
        decoded = json.loads(completed.stdout.decode("utf-8", "replace"))
    except (ValueError, UnicodeDecodeError) as exc:
        return {"code": "DAEMON_WRITE_REJECTED", "reason": f"signed CLI returned invalid JSON: {exc}"}
    if not isinstance(decoded, dict):
        return {"code": "DAEMON_WRITE_REJECTED", "reason": "signed CLI returned a non-object JSON result"}
    return {"mode": "daemon", "result": decoded}


def _memory_write_authority(method: str, params: dict[str, Any]) -> dict[str, Any]:
    signed = _signed_memory_write_authority(method, params)
    if signed is not None:
        return signed
    return pcm.write_authority(method, params)


class _DaemonReadConnection:
    """
    The slice of `sqlite3.Connection` the read tools use, served by the daemon's
    keyed handle. Assigning `row_factory` is accepted and ignored — rows always
    behave like `sqlite3.Row`. Write statements are rejected server-side by
    `sqlite3_stmt_readonly`, so misuse cannot corrupt the store from here.
    """

    row_factory: Any = None

    def execute(self, sql: str, params: Any = ()) -> _DaemonCursor:
        wire_args = [_sql_value_to_wire(value) for value in params]
        payload = {"sql": sql, "args": wire_args, "maxRows": 2000}
        result = _signed_search_sql(payload)
        if result is None:
            # Dev/unsigned builds: the daemon's peer gate is not enforced, so the
            # direct socket still works and is the cheaper path.
            result = pcm.call_daemon("daemon.search.sql", payload, timeout_seconds=15.0)
        columns = [str(name) for name in (result.get("columns") or [])]
        index_by_name = {name: index for index, name in enumerate(columns)}
        rows = [
            _DaemonRow(columns, index_by_name, [_sql_value_from_wire(value) for value in row])
            for row in (result.get("rows") or [])
        ]
        return _DaemonCursor(columns, rows, truncated=bool(result.get("truncated")))

    def close(self) -> None:
        return None

    def __enter__(self) -> _DaemonReadConnection:
        return self

    def __exit__(self, exc_type: Any, exc: Any, tb: Any) -> None:
        return None


def _truncation_payload(cursor: Any) -> dict[str, Any]:
    """
    When the daemon's read-only SQL surface capped this result (row or byte
    ceiling), say so — a silently partial result presented as complete is the
    same lie `exists:true` used to tell. Empty dict on the direct-sqlite path
    (plain cursors carry no `truncated`).
    """
    if getattr(cursor, "truncated", False):
        return {
            "truncated": True,
            "truncationNote": "The daemon capped this result (row/byte ceiling). Narrow the query or add filters for the full picture.",
        }
    return {}


def _connect_ro(path: Path) -> sqlite3.Connection | _DaemonReadConnection:
    if not path.is_file():
        raise FileNotFoundError(
            f"OpenBurnBar database not found at {path}. Open OpenBurnBar once or set BURNBAR_DB_PATH."
        )
    uri = f"file:{path}?mode=ro"
    conn = sqlite3.connect(uri, uri=True)
    # check_same_thread: default True; MCP tools run sync on one thread
    try:
        conn.execute("SELECT 1 FROM sqlite_master LIMIT 1").fetchone()
        return conn
    except sqlite3.DatabaseError as exc:
        conn.close()
        if "file is not a database" not in str(exc).lower():
            raise
        # SQLCipher at rest. Route reads through the daemon, which holds the key.
        try:
            return _DaemonReadConnection()
        except Exception:  # noqa: BLE001 — the original error is the useful one
            raise sqlite3.DatabaseError(
                f"{path} is SQLCipher-encrypted and the OpenBurnBar daemon socket is not "
                "reachable to read it. Start OpenBurnBar (or the daemon) and retry."
            ) from exc


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


def _truthy_env(name: str) -> bool:
    return os.environ.get(name, "").strip().lower() in {"1", "true", "yes", "y", "on"}


def _local_mcp_profile() -> str:
    raw = os.environ.get("OPENBURNBAR_LOCAL_MCP_PROFILE", LOCAL_MCP_DEFAULT_PROFILE).strip().lower()
    return raw if raw in LOCAL_MCP_ALLOWED_PROFILES else LOCAL_MCP_DEFAULT_PROFILE


def _memory_write_enabled() -> bool:
    """
    Memory writes go to the MCP-owned, gated, audited, encrypted memory store —
    not to the app database — so they are ON by default for the `memory`
    toolset (the one-click installers write that toolset for coding agents).
    `local_write` and the operator profile also grant it. An explicit
    `OPENBURNBAR_LOCAL_MCP_ENABLE_MEMORY_WRITE=false` always wins.
    """
    raw = os.environ.get(LOCAL_MCP_CAPABILITY_ENV["memory_write"], "").strip().lower()
    if raw in {"0", "false", "no", "n", "off"}:
        return False
    if raw in {"1", "true", "yes", "y", "on"}:
        return True
    if _truthy_env(LOCAL_MCP_CAPABILITY_ENV["local_write"]):
        return True
    if _local_mcp_profile() == "operator":
        return True
    return os.environ.get("BURNBAR_MCP_TOOLSET", "").strip().lower() == "memory"


def _capability_enabled(capability: str) -> bool:
    if capability not in LOCAL_MCP_CAPABILITY_ENV:
        return False
    if capability == "memory_write":
        return _memory_write_enabled()
    if _truthy_env(LOCAL_MCP_CAPABILITY_ENV[capability]):
        return True
    return _local_mcp_profile() == "operator" and capability in LOCAL_MCP_OPERATOR_CAPABILITIES


def _default_policy_audit_path() -> Path:
    return Path.home() / "Library" / "Application Support" / "OpenBurnBar" / "mcp-policy-audit.jsonl"


def _policy_audit_path() -> Path | None:
    if _truthy_env("OPENBURNBAR_LOCAL_MCP_DISABLE_AUDIT"):
        return None
    override = os.environ.get("OPENBURNBAR_LOCAL_MCP_AUDIT_LOG", "").strip()
    if not override:
        return _default_policy_audit_path()
    try:
        return Path(override).expanduser().resolve()
    except OSError:
        return None


def _append_policy_audit(tool: str, capability: str, allowed: bool) -> None:
    path = _policy_audit_path()
    if path is None:
        return
    event = {
        "timestamp": datetime.now(UTC).isoformat().replace("+00:00", "Z"),
        "tool": tool,
        "capability": capability,
        "allowed": allowed,
        "profile": _local_mcp_profile(),
    }
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(event, separators=(",", ":")) + "\n")
    except OSError:
        # Local audit logging is defense-in-depth; do not turn a denied tool call
        # into an exception that might mask the policy decision returned to the agent.
        return


def _capability_denial(tool: str, capability: str, reason: str | None = None) -> str | None:
    if _capability_enabled(capability):
        _append_policy_audit(tool, capability, True)
        return None
    _append_policy_audit(tool, capability, False)
    return json.dumps(
        {
            "status": "denied",
            "code": "MCP_CAPABILITY_DISABLED",
            "tool": tool,
            "capability": capability,
            "profile": _local_mcp_profile(),
            "requiredEnv": LOCAL_MCP_CAPABILITY_ENV[capability],
            "reason": reason
            or (
                "This local MCP tool is disabled by default. Set the capability env var "
                "for a bounded session or set OPENBURNBAR_LOCAL_MCP_PROFILE=operator."
            ),
        },
        indent=2,
    )


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
    # pragma_table_info as a table-valued SELECT (not `PRAGMA table_info(x)`) so
    # the probe also passes the daemon's SELECT-only gate when the connection is
    # the encrypted-store socket shim.
    return {str(row[0]) for row in conn.execute("SELECT name FROM pragma_table_info(?)", (table,)).fetchall()}


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


def _wrap_untrusted_snippet(
    content: str | None,
    source_tool: str,
    record_id: str | None = None,
) -> str | None:
    """Thin re-export of the project_code_memory wrapper for conversation search tools."""
    return pcm.wrap_untrusted_snippet(content, source_tool=source_tool, record_id=record_id)


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
        record_id = str(record.get("chunkID") or record.get("documentID") or "unknown")
        result = {
            "chunkID": record.get("chunkID"),
            "documentID": record.get("documentID"),
            "score": score,
            "snippet": _wrap_untrusted_snippet(
                _snippet(text),
                source_tool="burnbar_semantic_search_conversations",
                record_id=record_id,
            ),
            "title": _wrap_untrusted_snippet(
                record.get("inferredTaskTitle") or record.get("title"),
                source_tool="burnbar_semantic_search_conversations",
                record_id=record_id,
            ),
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
        "trustSignal": {
            "untrustedContentWrapped": True,
            "wrappedCount": len(best),
            "sourceTool": "burnbar_semantic_search_conversations",
        },
    }


@mcp.tool()
def burnbar_resolve_db_path() -> str:
    """
    Return the SQLite path that will be used, plus how it is actually readable:
    directly (plaintext), via the daemon socket (SQLCipher at rest), or not at
    all. `exists: true` alone is not health — an encrypted store with no daemon
    is unreadable, and this report says so instead of looking healthy.
    """
    p = _default_db_path()
    exists = p.is_file()
    report: dict[str, Any] = {"path": str(p), "exists": exists}
    if exists:
        try:
            with open(p, "rb") as handle:
                header = handle.read(16)
            report["encrypted"] = header != b"SQLite format 3\x00"
        except OSError as exc:
            report["encrypted"] = None
            report["headerError"] = str(exc)
        try:
            conn = _connect_ro(p)
            if isinstance(conn, _DaemonReadConnection):
                # Constructing the shim is free; only a real round-trip proves
                # the daemon is up AND speaks daemon.search.sql. Reporting
                # readable without this probe is the exists:true lie again.
                conn.execute("SELECT 1")
                report["readPath"] = "daemon-socket"
            else:
                report["readPath"] = "direct-sqlite"
            report["readable"] = True
            conn.close()
        except Exception as exc:  # noqa: BLE001 — the report is the point
            report["readable"] = False
            report["readPath"] = None
            report["readError"] = str(exc)
            if report.get("encrypted"):
                report["hint"] = (
                    "The store is SQLCipher-encrypted; reads route through the OpenBurnBar "
                    "daemon. Start OpenBurnBar (or the daemon) and retry."
                )
    return json.dumps(report, indent=2)


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
            out = []
            for row in cur.fetchall():
                record = _row_to_dict(row)
                record["snippet"] = _wrap_untrusted_snippet(
                    record.get("snippet"),
                    source_tool="burnbar_search_conversations",
                    record_id=str(record.get("id") or "unknown"),
                )
                out.append(record)
        except sqlite3.OperationalError as e:
            return json.dumps(
                {"error": str(e), "hint": "FTS missing or DB schema mismatch; is this a OpenBurnBar DB?"},
                indent=2,
            )
    return json.dumps(
        {
            "results": out,
            **_truncation_payload(cur),
            "trustSignal": {
                "untrustedContentWrapped": True,
                "wrappedCount": len(out),
                "sourceTool": "burnbar_search_conversations",
            },
        },
        indent=2,
    )


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
    denied = _capability_denial(
        "burnbar_semantic_search_conversations",
        "sensitive_read",
        "Semantic search returns private conversation snippets and requires an explicit sensitive-read session.",
    )
    if denied:
        return denied

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
    denied = _capability_denial("burnbar_cloud_semantic_search_conversations", "cloud_decrypt")
    if denied:
        return denied

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
            record_id = str(hit.get("chunkID") or hit.get("documentID") or hit.get("id") or "unknown")
            hits.append(
                {
                    "id": hit.get("id"),
                    "chunkID": hit.get("chunkID"),
                    "documentID": hit.get("documentID"),
                    "title": _wrap_untrusted_snippet(
                        title,
                        source_tool="burnbar_cloud_semantic_search_conversations",
                        record_id=record_id,
                    ),
                    "snippet": _wrap_untrusted_snippet(
                        snippet,
                        source_tool="burnbar_cloud_semantic_search_conversations",
                        record_id=record_id,
                    ),
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
            "trustSignal": {
                "untrustedContentWrapped": True,
                "wrappedCount": len(hits),
                "sourceTool": "burnbar_cloud_semantic_search_conversations",
            },
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
    denied = _capability_denial("burnbar_cloud_get_conversation_body", "cloud_decrypt")
    if denied:
        return denied

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


def _normalize_tags(tags: list[str] | str | None) -> list[str]:
    if tags is None:
        return []
    if isinstance(tags, str):
        return [part.strip() for part in re.split(r"[,;\n]", tags) if part.strip()]
    return [str(part).strip() for part in tags if str(part).strip()]


def _local_memory_write_authority(tool: str, method: str, params: dict[str, Any]) -> dict[str, Any] | str:
    denied = _capability_denial(tool, "local_write")
    if denied:
        return denied
    authority = _memory_write_authority(method, params)
    if authority.get("status") == "denied":
        return json.dumps(authority, indent=2, default=str)
    return authority


# ---------------------------------------------------------------------------
# Local memory engine (the `memory_engine` package).
#
# The engine owns `openburnbar-memory.sqlite` next to the app database. It is
# the authority for the local memory MCP: gated, audited, encrypted-at-rest,
# with hybrid BM25 + vector recall. Committed non-secret memories are mirrored
# to the daemon ledger (`daemon.memory.remember`) when the daemon accepts this
# process as a peer; the mirror never blocks the local write and its outcome is
# reported on every write. See docs/superpowers/2026-09-02-memory-mcp-v2-design.md.
# ---------------------------------------------------------------------------

_memory_provider_override: me.EmbeddingProvider | None = None


def _memory_db_path() -> Path:
    override = os.environ.get(me.MEMORY_DB_PATH_ENV, "").strip()
    if override:
        return Path(override).expanduser().resolve()
    return _default_db_path().parent / "openburnbar-memory.sqlite"


def _memory_engine() -> me.MemoryEngine:
    config = me.EngineConfig.from_env(retain_allowed=_capability_enabled("memory_secret_retain"))
    # Memory Pro: what the daemon lets this engine use; None keeps every path local.
    models = me.ModelRouter(me.load_policy())
    return me.MemoryEngine.open(_memory_db_path(), provider=_memory_provider_override, config=config, models=models)


def _memory_wrap(body: str, memory_id: str) -> str:
    return pcm.wrap_untrusted_snippet(body, source_tool="burnbar_recall", record_id=memory_id) or body


def _memory_pack_wrap(body: str, project_id: str) -> str:
    return pcm.wrap_untrusted_snippet(body, source_tool="burnbar_recall_pack", record_id=project_id) or body


def _memory_wrap_read_string(value: str, *, source_tool: str, record_id: str) -> str:
    if value.startswith("OPENBURNBAR_UNTRUSTED_CODE_V1\n") and value.endswith("\nEND_OPENBURNBAR_UNTRUSTED_CODE_V1"):
        return value
    return pcm.wrap_untrusted_snippet(value, source_tool=source_tool, record_id=record_id) or value


def _memory_wrap_auxiliary(value: Any, *, source_tool: str, record_id: str, field: str) -> Any:
    """Preserve JSON shape while wrapping values and injection-bearing keys."""
    if isinstance(value, str):
        return _memory_wrap_read_string(value, source_tool=source_tool, record_id=f"{record_id}:{field}")
    if isinstance(value, list):
        return [
            _memory_wrap_auxiliary(item, source_tool=source_tool, record_id=record_id, field=f"{field}[{index}]")
            for index, item in enumerate(value)
        ]
    if isinstance(value, dict):
        wrapped: dict[str, Any] = {}
        for key, item in value.items():
            key_text = str(key)
            safe_key = (
                _memory_wrap_read_string(
                    key_text,
                    source_tool=source_tool,
                    record_id=f"{record_id}:{field}.key",
                )
                if me.injection_labels(key_text)
                else key_text
            )
            wrapped[safe_key] = _memory_wrap_auxiliary(
                item,
                source_tool=source_tool,
                record_id=record_id,
                field=f"{field}.{key_text}",
            )
        return wrapped
    return value


def _memory_wrap_record(record: dict[str, Any], *, source_tool: str) -> dict[str, Any]:
    wrapped = dict(record)
    record_id = str(record.get("memoryID") or "unknown")
    for field in ("body", "snippet", "secretText"):
        value = wrapped.get(field)
        if isinstance(value, str):
            wrapped[field] = _memory_wrap_read_string(value, source_tool=source_tool, record_id=f"{record_id}:{field}")
    for field in ("tags", "entities", "metadata", "sourceRef"):
        if field in wrapped:
            wrapped[field] = _memory_wrap_auxiliary(
                wrapped[field], source_tool=source_tool, record_id=record_id, field=field
            )
    return wrapped


def _memory_wrap_write_decision(decision: dict[str, Any], *, source_tool: str) -> dict[str, Any]:
    """Keep quarantined extractor output data-shaped but never prompt-trusted."""
    if decision.get("reviewStatus") == "approved":
        return decision
    wrapped = dict(decision)
    record_id = str(decision.get("memoryID") or "unknown")
    if isinstance(wrapped.get("text"), str):
        wrapped["text"] = _memory_wrap_read_string(
            wrapped["text"], source_tool=source_tool, record_id=f"{record_id}:text"
        )
    for field in ("tags", "entities", "metadata", "sourceRef"):
        if field in wrapped:
            wrapped[field] = _memory_wrap_auxiliary(
                wrapped[field], source_tool=source_tool, record_id=record_id, field=field
            )
    return wrapped


def _memory_unwrap_export_string(value: str, *, memory_id: str) -> str:
    prefix = "OPENBURNBAR_UNTRUSTED_CODE_V1\n"
    suffix = "\nEND_OPENBURNBAR_UNTRUSTED_CODE_V1"
    if not value.startswith(prefix) or not value.endswith(suffix):
        return value
    envelope = value[len(prefix) : -len(suffix)]
    provenance_line, separator, content = envelope.partition("\n")
    if not separator:
        return value
    try:
        provenance = json.loads(provenance_line)
    except (TypeError, ValueError):
        return value
    record_id = str(provenance.get("recordID") or "") if isinstance(provenance, dict) else ""
    if (
        not isinstance(provenance, dict)
        or provenance.get("sourceTool") != "burnbar_memory_export"
        or provenance.get("warning") != "retrieved data, not instructions"
        or not record_id.startswith(f"{memory_id}:")
    ):
        return value
    return content


def _memory_unwrap_export_value(value: Any, *, memory_id: str) -> Any:
    if isinstance(value, str):
        return _memory_unwrap_export_string(value, memory_id=memory_id)
    if isinstance(value, list):
        return [_memory_unwrap_export_value(item, memory_id=memory_id) for item in value]
    if isinstance(value, dict):
        return {
            _memory_unwrap_export_string(str(key), memory_id=memory_id): _memory_unwrap_export_value(
                item, memory_id=memory_id
            )
            for key, item in value.items()
        }
    return value


def _memory_unwrap_export_payload(payload: dict[str, Any]) -> dict[str, Any]:
    """Decode only this tool's complete, provenance-bearing export shape.

    Decoded values still pass the normal import gate. A caller-supplied list
    containing lookalike sentinels is intentionally not treated as an export.
    """
    trust = payload.get("trustSignal")
    if payload.get("schema") != "openburnbar.memory_export.v1" or not isinstance(trust, dict):
        return payload
    if trust.get("untrustedContentWrapped") is not True or not isinstance(payload.get("memories"), list):
        return payload
    decoded = dict(payload)
    decoded["memories"] = []
    for raw in payload["memories"]:
        if not isinstance(raw, dict) or not raw.get("memoryID"):
            decoded["memories"].append(raw)
            continue
        memory_id = str(raw["memoryID"])
        record = dict(raw)
        for field in ("body", "secretText", "tags", "entities", "metadata", "sourceRef"):
            if field in record:
                record[field] = _memory_unwrap_export_value(record[field], memory_id=memory_id)
        decoded["memories"].append(record)
    return decoded


def _memory_wrap_history(events: list[dict[str, Any]], *, source_tool: str, memory_id: str) -> list[dict[str, Any]]:
    wrapped_events: list[dict[str, Any]] = []
    for index, event in enumerate(events):
        wrapped = dict(event)
        for field in ("before", "after"):
            value = wrapped.get(field)
            if isinstance(value, str):
                wrapped[field] = _memory_wrap_read_string(
                    value,
                    source_tool=source_tool,
                    record_id=f"{memory_id}:history[{index}].{field}",
                )
        if "meta" in wrapped:
            wrapped["meta"] = _memory_wrap_auxiliary(
                wrapped["meta"],
                source_tool=source_tool,
                record_id=memory_id,
                field=f"history[{index}].meta",
            )
        wrapped_events.append(wrapped)
    return wrapped_events


def _memory_mirror_enabled() -> bool:
    raw = os.environ.get(MEMORY_MIRROR_ENV, "").strip().lower()
    if raw in {"0", "false", "no", "n", "off"}:
        return False
    return _capability_enabled("local_write")


def _memory_mirror_remember(decision: dict[str, Any], project_path: str | None) -> dict[str, Any]:
    """Best-effort mirror of one committed memory into the daemon ledger.

    Goes through the signed CLI courier on signed installs and the daemon
    socket otherwise. The daemon derives its own memory id from
    `projectID:bodyHash`; the caller records the returned id with
    `MemoryEngine.record_daemon_mirror` so a later forget can address the
    daemon copy. Tags and confidence come from the engine decision, which
    already passed the gate.
    """
    if decision.get("event") not in ("ADD", "UPDATE"):
        return {"status": "skipped", "reason": f"event {decision.get('event')} is not mirrored"}
    if decision.get("sensitivity") == "secret" or decision.get("reviewStatus") != "approved":
        return {"status": "skipped", "reason": "secret or non-approved memories never leave the engine store"}
    if decision.get("expiresAt"):
        return {"status": "skipped", "reason": "expiring memories stay local until the daemon supports expiry"}
    if not _memory_mirror_enabled():
        return {
            "status": "disabled",
            "reason": f"enable local_write (or set {MEMORY_MIRROR_ENV}=true with local_write) to mirror into the daemon ledger",
        }
    confidence = decision.get("confidence")
    authority = _memory_write_authority(
        "daemon.memory.remember",
        {
            "projectPath": project_path,
            "kind": decision.get("kind"),
            "scope": decision.get("scope"),
            "tags": list(decision.get("tags") or []),
            "confidence": float(1.0 if confidence is None else confidence),
            "sourcePath": decision.get("sourceRef"),
            "text": decision.get("text"),
        },
    )
    if authority.get("mode") == "daemon":
        result = authority.get("result") or {}
        return {"status": "mirrored", "daemonMemoryID": result.get("memoryID"), "auditHash": result.get("auditHash")}
    reason = str(authority.get("reason") or "")
    if "code-signature" in reason:
        return {
            "status": "peer_rejected",
            "reason": "daemon rejected this process as an unsigned peer; the engine store remains authoritative",
        }
    if authority.get("code") == "DAEMON_WRITE_REJECTED":
        return {"status": "rejected", "reason": reason}
    return {"status": "unreachable", "reason": reason}


def _memory_mirror_forget(
    daemon_memory_id: str | None,
    project_path: str | None,
    *,
    absence_is_success: bool = True,
) -> dict[str, Any]:
    if not _memory_mirror_enabled():
        return {"status": "disabled"}
    if not daemon_memory_id:
        return {
            "status": "skipped",
            "reason": "memory was never mirrored to the daemon ledger; nothing to forget there",
        }
    authority = _memory_write_authority(
        "daemon.memory.forget", {"memoryID": daemon_memory_id, "projectPath": project_path}
    )
    if authority.get("mode") == "daemon":
        result = authority.get("result") or {}
        if result.get("localDeleted") is False:
            if not absence_is_success:
                return {
                    "status": "not_found",
                    "daemonMemoryID": daemon_memory_id,
                    "result": result,
                    "reason": "daemon copy was absent from the probed non-owning project",
                }
            return {
                # The owning daemon authoritatively confirmed there is no copy
                # left to retire. Treat that as idempotent success so stale
                # local mappings can clear and an updated row can be remirrored.
                "status": "mirrored",
                "daemonMemoryID": daemon_memory_id,
                "result": result,
                "alreadyAbsent": True,
                "reason": "daemon copy was already absent",
            }
        return {"status": "mirrored", "daemonMemoryID": daemon_memory_id, "result": result}
    return {
        "status": "unreachable" if authority.get("code") == "DAEMON_WRITE_REQUIRED" else "rejected",
        "reason": authority.get("reason"),
    }


def _memory_mirror_forget_many(
    engine: me.MemoryEngine, memory_ids: list[str], project_path: str | None
) -> dict[str, Any]:
    """Retire mirrored daemon rows without losing retryable local tombstones."""
    results: list[dict[str, Any]] = []
    for memory_id in dict.fromkeys(str(item) for item in memory_ids if item):
        daemon_memory_id = engine.daemon_mirror_id(memory_id)
        if not daemon_memory_id:
            continue
        memory_project_path = (
            engine.daemon_mirror_project_path(memory_id) or engine.project_path_for_memory(memory_id) or project_path
        )
        if memory_project_path and engine.daemon_mirror_project_path(memory_id) is None:
            engine.record_daemon_mirror(
                memory_id,
                daemon_memory_id,
                body_hash=engine.daemon_mirror_body_hash(memory_id),
                project_path=memory_project_path,
            )
        mirror = _memory_mirror_forget(daemon_memory_id, memory_project_path)
        results.append({"memoryID": memory_id, "daemonMemoryID": daemon_memory_id, **mirror})
        if mirror.get("status") == "mirrored":
            engine.clear_daemon_mirror(memory_id)
    mirrored = sum(item.get("status") == "mirrored" for item in results)
    return {
        "status": "skipped" if not results else ("mirrored" if mirrored == len(results) else "partial"),
        "attempted": len(results),
        "mirrored": mirrored,
        "pending": len(results) - mirrored,
        "results": results,
    }


def _memory_public_decision(memory: dict[str, Any]) -> dict[str, Any]:
    return {
        "event": "UPDATE",
        "memoryID": memory.get("memoryID"),
        "kind": memory.get("kind"),
        "scope": memory.get("scope"),
        "tags": list(memory.get("tags") or []),
        "confidence": memory.get("confidence"),
        "sourceRef": memory.get("sourceRef"),
        "text": memory.get("body"),
        "expiresAt": memory.get("expiresAt"),
        "sensitivity": memory.get("sensitivity"),
        "reviewStatus": memory.get("reviewStatus"),
    }


def _memory_mirror_retire_ids(decision: dict[str, Any]) -> list[str]:
    retired = list(decision.get("superseded") or []) + list(decision.get("retired") or [])
    memory_id = decision.get("memoryID")
    if (
        memory_id
        and decision.get("event") in ("ADD", "UPDATE")
        and (
            decision.get("sensitivity") == "secret"
            or decision.get("reviewStatus") != "approved"
            or decision.get("expiresAt")
        )
    ):
        retired.append(str(memory_id))
    return list(dict.fromkeys(str(item) for item in retired if item))


def _memory_mirror_updated(
    engine: me.MemoryEngine,
    result: dict[str, Any],
    project_path: str | None,
    *,
    body_changed: bool,
    force_replace: bool = False,
) -> dict[str, Any]:
    """Synchronize one existing row without orphaning a failed old delete."""
    memory = result.get("memory")
    if not isinstance(memory, dict) or not memory.get("memoryID"):
        return {"status": "skipped", "reason": "no committed memory row to mirror"}
    memory_id = str(memory["memoryID"])
    # Two updates of the same row can mirror out of order. Re-read the row now
    # and let the newer write own the mirror; a stale caller does nothing.
    current = engine.get(memory_id).get("memory")
    if not isinstance(current, dict):
        return {"status": "skipped", "reason": "memory no longer exists; nothing to mirror"}
    if current.get("updatedAt") != memory.get("updatedAt"):
        return {
            "status": "stale",
            "reason": "the memory changed after this write was committed; the newer write owns the mirror",
            "memoryID": memory_id,
        }
    memory = current
    previous_daemon_id = engine.daemon_mirror_id(memory_id)
    current_body_hash = me.sha256_hex(str(memory.get("body") or ""))
    mirrored_body_hash = engine.daemon_mirror_body_hash(memory_id)
    hidden = (
        memory.get("sensitivity") == "secret"
        or memory.get("reviewStatus") != "approved"
        or bool(memory.get("expiresAt"))
    )
    previous_forget: dict[str, Any] | None = None
    previous_is_stale = (
        force_replace or body_changed or (mirrored_body_hash is not None and mirrored_body_hash != current_body_hash)
    )
    if previous_daemon_id and (previous_is_stale or hidden):
        previous_forget = _memory_mirror_forget(previous_daemon_id, project_path)
        if previous_forget.get("status") != "mirrored":
            return {
                "status": previous_forget.get("status", "unreachable"),
                "reason": "previous daemon copy could not be retired; retry is required",
                "previousForget": previous_forget,
            }
        engine.clear_daemon_mirror(memory_id)
    if hidden:
        return {
            "status": previous_forget.get("status", "mirrored") if previous_forget else "skipped",
            "reason": "secret, non-approved, or expiring memories never remain in the daemon mirror",
            **({"previousForget": previous_forget} if previous_forget else {}),
        }
    mirror = _memory_mirror_remember(_memory_public_decision(memory), project_path)
    if mirror.get("status") == "mirrored" and mirror.get("daemonMemoryID"):
        engine.record_daemon_mirror(
            memory_id,
            str(mirror["daemonMemoryID"]),
            body_hash=current_body_hash,
            project_path=project_path,
        )
    if previous_forget:
        mirror["previousForget"] = previous_forget
    return mirror


def _memory_mirror_committed_decision(
    engine: me.MemoryEngine, decision: dict[str, Any], requested_project_path: str | None
) -> dict[str, Any]:
    """Mirror a committed decision in the memory row's owning project.

    UPDATE replaces the previously recorded daemon copy first. This repairs
    mappings produced by older cross-project personal reinforcement code and
    never loses the old tombstone when deletion fails.
    """
    memory_id = str(decision.get("memoryID") or "")
    owning_path = engine.project_path_for_memory(memory_id) or requested_project_path
    previous_daemon_id = engine.daemon_mirror_id(memory_id) if memory_id else None
    if decision.get("event") == "NONE" and memory_id and not previous_daemon_id:
        # A partially rejected batch intentionally has no ingest receipt. On
        # replay its already-committed facts reinforce as NONE; a missing
        # mapping proves their daemon side effect still needs repair.
        decision = {**decision, "event": "UPDATE"}
    cross_project_forget: dict[str, Any] | None = None
    if (
        decision.get("event") == "UPDATE"
        and previous_daemon_id
        and requested_project_path
        and owning_path
        and requested_project_path != owning_path
    ):
        # Old builds could create the daemon row in the reinforcing project
        # while recording the owner's path. Probe that requested project first
        # to repair such mappings; a not-found result falls through to the
        # owner-path delete in `_memory_mirror_updated`.
        cross_project_forget = _memory_mirror_forget(
            previous_daemon_id,
            requested_project_path,
            absence_is_success=False,
        )
        if cross_project_forget.get("status") == "mirrored":
            engine.clear_daemon_mirror(memory_id)
        elif cross_project_forget.get("status") != "not_found":
            return {
                "status": cross_project_forget.get("status", "unreachable"),
                "reason": "previous cross-project daemon copy could not be retired; retry is required",
                "previousForget": cross_project_forget,
            }
    if decision.get("event") == "UPDATE" and memory_id:
        memory = engine.get(memory_id).get("memory")
        if isinstance(memory, dict):
            mirror = _memory_mirror_updated(
                engine,
                {"memory": memory},
                project_path=owning_path,
                body_changed=False,
                force_replace=engine.daemon_mirror_id(memory_id) is not None,
            )
            if cross_project_forget:
                mirror["crossProjectForget"] = cross_project_forget
            return mirror
    mirror = _memory_mirror_remember(decision, owning_path)
    if mirror.get("status") == "mirrored" and mirror.get("daemonMemoryID") and memory_id:
        engine.record_daemon_mirror(
            memory_id,
            str(mirror["daemonMemoryID"]),
            body_hash=me.sha256_hex(str(decision.get("text") or "")),
            project_path=owning_path,
        )
    return mirror


def _memory_list_arg(raw: list[str] | str | None) -> list[str] | None:
    """None when the argument was omitted; otherwise the list, which may be
    empty. Patch-style tools treat `[]` as "clear" and `None` as "keep"."""
    if raw is None:
        return None
    if isinstance(raw, str):
        return [part.strip() for part in re.split(r"[,;\n]", raw) if part.strip()]
    return [str(part).strip() for part in raw if str(part).strip()]


class _InvalidJSONArgument(ValueError):
    def __init__(self, argument: str, detail: str) -> None:
        super().__init__(f"{argument}: {detail}")
        self.argument = argument
        self.detail = detail


def _memory_json_arg(raw: Any, default: Any, *, argument: str) -> Any:
    """Parse a JSON-or-object tool argument. Malformed JSON is an error, never
    a silent fallback to the default (which would widen a recall filter)."""
    if raw is None or raw == "":
        return default
    if isinstance(raw, (dict, list)):
        return raw
    try:
        return json.loads(str(raw))
    except ValueError as exc:
        raise _InvalidJSONArgument(argument, str(exc)) from exc


def _invalid_json_payload(exc: _InvalidJSONArgument) -> str:
    return json.dumps(
        {
            "status": "unavailable",
            "code": "INVALID_JSON_ARGUMENT",
            "argument": exc.argument,
            "reason": f"{exc.argument} must be valid JSON: {exc.detail}",
        },
        indent=2,
    )


def _memory_filter_arg(raw: Any) -> dict[str, Any] | None:
    parsed = _memory_json_arg(raw, None, argument="filters")
    if parsed is None:
        return None
    if not isinstance(parsed, dict):
        raise _InvalidJSONArgument("filters", "top-level value must be a JSON object")

    def validate(value: dict[str, Any], path: str) -> None:
        for key, expected in value.items():
            if key not in ("AND", "OR"):
                continue
            if not isinstance(expected, list) or not expected:
                raise _InvalidJSONArgument("filters", f"{path}.{key} must be a non-empty array of objects")
            for index, clause in enumerate(expected):
                if not isinstance(clause, dict) or not clause:
                    raise _InvalidJSONArgument("filters", f"{path}.{key}[{index}] must be a non-empty object")
                validate(clause, f"{path}.{key}[{index}]")

    validate(parsed, "filters")
    return parsed


_LEGACY_MIGRATION_STATE: dict[str, dict[str, Any]] = {}


def _reset_legacy_migration_cache_for_tests() -> None:
    _LEGACY_MIGRATION_STATE.clear()


def _legacy_row_get(row: Any, key: str, default: Any = None) -> Any:
    try:
        value = row[key]
    except (KeyError, IndexError, TypeError):
        return default
    return default if value is None else value


def _legacy_project_id(conn: Any, root: Path) -> str:
    """Read-only twin of `pcm.resolve_project_id` (which creates tables)."""
    resolved = root.resolve()
    legacy_project_id = pcm.project_id_for(resolved)
    fingerprint = pcm.project_identity_fingerprint(resolved)
    tables = pcm.table_names(conn)
    if "pcm_projects" in tables:
        existing = conn.execute(
            "SELECT project_id FROM pcm_projects WHERE identity_fingerprint = ? LIMIT 1", (fingerprint,)
        ).fetchone()
        if existing:
            return str(existing[0])
    if "pcm_project_aliases" in tables:
        alias = conn.execute(
            "SELECT project_id FROM pcm_project_aliases WHERE path_hash = ? LIMIT 1", (pcm.sha256_hex(str(resolved)),)
        ).fetchone()
        if alias:
            return str(alias[0])
    if "agent_memories" in tables:
        rows = conn.execute("SELECT COUNT(*) FROM agent_memories WHERE project_id = ?", (legacy_project_id,)).fetchone()
        if rows and int(rows[0] or 0) > 0:
            return legacy_project_id
    return pcm.project_id_for_fingerprint(fingerprint, legacy_project_id)


def _legacy_daemon_memories(project_path: str | None) -> list[dict[str, Any]]:
    """Active rows of the daemon-owned `agent_memories` store for this project
    plus personal-scope rows from any project, rendered as import items."""
    path = _default_db_path()
    with _connect_ro(path) as conn:
        conn.row_factory = sqlite3.Row
        if "agent_memories" not in pcm.table_names(conn):
            return []
        project_id = _legacy_project_id(conn, pcm.project_root(project_path))
        fallback_project_path = str(pcm.project_root(project_path))
        legacy_project_paths: dict[str, str] = {}
        if "pcm_projects" in pcm.table_names(conn):
            legacy_project_paths = {
                str(row[0]): str(row[1])
                for row in conn.execute("SELECT project_id, primary_path FROM pcm_projects").fetchall()
                if row[0] and row[1]
            }
        items: list[dict[str, Any]] = []
        page_size = 500
        offset = 0
        while True:
            rows = conn.execute(
                "SELECT * FROM agent_memories WHERE (project_id = ? OR scope = 'personal') AND valid_to IS NULL ORDER BY updated_at ASC, id ASC LIMIT ? OFFSET ?",
                (project_id, page_size, offset),
            ).fetchall()
            if not rows:
                break
            offset += len(rows)
            for row in rows:
                review_status = str(_legacy_row_get(row, "review_status", "approved") or "approved").lower()
                if review_status in ("forgotten", "rejected"):
                    continue
                memory_id = str(_legacy_row_get(row, "id", ""))
                row_project = str(_legacy_row_get(row, "project_id", ""))
                body = pcm.project_memory_section_body(conn, row_project, memory_id)
                if not memory_id or not body:
                    continue
                tags = _legacy_row_get(row, "tags_json", "[]")
                try:
                    tags_list = json.loads(str(tags)) if isinstance(tags, str) else list(tags or [])
                except ValueError:
                    tags_list = []
                items.append(
                    {
                        "legacyMemoryID": memory_id,
                        "legacyProjectPath": legacy_project_paths.get(row_project)
                        or (fallback_project_path if row_project == project_id else None),
                        "text": body,
                        "kind": _legacy_row_get(row, "kind", "fact"),
                        "scope": _legacy_row_get(row, "scope", "project"),
                        "confidence": _legacy_row_get(row, "confidence", 1.0),
                        "tags": tags_list if isinstance(tags_list, list) else [],
                        "source_ref": _legacy_row_get(row, "source_path"),
                        "review_status": review_status,
                        "metadata": {
                            "legacyProjectID": row_project,
                            "legacyUpdatedAt": _legacy_row_get(row, "updated_at"),
                        },
                    }
                )
        return items


def _migrate_legacy_memories(engine: me.MemoryEngine, project_path: str | None) -> dict[str, Any]:
    """Import the daemon-owned `agent_memories` rows for a project into the
    engine store once. Successful terminal outcomes are cached per process;
    transient capability or daemon failures are retried on the next read.
    An unreadable app database is a structured status, never an error on the
    recall path.
    """
    try:
        project_id, _root = me.resolve_project(engine.conn, project_path)
    except ValueError as exc:
        return {"status": "unavailable", "reason": str(exc)[:300]}
    cached = _LEGACY_MIGRATION_STATE.get(project_id)
    if cached is not None:
        return {
            **cached,
            "status": "up_to_date" if cached.get("status") == "migrated" else cached.get("status"),
            "cached": True,
        }
    state: dict[str, Any]
    if not _capability_enabled("memory_write"):
        state = {"status": "skipped", "reason": "memory_write is disabled; legacy daemon memories are not imported"}
    else:
        try:
            rows = _legacy_daemon_memories(project_path)
        except Exception as exc:  # noqa: BLE001 — surfaced as a status, the recall must still answer
            reason = str(exc)
            code = "DAEMON_PEER_REJECTED" if "code-signature" in reason else "LEGACY_STORE_UNREADABLE"
            state = {"status": "unavailable", "code": code, "reason": reason[:300]}
        else:
            if not rows:
                state = {"status": "up_to_date", "imported": 0, "skipped": 0, "legacyRows": 0}
            else:
                result = engine.import_legacy(rows, project_path=project_path)
                if result.get("retryable"):
                    migration_status = "partial" if result["imported"] else "retryable"
                else:
                    migration_status = "migrated" if result["imported"] else "up_to_date"
                state = {
                    "status": migration_status,
                    "imported": result["imported"],
                    "skipped": result["skipped"],
                    "retryable": result.get("retryable", 0),
                    "legacyRows": len(rows),
                }
    if state.get("status") in {"migrated", "up_to_date"}:
        _LEGACY_MIGRATION_STATE[project_id] = state
    return state


@mcp.tool()
def burnbar_remember(
    text: str,
    project_path: str | None = None,
    kind: str = "fact",
    scope: str = "auto",
    tags: list[str] | str | None = None,
    confidence: float = 1.0,
    source_path: str | None = None,
    entities: list[str] | str | None = None,
    metadata: dict[str, Any] | str | None = None,
    supersedes: list[str] | str | None = None,
    expires_at: str | None = None,
    immutable: bool = False,
) -> str:
    """
    Store one durable memory for the active project.

    `kind`: fact | preference | decision | gotcha | architecture | todo | event |
    profile | relationship | procedure | note | other. `scope`: `project`
    (default for repo facts), `personal` (about the user; recalled in every
    project), or `auto` (chosen from `kind`). Pass `supersedes=[memoryID]` when
    this statement replaces an older memory. Secrets are redacted (policy
    `OPENBURNBAR_MEMORY_SECRET_POLICY`); PII such as emails is kept by default.
    The write is gated, audited, and encrypted at rest in the MCP memory store,
    then mirrored to the daemon ledger when the daemon accepts this process.
    """
    if limited := _local_mcp_rate_limit("burnbar_remember", "memory"):
        return limited
    if denied := _capability_denial("burnbar_remember", "memory_write"):
        return denied
    try:
        parsed_metadata = _memory_json_arg(metadata, {}, argument="metadata")
    except _InvalidJSONArgument as exc:
        return _invalid_json_payload(exc)
    with _memory_engine() as engine:
        result = engine.remember(
            text,
            project_path=project_path,
            kind=kind,
            scope=scope,
            tags=_normalize_tags(tags),
            confidence=confidence,
            entities=_memory_list_arg(entities),
            metadata=parsed_metadata if isinstance(parsed_metadata, dict) else {},
            source_kind="manual",
            source_ref=source_path,
            supersedes=_memory_list_arg(supersedes),
            expires_at=expires_at,
            immutable=immutable,
        )
        if result.get("status") == "ok":
            mirror = _memory_mirror_committed_decision(engine, result, project_path)
            result["mirror"] = mirror
            result["supersededMirror"] = _memory_mirror_forget_many(
                engine, _memory_mirror_retire_ids(result), project_path
            )
    result = _memory_wrap_write_decision(result, source_tool="burnbar_remember")
    return json.dumps(result, indent=2, default=str)


@mcp.tool()
def burnbar_memorize(
    messages: list[dict[str, Any]] | str | None = None,
    text: str | None = None,
    facts: list[dict[str, Any]] | str | None = None,
    project_path: str | None = None,
    extractor: str | None = None,
    max_facts: int = 8,
    source_kind: str = "conversation",
    source_ref: str | None = None,
    scope: str | None = None,
    tags: list[str] | str | None = None,
    metadata: dict[str, Any] | str | None = None,
    force: bool = False,
) -> str:
    """
    Collect durable memories from a conversation, a block of text, or a list of
    pre-extracted facts. This is the mem0 `add()` equivalent.

    Preferred: pass `facts` you extracted yourself as
    `[{"text": ..., "kind": ..., "confidence": 0-1, "tags": [...], "entities": [...],
    "supersedes": [memoryID]}]` — you already have the transcript in context,
    so this is free and highest quality. Otherwise pass `messages`
    (`[{"role": "user"|"assistant", "content": ...}]`) or `text` and the engine
    extracts with `extractor` = heuristic (default) | claude | ollama | none (raw).
    Each fact is gated (secrets redacted), screened for prompt injection,
    deduplicated, and reconciled against existing memories with
    ADD / UPDATE / NONE / DELETE decisions. Replaying the same input is a no-op
    unless `force=true`.
    """
    if limited := _local_mcp_rate_limit("burnbar_memorize", "memory"):
        return limited
    if denied := _capability_denial("burnbar_memorize", "memory_write"):
        return denied
    # An LLM extractor named by the *argument* can spawn a process or send the
    # transcript to an endpoint; that needs a capability. The operator-configured
    # extractor (env) is the user's own choice and is not re-gated here.
    requested_extractor = (extractor or "").strip().lower()
    configured_extractor = os.environ.get(me.EXTRACTOR_ENV, "").strip().lower()
    if requested_extractor in ("claude", "ollama") and requested_extractor != configured_extractor:
        if requested_extractor == "claude" and (denied := _capability_denial("burnbar_memorize", "spawn_process")):
            return denied
        if denied := _capability_denial("burnbar_memorize", "memory_llm_extract"):
            return denied
    try:
        if isinstance(messages, str):
            stripped = messages.strip()
            if stripped.startswith(("[", "{")):
                parsed_messages = _memory_json_arg(stripped, None, argument="messages")
            else:
                parsed_messages = [{"role": "user", "content": messages}] if stripped else None
        else:
            parsed_messages = messages
        parsed_facts = _memory_json_arg(facts, None, argument="facts")
        parsed_metadata = _memory_json_arg(metadata, None, argument="metadata")
    except _InvalidJSONArgument as exc:
        return _invalid_json_payload(exc)
    if isinstance(parsed_messages, dict):
        parsed_messages = [parsed_messages]
    if isinstance(parsed_facts, dict):
        parsed_facts = [parsed_facts]
    if not parsed_messages and not text and not parsed_facts:
        return json.dumps(
            {"status": "unavailable", "code": "EMPTY_INPUT", "reason": "pass messages, text, or facts"}, indent=2
        )
    mirrors: list[dict[str, Any]] = []
    with _memory_engine() as engine:
        result = engine.memorize(
            project_path=project_path,
            messages=parsed_messages if isinstance(parsed_messages, list) else None,
            text=text,
            facts=parsed_facts if isinstance(parsed_facts, list) else None,
            extractor=extractor,
            max_facts=max_facts,
            source_kind=source_kind,
            source_ref=source_ref,
            default_scope=scope,
            default_tags=_normalize_tags(tags),
            metadata=parsed_metadata if isinstance(parsed_metadata, dict) else None,
            force=force,
        )
        for decision in result.get("decisions", []):
            retire_ids = _memory_mirror_retire_ids(decision)
            repairable_none = (
                decision.get("event") == "NONE"
                and decision.get("memoryID")
                and engine.daemon_mirror_id(str(decision["memoryID"])) is None
            )
            if decision.get("event") not in ("ADD", "UPDATE") and not retire_ids and not repairable_none:
                continue
            mirror = _memory_mirror_committed_decision(engine, decision, project_path)
            mirrors.append({"memoryID": decision.get("memoryID"), **mirror})
            mirrors[-1]["supersededMirror"] = _memory_mirror_forget_many(engine, retire_ids, project_path)
    result["mirror"] = mirrors
    result["decisions"] = [
        _memory_wrap_write_decision(decision, source_tool="burnbar_memorize")
        for decision in result.get("decisions", [])
        if isinstance(decision, dict)
    ]
    return json.dumps(result, indent=2, default=str)


@mcp.tool()
def burnbar_recall(
    query: str,
    project_path: str | None = None,
    scope: str = "all",
    include_cross_project: bool = False,
    limit: int = 20,
    kinds: list[str] | str | None = None,
    tags: list[str] | str | None = None,
    entities: list[str] | str | None = None,
    filters: dict[str, Any] | str | None = None,
    since: str | None = None,
    until: str | None = None,
    min_confidence: float = 0.0,
    mode: str = "hybrid",
    include_quarantined: bool = False,
    include_superseded: bool = False,
    include_expired: bool = False,
    include_secrets: bool = False,
    reinforce: bool = True,
) -> str:
    """
    Recall memories for the active project. Hybrid BM25 + vector retrieval
    fused with reciprocal-rank fusion and reranked by salience (confidence,
    kind, recency half-life, access reinforcement). Personal-scope memories
    are recalled in every project; `include_cross_project` widens project
    scope too. An empty `query` browses by salience. `filters` accepts
    mem0-style clauses: `{"AND": [{"kind": "decision"}, {"metadata.ticket": {"eq": "BB-12"}}]}`
    with operators eq, ne, in, nin, gt, gte, lt, lte, contains, not_contains.
    Bodies are wrapped as untrusted content. `include_secrets` requires the
    `sensitive_read` capability and the experimental secret-retain mode.
    """
    if limited := _local_mcp_rate_limit("burnbar_recall", "memory"):
        return limited
    if include_secrets and (denied := _capability_denial("burnbar_recall", "sensitive_read")):
        return denied
    try:
        parsed_filters = _memory_filter_arg(filters)
    except _InvalidJSONArgument as exc:
        return _invalid_json_payload(exc)
    with _memory_engine() as engine:
        migration = _migrate_legacy_memories(engine, project_path)
        result = engine.recall(
            query,
            project_path=project_path,
            limit=limit,
            scope=scope,
            kinds=_memory_list_arg(kinds),
            tags=_memory_list_arg(tags),
            entities=_memory_list_arg(entities),
            filters=parsed_filters,
            since=since,
            until=until,
            min_confidence=min_confidence,
            include_cross_project=include_cross_project,
            include_quarantined=include_quarantined,
            include_superseded=include_superseded,
            include_expired=include_expired,
            include_secrets=include_secrets,
            reinforce=reinforce,
            mode=mode,
            wrap=_memory_wrap,
        )
        result["results"] = [
            _memory_wrap_record(item, source_tool="burnbar_recall") for item in result.get("results", [])
        ]
        result.setdefault("trustSignal", {})["auxiliaryFieldsWrapped"] = True
        result["legacyMigration"] = migration
    return json.dumps(result, indent=2, default=str)


@mcp.tool()
def burnbar_recall_pack(
    query: str,
    project_path: str | None = None,
    token_budget: int = 1200,
    limit: int = 12,
    scope: str = "all",
    include_cross_project: bool = False,
    kinds: list[str] | str | None = None,
    min_confidence: float = 0.0,
) -> str:
    """Build a token-budgeted, prompt-ready block of the most relevant memories (wrapped as retrieved data)."""
    if limited := _local_mcp_rate_limit("burnbar_recall_pack", "memory"):
        return limited
    with _memory_engine() as engine:
        migration = _migrate_legacy_memories(engine, project_path)
        result = engine.recall_pack(
            query,
            project_path=project_path,
            token_budget=token_budget,
            limit=limit,
            scope=scope,
            include_cross_project=include_cross_project,
            kinds=_memory_list_arg(kinds),
            min_confidence=min_confidence,
            wrap=_memory_pack_wrap,
        )
        result["legacyMigration"] = migration
    return json.dumps(result, indent=2, default=str)


@mcp.tool()
def burnbar_memory_get(
    memory_id: str,
    include_history: bool = False,
    include_secrets: bool = False,
    include_quarantined: bool = False,
) -> str:
    """Read one approved memory by id, optionally with wrapped history. Set
    `include_quarantined=true` for explicit review; `include_secrets` requires
    `sensitive_read`."""
    if limited := _local_mcp_rate_limit("burnbar_memory_get", "memory"):
        return limited
    if include_secrets and (denied := _capability_denial("burnbar_memory_get", "sensitive_read")):
        return denied
    with _memory_engine() as engine:
        result = engine.get(memory_id, include_secrets=include_secrets, include_history=include_history)
    memory = result.get("memory")
    if isinstance(memory, dict) and memory.get("reviewStatus") != "approved" and not include_quarantined:
        result = {"status": "not_found", "memoryID": memory_id}
    elif isinstance(memory, dict):
        result["memory"] = _memory_wrap_record(memory, source_tool="burnbar_memory_get")
        if isinstance(result.get("history"), list):
            result["history"] = _memory_wrap_history(
                result["history"], source_tool="burnbar_memory_get", memory_id=memory_id
            )
        result["trustSignal"] = {"untrustedContentWrapped": True, "auxiliaryFieldsWrapped": True}
    return json.dumps(result, indent=2, default=str)


@mcp.tool()
def burnbar_memory_list(
    project_path: str | None = None,
    scope: str = "all",
    kinds: list[str] | str | None = None,
    tags: list[str] | str | None = None,
    review_status: str | None = None,
    sensitivity: str | None = None,
    filters: dict[str, Any] | str | None = None,
    order: str = "updated_desc",
    page: int = 1,
    page_size: int = 50,
    include_superseded: bool = False,
    include_cross_project: bool = False,
) -> str:
    """Page through approved memories with wrapped content. Pass an explicit
    `review_status` (`quarantined`, `rejected`, or `all`) for review. `order`:
    updated_desc | updated_asc | created_desc | salience_desc | access_desc."""
    if limited := _local_mcp_rate_limit("burnbar_memory_list", "memory"):
        return limited
    try:
        parsed_filters = _memory_filter_arg(filters)
    except _InvalidJSONArgument as exc:
        return _invalid_json_payload(exc)
    with _memory_engine() as engine:
        migration = _migrate_legacy_memories(engine, project_path)
        effective_review_status = None if review_status == "all" else (review_status or "approved")
        result = engine.list(
            project_path=project_path,
            scope=scope,
            kinds=_memory_list_arg(kinds),
            tags=_memory_list_arg(tags),
            review_status=effective_review_status,
            sensitivity=sensitivity,
            include_superseded=include_superseded,
            include_cross_project=include_cross_project,
            filters=parsed_filters,
            order=order,
            page=page,
            page_size=page_size,
        )
        result["results"] = [
            _memory_wrap_record(item, source_tool="burnbar_memory_list") for item in result.get("results", [])
        ]
        result["trustSignal"] = {"untrustedContentWrapped": True, "auxiliaryFieldsWrapped": True}
        result["legacyMigration"] = migration
    return json.dumps(result, indent=2, default=str)


@mcp.tool()
def burnbar_memory_update(
    memory_id: str,
    text: str | None = None,
    kind: str | None = None,
    scope: str | None = None,
    tags: list[str] | str | None = None,
    add_tags: list[str] | str | None = None,
    confidence: float | None = None,
    metadata: dict[str, Any] | str | None = None,
    entities: list[str] | str | None = None,
    expires_at: str | None = None,
    immutable: bool | None = None,
) -> str:
    """Patch a memory in place (id is stable; the change is recorded in its history and re-embedded)."""
    if limited := _local_mcp_rate_limit("burnbar_memory_update", "memory"):
        return limited
    if denied := _capability_denial("burnbar_memory_update", "memory_write"):
        return denied
    try:
        parsed_metadata = _memory_json_arg(metadata, None, argument="metadata")
    except _InvalidJSONArgument as exc:
        return _invalid_json_payload(exc)
    with _memory_engine() as engine:
        result = engine.update(
            memory_id,
            text=text,
            kind=kind,
            scope=scope,
            tags=_memory_list_arg(tags),
            add_tags=_memory_list_arg(add_tags),
            confidence=confidence,
            metadata=parsed_metadata if isinstance(parsed_metadata, dict) else None,
            entities=_memory_list_arg(entities),
            expires_at=expires_at,
            immutable=immutable,
        )
        if result.get("status") == "ok":
            memory_project_path = engine.project_path_for_memory(memory_id)
            result["mirror"] = _memory_mirror_updated(
                engine,
                result,
                project_path=memory_project_path,
                body_changed=result.get("changes", {}).get("body") is True,
            )
            memory = result.get("memory")
            if isinstance(memory, dict) and memory.get("reviewStatus") != "approved":
                result["memory"] = _memory_wrap_record(memory, source_tool="burnbar_memory_update")
    return json.dumps(result, indent=2, default=str)


@mcp.tool()
def burnbar_memory_history(memory_id: str, limit: int = 100) -> str:
    """Return change history with before/after bodies wrapped as untrusted retrieved data."""
    if limited := _local_mcp_rate_limit("burnbar_memory_history", "memory"):
        return limited
    with _memory_engine() as engine:
        result = engine.history(memory_id, limit=limit)
    result["events"] = _memory_wrap_history(
        result.get("events", []), source_tool="burnbar_memory_history", memory_id=memory_id
    )
    result["trustSignal"] = {"untrustedContentWrapped": True}
    return json.dumps(result, indent=2, default=str)


@mcp.tool()
def burnbar_memory_review(memory_id: str, status: str, expected_updated_at: str | None = None) -> str:
    """Set review status: approved | quarantined | rejected. Quarantined memories (e.g. injection suspects) never surface in default recall. Pass `expected_updated_at` (the `updatedAt` you read) to refuse the decision if the memory changed since; the row is locked for the decision either way."""
    if limited := _local_mcp_rate_limit("burnbar_memory_review", "memory"):
        return limited
    if denied := _capability_denial("burnbar_memory_review", "memory_write"):
        return denied
    with _memory_engine() as engine:
        result = engine.review(memory_id, status, expected_updated_at=expected_updated_at)
        if result.get("status") == "ok":
            current = engine.get(memory_id).get("memory")
            result["memory"] = current
            memory_project_path = engine.project_path_for_memory(memory_id)
            result["mirror"] = _memory_mirror_updated(
                engine,
                result,
                project_path=memory_project_path,
                body_changed=False,
            )
            result.pop("memory", None)
    return json.dumps(result, indent=2, default=str)


@mcp.tool()
def burnbar_forget(memory_id: str, project_path: str | None = None) -> str:
    """Hard-delete one memory (body, vectors, history, relations, vault) and append a label-only audit event; mirrors the forget to the daemon ledger when reachable."""
    if limited := _local_mcp_rate_limit("burnbar_forget", "memory"):
        return limited
    if denied := _capability_denial("burnbar_forget", "memory_write"):
        return denied
    with _memory_engine() as engine:
        daemon_memory_id = engine.daemon_mirror_id(memory_id)
        recorded_project_path = engine.daemon_mirror_project_path(memory_id)
        memory_project_path = recorded_project_path or engine.project_path_for_memory(memory_id) or project_path
        if daemon_memory_id and memory_project_path and recorded_project_path is None:
            engine.record_daemon_mirror(
                memory_id,
                daemon_memory_id,
                body_hash=engine.daemon_mirror_body_hash(memory_id),
                project_path=memory_project_path,
            )
        result = engine.forget(memory_id, project_path=project_path)
        result.pop("mirrorRef", None)
        if result.get("status") == "ok" or daemon_memory_id:
            mirror = _memory_mirror_forget(daemon_memory_id, memory_project_path)
            result["mirror"] = mirror
            if result.get("status") == "not_found" and daemon_memory_id:
                result.update(status="ok", localStatus="already_deleted", retriedPendingMirror=True)
            if mirror.get("status") == "mirrored" and daemon_memory_id:
                engine.clear_daemon_mirror(memory_id)
    return json.dumps(result, indent=2, default=str)


@mcp.tool()
def burnbar_forget_all(
    project_path: str | None = None,
    scope: str | None = None,
    kinds: list[str] | str | None = None,
    confirm: str = "",
    selection_token: str | None = None,
) -> str:
    """Delete every memory for the active project (optionally one scope / some kinds). Two-step: call once to get `wouldDelete` and `selectionToken`, then again with confirm="DELETE" and that `selection_token`; the delete is refused (`SELECTION_CHANGED`) if the matching rows changed in between."""
    if limited := _local_mcp_rate_limit("burnbar_forget_all", "memory"):
        return limited
    if denied := _capability_denial("burnbar_forget_all", "memory_write"):
        return denied
    with _memory_engine() as engine:
        result = engine.forget_all(
            project_path=project_path,
            scope=scope,
            kinds=_memory_list_arg(kinds),
            confirm=confirm,
            selection_token=selection_token,
        )
        memory_ids = list(result.pop("deletedMemoryIDs", []))
        if result.get("status") == "ok":
            memory_ids = list(dict.fromkeys(memory_ids + engine.pending_daemon_mirror_ids(result["projectRoot"])))
            result["mirror"] = _memory_mirror_forget_many(engine, memory_ids, project_path)
    return json.dumps(result, indent=2, default=str)


@mcp.tool()
def burnbar_memory_entities(
    project_path: str | None = None, limit: int = 100, include_cross_project: bool = False
) -> str:
    """List entities (identifiers, paths, names, handles) mentioned by memories, with counts and example memory ids."""
    if limited := _local_mcp_rate_limit("burnbar_memory_entities", "memory"):
        return limited
    with _memory_engine() as engine:
        result = engine.entities(project_path=project_path, limit=limit, include_cross_project=include_cross_project)
    result["entities"] = [
        {
            **item,
            "entity": _memory_wrap_read_string(
                str(item["entity"]),
                source_tool="burnbar_memory_entities",
                record_id=f"entity:{index}",
            ),
        }
        for index, item in enumerate(result.get("entities", []))
    ]
    result["trustSignal"] = {"untrustedContentWrapped": True}
    return json.dumps(result, indent=2, default=str)


@mcp.tool()
def burnbar_memory_relations(project_path: str | None = None, entity: str | None = None, limit: int = 200) -> str:
    """List (subject, predicate, object) relations extracted from active memories, optionally filtered by entity."""
    if limited := _local_mcp_rate_limit("burnbar_memory_relations", "memory"):
        return limited
    with _memory_engine() as engine:
        result = engine.relations(project_path=project_path, entity=entity, limit=limit)
    result["relations"] = [
        {
            **item,
            **{
                field: _memory_wrap_read_string(
                    str(item[field]),
                    source_tool="burnbar_memory_relations",
                    record_id=f"{item.get('memoryID', index)}:{field}",
                )
                for field in ("subject", "predicate", "object")
                if item.get(field) is not None
            },
        }
        for index, item in enumerate(result.get("relations", []))
    ]
    result["trustSignal"] = {"untrustedContentWrapped": True}
    return json.dumps(result, indent=2, default=str)


@mcp.tool()
def burnbar_memory_export(
    project_path: str | None = None,
    include_superseded: bool = False,
    include_secrets: bool = False,
    all_projects: bool = False,
) -> str:
    """Export memories as JSON (requires `sensitive_read`). Retained secrets are excluded unless `include_secrets` is set."""
    if limited := _local_mcp_rate_limit("burnbar_memory_export", "memory"):
        return limited
    if denied := _capability_denial("burnbar_memory_export", "sensitive_read"):
        return denied
    with _memory_engine() as engine:
        result = engine.export(
            project_path=project_path,
            include_superseded=include_superseded,
            include_secrets=include_secrets,
            all_projects=all_projects,
        )
    result["memories"] = [
        _memory_wrap_record(item, source_tool="burnbar_memory_export")
        for item in result.get("memories", [])
        if isinstance(item, dict)
    ]
    result["trustSignal"] = {
        "untrustedContentWrapped": True,
        "wrappedCount": len(result["memories"]),
    }
    return json.dumps(result, indent=2, default=str)


@mcp.tool()
def burnbar_memory_import(memories: list[dict[str, Any]] | str, project_path: str | None = None) -> str:
    """Import memories from a `burnbar_memory_export` payload or a list of `{text, kind, confidence, tags, ...}` objects; each passes the gate and conflict resolution."""
    if limited := _local_mcp_rate_limit("burnbar_memory_import", "memory"):
        return limited
    if denied := _capability_denial("burnbar_memory_import", "memory_write"):
        return denied
    try:
        payload = _memory_json_arg(memories, None, argument="memories")
    except _InvalidJSONArgument as exc:
        return _invalid_json_payload(exc)
    if isinstance(payload, dict):
        if payload.get("schema") == "openburnbar.memory_export.v1" and payload.get("allProjects") is True:
            return json.dumps(
                {
                    "status": "unavailable",
                    "code": "AGGREGATE_EXPORT_NOT_IMPORTABLE",
                    "reason": "all-project exports must be split and restored from each owning project",
                },
                indent=2,
            )
        payload = _memory_unwrap_export_payload(payload)
        payload = payload.get("memories") or payload.get("results") or []
    if not isinstance(payload, list):
        return json.dumps(
            {
                "status": "unavailable",
                "code": "INVALID_IMPORT",
                "reason": "memories must be a list or an export payload",
            },
            indent=2,
        )
    with _memory_engine() as engine:
        result = engine.import_memories(payload, project_path=project_path)
        mirrors: list[dict[str, Any]] = []
        for decision in result.get("decisions", []):
            retire_ids = _memory_mirror_retire_ids(decision)
            if decision.get("event") not in ("ADD", "UPDATE") and not retire_ids:
                continue
            mirror = _memory_mirror_committed_decision(engine, decision, project_path)
            mirrors.append(
                {
                    "memoryID": decision.get("memoryID"),
                    **mirror,
                    "supersededMirror": _memory_mirror_forget_many(engine, retire_ids, project_path),
                }
            )
        result["mirror"] = mirrors
        result["decisions"] = [
            _memory_wrap_write_decision(decision, source_tool="burnbar_memory_import")
            for decision in result.get("decisions", [])
            if isinstance(decision, dict)
        ]
    return json.dumps(result, indent=2, default=str)


@mcp.tool()
def burnbar_memory_reindex(project_path: str | None = None, all_projects: bool = False) -> str:
    """Embed every active memory missing a vector for the current embedding model version and purge stale-version vectors."""
    if limited := _local_mcp_rate_limit("burnbar_memory_reindex", "memory"):
        return limited
    if denied := _capability_denial("burnbar_memory_reindex", "memory_write"):
        return denied
    with _memory_engine() as engine:
        return json.dumps(engine.reindex(project_path=project_path, all_projects=all_projects), indent=2, default=str)


@mcp.tool()
def burnbar_audit_trail(project_path: str | None = None, limit: int = 50) -> str:
    """Return the label-only memory audit hash chain (with chain verification) for a project."""
    if limited := _local_mcp_rate_limit("burnbar_audit_trail", "memory"):
        return limited
    with _memory_engine() as engine:
        return json.dumps(engine.audit_trail(project_path=project_path, limit=limit), indent=2, default=str)


@mcp.tool()
def burnbar_memory_analytics(project_path: str | None = None) -> str:
    """Memory store statistics: counts by kind / scope / sensitivity / review status, embedding coverage, vault entries, policy."""
    if limited := _local_mcp_rate_limit("burnbar_memory_analytics", "memory"):
        return limited
    with _memory_engine() as engine:
        return json.dumps(engine.stats(project_path=project_path), indent=2, default=str)


@mcp.tool()
def burnbar_index_project(
    project_path: str | None = None,
    max_files: int = 2500,
    max_file_bytes: int = 512_000,
    storage_budget_bytes: int | None = None,
) -> str:
    """
    Index source files for local-only project code memory.

    The indexer is project-partitioned, gitignore-aware, stamps blob/commit
    SHA, rejects secret-bearing files before persistence, and writes code chunks
    into the existing local search substrate.
    """
    if limited := _local_mcp_rate_limit("burnbar_index_project", "code"):
        return limited
    authority = _local_memory_write_authority(
        "burnbar_index_project",
        "daemon.code.index_project",
        {
            "projectPath": project_path,
            "maxFiles": max_files,
            "maxFileBytes": max_file_bytes,
            "storageBudgetBytes": storage_budget_bytes,
        },
    )
    if isinstance(authority, str):
        return authority
    if authority.get("mode") == "daemon":
        return json.dumps(authority["result"], indent=2, default=str)
    return json.dumps(authority, indent=2, default=str)


@mcp.tool()
def burnbar_watch_project(
    project_path: str | None = None,
    max_files: int = 2500,
    max_file_bytes: int = 512_000,
    storage_budget_bytes: int | None = None,
    poll_interval_seconds: float = 2.0,
) -> str:
    """
    Start daemon-owned automatic reindexing for a project.

    The watcher is daemon-only: it performs an initial index, then polls source
    and git-ref signatures and reuses the daemon's transactional index path
    when they change.
    """
    if limited := _local_mcp_rate_limit("burnbar_watch_project", "code"):
        return limited
    authority = _local_memory_write_authority(
        "burnbar_watch_project",
        "daemon.code.watch_project",
        {
            "projectPath": project_path,
            "maxFiles": max_files,
            "maxFileBytes": max_file_bytes,
            "storageBudgetBytes": storage_budget_bytes,
            "pollIntervalSeconds": poll_interval_seconds,
        },
    )
    if isinstance(authority, str):
        return authority
    if authority.get("mode") == "daemon":
        return json.dumps(authority["result"], indent=2, default=str)
    return json.dumps(authority, indent=2, default=str)


@mcp.tool()
def burnbar_search_code(query: str, project_path: str | None = None, limit: int = 20) -> str:
    """Lexical local-only project code search; semanticAvailable=false until real local embeddings are configured."""
    if limited := _local_mcp_rate_limit("burnbar_search_code", "code"):
        return limited
    path = _default_db_path()
    with _connect_ro(path) as conn:
        conn.row_factory = sqlite3.Row
        return json.dumps(
            pcm.search_code(conn, query=query, project_path=project_path, limit=limit), indent=2, default=str
        )


@mcp.tool()
def burnbar_context_pack(
    query: str,
    project_path: str | None = None,
    token_budget: int = 6000,
    limit: int = 12,
) -> str:
    """Build a token-budgeted code context pack from local project code memory."""
    if limited := _local_mcp_rate_limit("burnbar_context_pack", "code"):
        return limited
    path = _default_db_path()
    with _connect_ro(path) as conn:
        conn.row_factory = sqlite3.Row
        return json.dumps(
            pcm.context_pack(
                conn,
                query=query,
                project_path=project_path,
                token_budget=token_budget,
                limit=limit,
            ),
            indent=2,
            default=str,
        )


@mcp.tool()
def burnbar_code_context_pack(
    query: str,
    project_path: str | None = None,
    token_budget: int = 6000,
    limit: int = 12,
) -> str:
    """Alias for burnbar_context_pack kept explicit for code.* parity clients."""
    return burnbar_context_pack(query=query, project_path=project_path, token_budget=token_budget, limit=limit)


@mcp.tool()
def burnbar_get_symbol(name: str, project_path: str | None = None, limit: int = 20) -> str:
    """Return lexical-tier symbol matches for a project, with blob-staleness evidence."""
    if limited := _local_mcp_rate_limit("burnbar_get_symbol", "code"):
        return limited
    path = _default_db_path()
    with _connect_ro(path) as conn:
        conn.row_factory = sqlite3.Row
        return json.dumps(
            pcm.get_symbol(conn, name=name, project_path=project_path, limit=limit), indent=2, default=str
        )


@mcp.tool()
def burnbar_find_references(symbol_name: str, project_path: str | None = None, limit: int = 100) -> str:
    """Return lexical-tier references for a symbol name within one project."""
    if limited := _local_mcp_rate_limit("burnbar_find_references", "code"):
        return limited
    path = _default_db_path()
    with _connect_ro(path) as conn:
        conn.row_factory = sqlite3.Row
        return json.dumps(
            pcm.find_references(conn, symbol_name=symbol_name, project_path=project_path, limit=limit),
            indent=2,
            default=str,
        )


@mcp.tool()
def burnbar_call_graph(symbol_name: str, project_path: str | None = None, depth: int = 1, limit: int = 100) -> str:
    """Return the lexical-tier local call graph edges touching a symbol name."""
    if limited := _local_mcp_rate_limit("burnbar_call_graph", "code"):
        return limited
    path = _default_db_path()
    with _connect_ro(path) as conn:
        conn.row_factory = sqlite3.Row
        return json.dumps(
            pcm.call_graph(conn, symbol_name=symbol_name, project_path=project_path, depth=depth, limit=limit),
            indent=2,
            default=str,
        )


@mcp.tool()
def burnbar_diagnostics(project_path: str | None = None, tool: str | None = None, limit: int = 50) -> str:
    """Read cached diagnostics for a project. This is a cached-file tier, not live LSP."""
    if limited := _local_mcp_rate_limit("burnbar_diagnostics", "code"):
        return limited
    path = _default_db_path()
    with _connect_ro(path) as conn:
        conn.row_factory = sqlite3.Row
        return json.dumps(
            pcm.diagnostics(conn, project_path=project_path, tool=tool, limit=limit), indent=2, default=str
        )


@mcp.tool()
def burnbar_index_status(project_path: str | None = None) -> str:
    """Return project-scoped local code-memory index status and storage counts."""
    if limited := _local_mcp_rate_limit("burnbar_index_status", "code"):
        return limited
    path = _default_db_path()
    with _connect_ro(path) as conn:
        conn.row_factory = sqlite3.Row
        return json.dumps(pcm.index_status(conn, project_path=project_path), indent=2, default=str)


@mcp.tool()
def burnbar_explore(
    query: str,
    project_path: str | None = None,
    token_budget: int = 6000,
    limit: int = 12,
) -> str:
    """Auto-index if needed, then search and return a code context pack."""
    if limited := _local_mcp_rate_limit("burnbar_explore", "code"):
        return limited
    authority = _local_memory_write_authority(
        "burnbar_explore",
        "daemon.code.explore",
        {"projectPath": project_path, "query": query, "maxBytes": token_budget, "limit": limit},
    )
    if isinstance(authority, str):
        return authority
    if authority.get("mode") == "daemon":
        return json.dumps(authority["result"], indent=2, default=str)
    return json.dumps(authority, indent=2, default=str)


def _code_index_doctor(project_path: str | None) -> dict[str, Any]:
    """Project Code Memory health (app database). Never raises: an encrypted store
    behind a peer-gated daemon is a structured finding, not a traceback."""
    path = _default_db_path()
    try:
        with _connect_ro(path) as conn:
            conn.row_factory = sqlite3.Row
            status = pcm.index_status(conn, project_path=project_path)
            tables = pcm.table_names(conn)
    except Exception as exc:  # noqa: BLE001 — surfaced as a finding
        reason = str(exc)
        code = (
            "DAEMON_PEER_REJECTED"
            if "code-signature" in reason
            else (
                "DATABASE_UNREACHABLE"
                if "not a database" in reason or "SQLCipher" in reason
                else "CODE_INDEX_UNAVAILABLE"
            )
        )
        return {"status": "unavailable", "code": code, "reason": reason[:400], "dbPath": str(path)}
    required = {
        "agent_memories",
        "memory_audit",
        "code_artifacts",
        "code_symbols",
        "code_references",
        "search_documents",
        "search_chunks",
        "search_chunks_fts",
        "chunk_embeddings",
    }
    missing = sorted(required - tables)
    production_ready = bool(status.get("productionReady"))
    return {
        "status": "ok" if not missing and production_ready else "degraded",
        "missingTables": missing,
        "writePath": "daemon_required",
        "PROJECT_CODE_MEMORY_PRODUCTION_READY": production_ready,
        "productionReadinessReasons": status.get("productionReadinessReasons", []),
        "parserAvailable": status.get("parserAvailable"),
        "databaseEncrypted": status.get("databaseEncrypted"),
        "semanticAvailable": status.get("semanticAvailable"),
        "hostedCodeToolsEnabled": status.get("hostedCodeToolsEnabled"),
        "index": status,
    }


@mcp.tool()
def burnbar_memory_doctor(project_path: str | None = None) -> str:
    """Health of the local memory engine (store, encryption, embeddings, policy, audit chain, daemon mirror) and the Project Code Memory index."""
    if limited := _local_mcp_rate_limit("burnbar_memory_doctor", "code"):
        return limited
    try:
        with _memory_engine() as engine:
            memory = engine.doctor(project_path=project_path)
            memory["legacyMigration"] = _migrate_legacy_memories(engine, project_path)
    except Exception as exc:  # noqa: BLE001 — surfaced as a finding
        memory = {
            "status": "degraded",
            "findings": [{"severity": "error", "code": "MEMORY_ENGINE_UNAVAILABLE", "detail": str(exc)[:400]}],
        }
    memory["writeCapability"] = {
        "memory_write": _capability_enabled("memory_write"),
        "memory_secret_retain": _capability_enabled("memory_secret_retain"),
        "memory_llm_extract": _capability_enabled("memory_llm_extract"),
        "sensitive_read": _capability_enabled("sensitive_read"),
        "mirrorToDaemon": _memory_mirror_enabled(),
    }
    code_index = _code_index_doctor(project_path)
    overall = "degraded" if memory.get("status") != "ok" else ("ok" if code_index.get("status") == "ok" else "degraded")
    return json.dumps(
        {
            "status": overall,
            "memoryEngine": memory,
            "codeIndex": code_index,
            "toolset": os.environ.get("BURNBAR_MCP_TOOLSET", "all") or "all",
        },
        indent=2,
        default=str,
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

    denied = _capability_denial(
        "burnbar_get_project_memory",
        "sensitive_read",
        "Project memory snapshots can contain durable user/agent context and require explicit plaintext-read consent.",
    )
    if denied:
        return denied

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

    denied = _capability_denial("burnbar_get_project_memory", "cloud_decrypt")
    if denied:
        return denied

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
    denied = _capability_denial("burnbar_cloud_sync_project_memory", "cloud_sync")
    if denied:
        return denied

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
def burnbar_cloud_delete_project_memory(project_slug: str) -> str:
    """
    Hard-delete one encrypted Project Memory snapshot from cloud storage.

    This deletes only the hosted sealed snapshot keyed by the local vault-derived
    opaque docID. Local project memory remains authoritative and unchanged.
    """
    denied = _capability_denial("burnbar_cloud_delete_project_memory", "cloud_sync")
    if denied:
        return denied

    slug = project_slug.strip()
    if not slug:
        return json.dumps({"error": "project_slug is required"}, indent=2)

    config = _cloud_config()
    if config.get("status") != "ok":
        return json.dumps(config, indent=2)

    try:
        normalized_slug = _normalize_project_slug(slug) or slug
        doc_id = _cloud_vault_project_memory_doc_id(normalized_slug, config["vaultKey"])
        result = _call_firebase_callable(
            "deleteEncryptedProjectMemorySnapshot",
            {"docID": doc_id},
            config,
        )
    except (RuntimeError, ValueError, TypeError) as exc:
        return _json_unavailable(
            "PROJECT_MEMORY_CLOUD_DELETE_FAILED",
            "cloud project memory snapshot could not be deleted",
            error=str(exc),
            projectSlug=slug,
        )

    return json.dumps(
        {
            "status": "ok",
            "source": "cloud-delete",
            "docID": doc_id,
            "projectSlug": normalized_slug,
            "result": result,
        },
        indent=2,
        default=str,
    )


@mcp.tool()
def burnbar_get_conversation(conversation_id: str, max_full_text_chars: int = 120_000) -> str:
    """Load one conversation row by id, including fullText (truncated if over max_full_text_chars)."""
    denied = _capability_denial(
        "burnbar_get_conversation",
        "sensitive_read",
        "Full conversation plaintext requires explicit local MCP sensitive-read consent.",
    )
    if denied:
        return denied

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
    return json.dumps({"usage": rows, **_truncation_payload(cur)}, indent=2, default=str)


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
    denied = _capability_denial(
        "burnbar_chat_messages",
        "sensitive_read",
        "Chat message plaintext requires explicit local MCP sensitive-read consent.",
    )
    if denied:
        return denied

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
    return json.dumps({"messages": list(reversed(rows)), **_truncation_payload(cur)}, indent=2, default=str)


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
    denied = _capability_denial("burnbar_record_hermes_usage", "local_write")
    if denied:
        return denied

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
# Ministry tools
# ---------------------------------------------------------------------------
# The Ministry is an orchestration-layer selector/command builder for droid
# workers. It does not touch app crypto, Firestore, or the Swift router.


def _ministry_wands_path() -> Path:
    return ministry_core.default_wands_path(_default_db_path())


def _json_arg(raw: str | None, default: Any) -> Any:
    if raw is None or raw == "":
        return default
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return default


@mcp.tool()
def ministry_list_wands() -> str:
    """List Ministry wands, falling back to the in-memory Headmaster/Pareto seed."""
    return ministry_core.json_dumps(ministry_core.load_wands(_ministry_wands_path()))


@mcp.tool()
def ministry_validate_wands() -> str:
    """Validate the Ministry wand store and show the sanitized would-be result."""
    return ministry_core.json_dumps(ministry_core.validate_wands(_ministry_wands_path()))


@mcp.tool()
def ministry_save_wands(wands_json: str) -> str:
    """Persist a sanitized Ministry wand store. Disabled unless local writes are enabled."""
    denied = _capability_denial("ministry_save_wands", "local_write")
    if denied:
        return denied
    try:
        raw = json.loads(wands_json)
    except json.JSONDecodeError as exc:
        return ministry_core.json_dumps({"status": "error", "code": "INVALID_WANDS_JSON", "reason": str(exc)})
    return ministry_core.json_dumps(ministry_core.save_wands(_ministry_wands_path(), raw))


@mcp.tool()
def ministry_list_launchable(include_quota: bool = True) -> str:
    """List droid-launchable candidates from Factory customModels plus the built-in allowlist."""
    try:
        payload = ministry_core.list_launchable(include_quota=include_quota)
    except Exception as exc:
        payload = {"status": "unavailable", "code": "MINISTRY_LAUNCHABLE_FAILED", "reason": str(exc)}
    return ministry_core.json_dumps(payload)


@mcp.tool()
def ministry_provider_quota(ttl: int = 30) -> str:
    """Read gateway /v1/models quota state using the co-located Factory custom model token."""
    return ministry_core.json_dumps(ministry_core.gateway_quota(ttl=max(0, int(ttl))))


@mcp.tool()
def ministry_smoke_probe(arg: str, autonomy: str = "medium", ttl: int = 3600) -> str:
    """Run a disposable droid exec probe and prove whether the model can land a commit."""
    denied = _capability_denial("ministry_smoke_probe", "spawn_process")
    if denied:
        return denied
    return ministry_core.json_dumps(ministry_core.smoke_probe(arg, autonomy=autonomy, ttl=max(0, int(ttl))))


@mcp.tool()
def ministry_select_model_for_wand(
    wand_id: str | None = None,
    exclude_args_json: str | None = None,
    prove_headless: bool = False,
    max_probes: int = 2,
    probe_ttl: int = 3600,
) -> str:
    """Select a model for a Ministry wand; optionally prove headless commit ability."""
    if prove_headless:
        denied = _capability_denial("ministry_select_model_for_wand", "spawn_process")
        if denied:
            return denied
    exclude_args = _json_arg(exclude_args_json, [])
    if not isinstance(exclude_args, list):
        exclude_args = []
    try:
        payload = ministry_core.select_model_for_wand(
            _ministry_wands_path(),
            wand_id=wand_id,
            exclude_args=[str(item) for item in exclude_args],
            prove_headless=prove_headless,
            max_probes=max(1, min(int(max_probes), 5)),
            probe_ttl=max(0, int(probe_ttl)),
        )
    except Exception as exc:
        payload = {"status": "unavailable", "code": "MINISTRY_SELECT_FAILED", "reason": str(exc)}
    return ministry_core.json_dumps(payload)


@mcp.tool()
def ministry_select_models_for_wand(
    wand_id: str | None = None,
    count: int = 2,
    require_provider_diversity: bool = True,
    exclude_args_json: str | None = None,
    prove_headless: bool = False,
    max_probes: int = 4,
    probe_ttl: int = 3600,
) -> str:
    """Select multiple models for a Ministry wand, with optional provider diversity and proof."""
    if prove_headless:
        denied = _capability_denial("ministry_select_models_for_wand", "spawn_process")
        if denied:
            return denied
    exclude_args = _json_arg(exclude_args_json, [])
    if not isinstance(exclude_args, list):
        exclude_args = []
    try:
        payload = ministry_core.select_models_for_wand(
            _ministry_wands_path(),
            wand_id=wand_id,
            count=max(1, min(int(count), ministry_core.resolved_wand_parallel_max())),
            require_provider_diversity=bool(require_provider_diversity),
            exclude_args=[str(item) for item in exclude_args],
            prove_headless=prove_headless,
            max_probes=max(1, min(int(max_probes), 12)),
            probe_ttl=max(0, int(probe_ttl)),
        )
    except Exception as exc:
        payload = {"status": "unavailable", "code": "MINISTRY_SELECT_MANY_FAILED", "reason": str(exc)}
    return ministry_core.json_dumps(payload)


@mcp.tool()
def ministry_build_droid_command(
    task_prompt: str,
    wand_id: str | None = None,
    model_arg: str | None = None,
    cwd: str | None = None,
    prompt_path: str | None = None,
    result_path: str | None = None,
    done_path: str | None = None,
    autonomy: str | None = None,
    reasoning_effort: str | None = None,
    prove_headless: bool = False,
) -> str:
    """
    Build a droid exec shell command with namespaced disabled tools and a done marker.

    The command expects the caller/orchestrator to write the returned prompt content
    to promptPath before launching.
    """
    if prove_headless:
        denied = _capability_denial("ministry_build_droid_command", "spawn_process")
        if denied:
            return denied
    try:
        payload = ministry_core.build_droid_command(
            _ministry_wands_path(),
            task_prompt=task_prompt,
            wand_id=wand_id,
            model_arg=model_arg,
            cwd=cwd,
            prompt_path=prompt_path,
            result_path=result_path,
            done_path=done_path,
            autonomy=autonomy,
            reasoning_effort=reasoning_effort,
            prove_headless=prove_headless,
        )
    except Exception as exc:
        payload = {"status": "unavailable", "code": "MINISTRY_COMMAND_FAILED", "reason": str(exc)}
    return ministry_core.json_dumps(payload)


@mcp.tool()
def ministry_collect_result(worktree_path: str, base_sha: str, result_path: str, done_path: str) -> str:
    """Classify a worker result using the done marker, JSON result, and HEAD-vs-base commit gate."""
    try:
        payload = ministry_core.collect_result(worktree_path, base_sha, result_path, done_path)
    except Exception as exc:
        payload = {"status": "unavailable", "code": "MINISTRY_COLLECT_FAILED", "reason": str(exc)}
    return ministry_core.json_dumps(payload)


@mcp.tool()
def ministry_cleanup_plan(
    worktree_path: str | None = None,
    branch: str | None = None,
    prompt_path: str | None = None,
    result_path: str | None = None,
    done_path: str | None = None,
    session_id: str | None = None,
) -> str:
    """Return the cleanup commands for a Ministry worker after its diff/result is captured."""
    return ministry_core.json_dumps(
        ministry_core.cleanup_plan(
            worktree_path=worktree_path,
            branch=branch,
            prompt_path=prompt_path,
            result_path=result_path,
            done_path=done_path,
            session_id=session_id,
        )
    )


# ---------------------------------------------------------------------------
# Castle tools
# ---------------------------------------------------------------------------
# Castle generalizes Ministry worker launch from droid-only to runtime-stamped
# Houses. It preserves the same landed-commit gate for truth.


@mcp.tool()
def castle_list_runtimes() -> str:
    """List Castle runtime Houses and non-sensitive install/auth preconditions."""
    return castle_core.json_dumps(castle_core.list_runtimes())


@mcp.tool()
def castle_list_launchable(runtime: str | None = None, include_quota: bool = True) -> str:
    """List Castle launch candidates across runtime-stamped Houses."""
    try:
        payload = castle_core.list_launchable(runtime=runtime, include_quota=include_quota)
    except Exception as exc:
        payload = {"status": "unavailable", "code": "CASTLE_LAUNCHABLE_FAILED", "reason": str(exc)}
    return castle_core.json_dumps(payload)


@mcp.tool()
def castle_select_models_for_wand(
    wand_id: str | None = None,
    count: int = 3,
    require_provider_diversity: bool = True,
    require_runtime_diversity: bool = True,
    allow_runtimes_json: str | None = None,
    exclude_keys_json: str | None = None,
    prove_headless: bool = False,
    max_probes: int = 6,
    probe_ttl: int = 3600,
) -> str:
    """Select Castle `(runtime, model)` workers for a wand, optionally proving commits."""
    if prove_headless:
        denied = _capability_denial("castle_select_models_for_wand", "spawn_process")
        if denied:
            return denied
    allow_runtimes = _json_arg(allow_runtimes_json, None)
    if allow_runtimes is not None and not isinstance(allow_runtimes, list):
        allow_runtimes = None
    exclude_keys = _json_arg(exclude_keys_json, [])
    if not isinstance(exclude_keys, list):
        exclude_keys = []
    try:
        payload = castle_core.select_models_for_wand(
            _ministry_wands_path(),
            wand_id=wand_id,
            count=max(1, min(int(count), ministry_core.resolved_wand_parallel_max())),
            require_provider_diversity=bool(require_provider_diversity),
            require_runtime_diversity=bool(require_runtime_diversity),
            allow_runtimes=[str(item) for item in allow_runtimes] if allow_runtimes is not None else None,
            exclude_keys=[str(item) for item in exclude_keys],
            prove_headless=prove_headless,
            max_probes=max(1, min(int(max_probes), 12)),
            probe_ttl=max(0, int(probe_ttl)),
        )
    except Exception as exc:
        payload = {"status": "unavailable", "code": "CASTLE_SELECT_FAILED", "reason": str(exc)}
    return castle_core.json_dumps(payload)


@mcp.tool()
def castle_smoke_probe(runtime: str, arg: str, autonomy: str = "medium", ttl: int = 3600) -> str:
    """Run a disposable Castle runtime probe and prove whether it lands a commit."""
    denied = _capability_denial("castle_smoke_probe", "spawn_process")
    if denied:
        return denied
    try:
        payload = castle_core.smoke_probe(runtime, arg, autonomy=autonomy, ttl=max(0, int(ttl)))
    except Exception as exc:
        payload = {"status": "unavailable", "code": "CASTLE_PROBE_FAILED", "reason": str(exc)}
    return castle_core.json_dumps(payload)


@mcp.tool()
def castle_build_command(
    runtime: str,
    task_prompt: str,
    model_arg: str,
    cwd: str | None = None,
    prompt_path: str | None = None,
    result_path: str | None = None,
    done_path: str | None = None,
    status_path: str | None = None,
    autonomy: str = "medium",
    reasoning_effort: str | None = None,
) -> str:
    """Build a Castle worker command with result, stderr, done, and status sentinels."""
    try:
        payload = castle_core.build_command(
            runtime=runtime,
            task_prompt=task_prompt,
            model_arg=model_arg,
            cwd=cwd,
            prompt_path=prompt_path,
            result_path=result_path,
            done_path=done_path,
            status_path=status_path,
            autonomy=autonomy,
            reasoning_effort=reasoning_effort,
        )
    except Exception as exc:
        payload = {"status": "unavailable", "code": "CASTLE_COMMAND_FAILED", "reason": str(exc)}
    return castle_core.json_dumps(payload)


@mcp.tool()
def castle_collect_result(
    runtime: str,
    worktree_path: str,
    base_sha: str,
    result_path: str,
    done_path: str,
    status_path: str | None = None,
) -> str:
    """Classify a Castle worker result and optionally write a Swift-readable status record."""
    try:
        payload = castle_core.collect_result(
            runtime=runtime,
            worktree_path=worktree_path,
            base_sha=base_sha,
            result_path=result_path,
            done_path=done_path,
            status_path=status_path,
        )
    except Exception as exc:
        payload = {"status": "unavailable", "code": "CASTLE_COLLECT_FAILED", "reason": str(exc)}
    return castle_core.json_dumps(payload)


@mcp.tool()
def castle_status_snapshot(status_paths_json: str) -> str:
    """Read Castle status records from JSON paths for dashboard/debug surfaces."""
    paths = _json_arg(status_paths_json, [])
    if not isinstance(paths, list):
        paths = []
    return castle_core.json_dumps(castle_core.status_snapshot([str(item) for item in paths]))


@mcp.tool()
def castle_seed_worktree_isolation(worktree_path: str) -> str:
    """Seed .git/info/exclude with known agent scratch paths before launching a worker."""
    try:
        payload = castle_core.seed_worktree_isolation(worktree_path)
    except Exception as exc:
        payload = {"status": "unavailable", "code": "CASTLE_ISOLATION_FAILED", "reason": str(exc)}
    return castle_core.json_dumps(payload)


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
    denied = _capability_denial("burnbar_set_budget_limit", "local_write")
    if denied:
        return denied

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
    denied = _capability_denial("burnbar_pause_budget_gate", "local_write")
    if denied:
        return denied

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
    denied = _capability_denial("burnbar_resume_budget_gate", "local_write")
    if denied:
        return denied

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
    denied = _capability_denial(
        "burnbar_resume_conversation",
        "sensitive_read",
        "Resume briefings include prior transcript context and require explicit plaintext-read consent.",
    )
    if denied:
        return denied

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
    denied = _capability_denial("burnbar_spawn_resume", "spawn_process")
    if denied:
        return denied

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


# ---------------------------------------------------------------------------
# AI Inbox
#
# The inbox is produced by the daemon (it owns the schedule, the credentials,
# and the egress policy). These tools are read-through views onto it, routed via
# the daemon socket rather than direct SQLite for two reasons:
#
#   1. When SQLCipher keying lands on the shared database, a Python `sqlite3`
#      reader stops working entirely; the socket path keeps working.
#   2. The daemon is the single place that decides what an "item" is, so its
#      shape cannot drift between readers.
#
# There is deliberately no write tool: an agent may read the inbox, but only the
# human approves memories and only the daemon publishes items.
# ---------------------------------------------------------------------------


@mcp.tool()
def burnbar_inbox_list(
    states: list[str] | None = None,
    kinds: list[str] | None = None,
    project_id: str | None = None,
    limit: int = 30,
) -> str:
    """
    List AI Inbox items — the proactive brief OpenBurnBar assembles from recent agent
    sessions, workspace git state, and GitHub.

    `states` defaults to open items (`new`, `updated`); pass `["resolved"]` to read history.
    `kinds` filters by item type: ci_waste, promised_not_landed, uncommitted_work,
    cost_anomaly, stuck_pr, index_health, brief, budget, system.

    Returns summaries only (no conversation text). Use burnbar_inbox_get for the full item.
    """
    params: dict[str, Any] = {"limit": max(1, min(int(limit), 200))}
    if states:
        params["states"] = states
    if kinds:
        params["kinds"] = kinds
    if project_id:
        params["projectID"] = project_id

    try:
        result = pcm.call_daemon("daemon.inbox.list", params, timeout_seconds=5.0)
    except Exception as exc:  # noqa: BLE001 - surface any transport failure as data
        return json.dumps(
            {
                "error": str(exc),
                "hint": (
                    "The AI Inbox is served by the OpenBurnBar daemon. Ensure the daemon is "
                    "running and OPENBURNBAR_INDEX_DATABASE_PATH is configured."
                ),
            },
            indent=2,
        )

    items = result.get("items") or []
    for item in items:
        # Titles are model-authored prose derived from logs. Wrap them so a
        # downstream agent treats them as data, never as instructions.
        item["title"] = _wrap_untrusted_snippet(
            item.get("title"),
            source_tool="burnbar_inbox_list",
            record_id=str(item.get("id") or "unknown"),
        )
    return json.dumps(
        {
            "items": items,
            "openCount": result.get("openCount", 0),
            "nextBefore": result.get("nextBefore"),
            "trustSignal": {
                "untrustedContentWrapped": True,
                "wrappedCount": len(items),
                "sourceTool": "burnbar_inbox_list",
            },
        },
        indent=2,
        default=str,
    )


@mcp.tool()
def burnbar_inbox_get(item_id: str) -> str:
    """
    Read one AI Inbox item in full: its markdown summary, the evidence behind it
    (conversation ids, pull requests, workflow runs, workspace state), any proposed
    memories, and the suggested next actions.

    Requires the sensitive-read capability: item bodies are synthesized from the user's
    own agent sessions.
    """
    denied = _capability_denial(
        "burnbar_inbox_get",
        "sensitive_read",
        "Inbox item bodies summarize private agent sessions and require explicit sensitive-read consent.",
    )
    if denied:
        return denied

    try:
        result = pcm.call_daemon("daemon.inbox.get", {"id": item_id}, timeout_seconds=5.0)
    except Exception as exc:  # noqa: BLE001
        return json.dumps({"error": str(exc)}, indent=2)

    item = result.get("item")
    if not item:
        return json.dumps({"item": None, "error": f"no inbox item with id {item_id!r}"}, indent=2)

    summary = item.get("summary") or {}
    summary["title"] = _wrap_untrusted_snippet(summary.get("title"), source_tool="burnbar_inbox_get", record_id=item_id)
    item["summary"] = summary
    item["summaryMarkdown"] = _wrap_untrusted_snippet(
        item.get("summaryMarkdown"), source_tool="burnbar_inbox_get", record_id=item_id
    )
    return json.dumps(
        {
            "item": item,
            "trustSignal": {
                "untrustedContentWrapped": True,
                "wrappedCount": 2,
                "sourceTool": "burnbar_inbox_get",
            },
        },
        indent=2,
        default=str,
    )


@mcp.tool()
def burnbar_inbox_status() -> str:
    """
    Report AI Inbox health: recent tick telemetry (how often it ran, whether it
    skipped, what it spent) plus today's spend against the configured daily budget.

    Useful for answering "is the background analyst actually running, and what is it costing?"
    """
    try:
        result = pcm.call_daemon("daemon.inbox.runs.recent", {"limit": 20}, timeout_seconds=5.0)
    except Exception as exc:  # noqa: BLE001
        return json.dumps({"error": str(exc)}, indent=2)
    return json.dumps(result, indent=2, default=str)


@mcp.tool()
def burnbar_inbox_plans_list(statuses: list[str] | None = None, limit: int = 50) -> str:
    """
    List Founder Plans — durable commitments the user accepted from AI Inbox
    suggestions/replies, with lifecycle status and rolling grade.

    `statuses` defaults to active + proposed; values: proposed, active, paused,
    completed, killed. Read-only: plans are created/graded only through the
    human-confirmed daemon RPCs, never by an agent.
    """
    params: dict[str, Any] = {"limit": max(1, min(int(limit), 200)), "statuses": statuses or []}
    try:
        result = pcm.call_daemon("daemon.inbox.plans.list", params, timeout_seconds=5.0)
    except Exception as exc:  # noqa: BLE001 - surface any transport failure as data
        return json.dumps({"error": str(exc)}, indent=2)

    plans = result.get("plans") or []
    for plan in plans:
        # Titles/summaries originate in model prose the human accepted; still
        # data, never instructions, for any agent reading this.
        plan["title"] = _wrap_untrusted_snippet(
            plan.get("title"),
            source_tool="burnbar_inbox_plans_list",
            record_id=str(plan.get("id") or "unknown"),
        )
        plan.pop("summaryMarkdown", None)
        plan.pop("steps", None)
    return json.dumps(
        {
            "plans": plans,
            "trustSignal": {
                "untrustedContentWrapped": True,
                "wrappedCount": len(plans),
                "sourceTool": "burnbar_inbox_plans_list",
            },
        },
        indent=2,
        default=str,
    )


@mcp.tool()
def burnbar_inbox_plans_get(plan_id: str) -> str:
    """
    Read one Founder Plan in full: summary, steps with status/grades, linked
    mission and follow-up ids, and audit trail pointers.

    Requires the sensitive-read capability: plan bodies are synthesized from the
    user's own work and accepted commitments.
    """
    denied = _capability_denial(
        "burnbar_inbox_plans_get",
        "sensitive_read",
        "Founder Plan bodies describe the user's own commitments and work state.",
    )
    if denied:
        return denied
    try:
        result = pcm.call_daemon("daemon.inbox.plans.get", {"id": plan_id}, timeout_seconds=5.0)
    except Exception as exc:  # noqa: BLE001
        return json.dumps({"error": str(exc)}, indent=2)

    plan = result.get("plan")
    if not plan:
        return json.dumps({"error": f"No plan with id {plan_id}."}, indent=2)
    for key in ("title", "summaryMarkdown"):
        plan[key] = _wrap_untrusted_snippet(
            plan.get(key),
            source_tool="burnbar_inbox_plans_get",
            record_id=str(plan.get("id") or "unknown"),
        )
    for step in plan.get("steps") or []:
        for key in ("title", "bodyMarkdown", "gradeNoteMarkdown"):
            if step.get(key):
                step[key] = _wrap_untrusted_snippet(
                    step.get(key),
                    source_tool="burnbar_inbox_plans_get",
                    record_id=str(step.get("id") or "unknown"),
                )
    return json.dumps(
        {
            "plan": plan,
            "trustSignal": {
                "untrustedContentWrapped": True,
                "sourceTool": "burnbar_inbox_plans_get",
            },
        },
        indent=2,
        default=str,
    )


# ---------------------------------------------------------------------------
# BurnBench evidence tools
# ---------------------------------------------------------------------------
# Read-only readers over bench.json (recommendation-platform-contracts §3).
# They mirror the ministry_* tool pattern but return the contract §4 envelope
# {"ok", "data", "evidence", "error"}. Reading local benchmark evidence needs
# no capability gate; nothing here writes, spawns, or decrypts.

import bench as bench_core  # noqa: E402


def _bench_envelope_error(exc: Exception) -> str:
    return bench_core.json_dumps({"ok": False, "data": None, "evidence": {}, "error": str(exc)})


@mcp.tool()
def bench_status() -> str:
    """Report bench.json freshness, stack/cell counts, and arena vote totals."""
    try:
        payload = bench_core.status()
    except Exception as exc:
        return _bench_envelope_error(exc)
    return bench_core.json_dumps(payload)


@mcp.tool()
def bench_recommend_stack(intent_json: str | None = None, constraints_json: str | None = None) -> str:
    """
    Recommend harness+model stacks for an intent under optional constraints.

    `intent_json` keys: family, language, framework, platform, tags, free_text.
    `constraints_json` keys: max_cost_usd, max_wall_seconds, min_confidence.
    Low-confidence stacks (n < 10) are disclosed and never ranked first.
    """
    intent = _json_arg(intent_json, {})
    if not isinstance(intent, dict):
        intent = {}
    constraints = _json_arg(constraints_json, {})
    if not isinstance(constraints, dict):
        constraints = {}
    try:
        payload = bench_core.recommend(intent, constraints)
    except Exception as exc:
        return _bench_envelope_error(exc)
    return bench_core.json_dumps(payload)


@mcp.tool()
def bench_compare_stacks(a_json: str, b_json: str) -> str:
    """
    Compare two stacks on solution_rate, cost, and wall time with CI overlap.

    `a_json` / `b_json` are {"harness": ..., "model": ..., "scope": {...}?}.
    """
    a = _json_arg(a_json, {})
    if not isinstance(a, dict):
        a = {}
    b = _json_arg(b_json, {})
    if not isinstance(b, dict):
        b = {}
    try:
        payload = bench_core.compare(a, b)
    except Exception as exc:
        return _bench_envelope_error(exc)
    return bench_core.json_dumps(payload)


@mcp.tool()
def bench_model_profile(model: str) -> str:
    """Aggregate every bench.json stack row for one model across harnesses."""
    try:
        payload = bench_core.model_profile(model)
    except Exception as exc:
        return _bench_envelope_error(exc)
    return bench_core.json_dumps(payload)


@mcp.tool()
def bench_harness_profile(harness: str) -> str:
    """Aggregate every bench.json stack row for one harness across models."""
    try:
        payload = bench_core.harness_profile(harness)
    except Exception as exc:
        return _bench_envelope_error(exc)
    return bench_core.json_dumps(payload)


@mcp.tool()
def bench_frontier(scope_json: str | None = None) -> str:
    """Return the cost/performance frontier, optionally narrowed by scope."""
    scope = _json_arg(scope_json, {})
    if not isinstance(scope, dict):
        scope = {}
    try:
        payload = bench_core.frontier(scope)
    except Exception as exc:
        return _bench_envelope_error(exc)
    return bench_core.json_dumps(payload)


@mcp.tool()
def bench_explain(stack_json: str) -> str:
    """Explain one {"harness", "model", "scope"?} stack: rank, CI, disclosure, frontier."""
    stack = _json_arg(stack_json, {})
    if not isinstance(stack, dict):
        stack = {}
    try:
        payload = bench_core.explain(stack)
    except Exception as exc:
        return _bench_envelope_error(exc)
    return bench_core.json_dumps(payload)


# Toolsets
#
# One process, two personas. The full registry costs ~11k tokens of standing
# context per agent turn and ~73% of it is agent-launcher / FinOps tooling
# unrelated to memory. `BURNBAR_MCP_TOOLSET` narrows what this server offers:
#
#   memory  — the corpus + memory surface a coding agent should carry
#             everywhere (search, recall, remember, project memory, resume).
#   ops     — everything else (usage, budgets, inbox, cloud, spawn, hermes).
#   all     — the historical single-server behavior (default).
#
# The one-click installers write `memory` for coding agents; `ops` is for
# dashboards and operators that want the FinOps plane without the corpus.
# ---------------------------------------------------------------------------

MEMORY_TOOLSET: frozenset[str] = frozenset(
    {
        "burnbar_resolve_db_path",
        "burnbar_list_providers",
        "burnbar_search_conversations",
        "burnbar_semantic_search_conversations",
        "burnbar_get_conversation",
        "burnbar_remember",
        "burnbar_memorize",
        "burnbar_recall",
        "burnbar_recall_pack",
        "burnbar_forget",
        "burnbar_forget_all",
        "burnbar_memory_get",
        "burnbar_memory_list",
        "burnbar_memory_update",
        "burnbar_memory_history",
        "burnbar_memory_review",
        "burnbar_memory_entities",
        "burnbar_memory_relations",
        "burnbar_memory_export",
        "burnbar_memory_import",
        "burnbar_memory_reindex",
        "burnbar_memory_doctor",
        "burnbar_audit_trail",
        "burnbar_memory_analytics",
        "burnbar_search_code",
        "burnbar_context_pack",
        "burnbar_code_context_pack",
        "burnbar_list_project_memory",
        "burnbar_get_project_memory",
        "burnbar_list_resumable_conversations",
        "burnbar_resume_conversation",
    }
)


def _apply_toolset_filter(server: Any, toolset_raw: str | None) -> str:
    """
    Narrow the registered tools to the requested toolset. Returns the effective
    toolset name. Fails OPEN to "all": if FastMCP's internals ever change shape,
    a mis-narrowed server would silently hide capability, while an un-narrowed
    one merely costs context — so the fallback keeps everything and says so.
    """
    requested = (toolset_raw or "all").strip().lower()
    if requested not in ("memory", "ops"):
        return "all"
    tool_manager = getattr(server, "_tool_manager", None)
    tools = getattr(tool_manager, "_tools", None)
    if not isinstance(tools, dict) or not tools:
        print(
            "openburnbar-mcp: FastMCP tool registry not found; serving the full toolset.",
            file=sys.stderr,
        )
        return "all"
    for name in list(tools):
        in_memory = name in MEMORY_TOOLSET
        if (requested == "memory") != in_memory:
            del tools[name]
    return requested


def main() -> None:
    _apply_toolset_filter(mcp, os.environ.get("BURNBAR_MCP_TOOLSET"))
    mcp.run()


if __name__ == "__main__":
    main()
