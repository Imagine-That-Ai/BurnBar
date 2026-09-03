"""The SQLite store: schema, versioned migrations, connection opening, the
hash-chained audit log, and project identity."""

from __future__ import annotations

import contextlib
import os
import sqlite3
import time
from collections.abc import Sequence
from pathlib import Path
from typing import Any

import project_code_memory as pcm

from ._util import _json_dumps, _json_loads, now_iso, sha256_hex
from .constants import ENGINE_ACTOR, ENGINE_SCHEMA_VERSION, MEMORY_DB_PATH_ENV
from .crypto import secure_store_files, store_lock_path

try:
    import fcntl
except ImportError:  # pragma: no cover - POSIX only; the local MCP runs on macOS/Linux
    fcntl = None  # type: ignore[assignment]


def default_db_path() -> Path:
    override = os.environ.get(MEMORY_DB_PATH_ENV, "").strip()
    if override:
        return Path(override).expanduser().resolve()
    return Path.home() / "Library" / "Application Support" / "OpenBurnBar" / "openburnbar-memory.sqlite"


STORE_OPEN_ATTEMPTS = 25


def open_store(path: Path | str | None = None) -> sqlite3.Connection:
    db_path = Path(path) if path is not None else default_db_path()
    db_path.parent.mkdir(parents=True, exist_ok=True)
    # SQLite creates the WAL and SHM sidecars with the process umask. Narrow it
    # while the store is opened so they are born private, then pin the modes.
    previous_umask = os.umask(0o077)
    # Several MCP clients can open a brand-new store at the same moment. The
    # journal-mode switch and the schema script need exclusive access, and
    # neither honors the busy timeout, so initialization is serialized with the
    # same advisory lock the key file uses, with a bounded retry underneath it.
    lock_fd = os.open(str(store_lock_path(db_path)), os.O_RDWR | os.O_CREAT, 0o600)
    try:
        if fcntl is not None:
            fcntl.flock(lock_fd, fcntl.LOCK_EX)
        if not db_path.exists():
            os.close(os.open(str(db_path), os.O_RDWR | os.O_CREAT, 0o600))
        conn: sqlite3.Connection | None = None
        for attempt in range(STORE_OPEN_ATTEMPTS):
            candidate = sqlite3.connect(str(db_path), check_same_thread=False, timeout=10.0)
            try:
                candidate.row_factory = sqlite3.Row
                candidate.execute("PRAGMA journal_mode=WAL")
                candidate.execute("PRAGMA foreign_keys=ON")
                ensure_schema(candidate)
            except sqlite3.OperationalError as exc:
                candidate.close()
                if "locked" not in str(exc).lower() or attempt == STORE_OPEN_ATTEMPTS - 1:
                    raise
                time.sleep(0.02 * (attempt + 1))
                continue
            except BaseException:
                # Anything else (SchemaTooNew, a failed migration step) is terminal:
                # hand it up, but never leak the half-initialized connection.
                candidate.close()
                raise
            conn = candidate
            break
        assert conn is not None
    finally:
        if fcntl is not None:
            with contextlib.suppress(OSError):
                fcntl.flock(lock_fd, fcntl.LOCK_UN)
        os.close(lock_fd)
        os.umask(previous_umask)
    secure_store_files(db_path)
    return conn


SCHEMA_SQL = """
        CREATE TABLE IF NOT EXISTS engine_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS projects (
            project_id TEXT PRIMARY KEY,
            fingerprint TEXT NOT NULL,
            display_name TEXT NOT NULL,
            primary_path TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS projects_fingerprint_idx ON projects(fingerprint);
        CREATE TABLE IF NOT EXISTS memories (
            rowid INTEGER PRIMARY KEY,
            id TEXT NOT NULL UNIQUE,
            project_id TEXT NOT NULL,
            scope TEXT NOT NULL,
            kind TEXT NOT NULL,
            body_cipher BLOB NOT NULL,
            body_nonce BLOB NOT NULL,
            key_id TEXT NOT NULL,
            body_hash TEXT NOT NULL,
            sensitivity TEXT NOT NULL DEFAULT 'none',
            review_status TEXT NOT NULL DEFAULT 'approved',
            confidence REAL NOT NULL,
            salience REAL NOT NULL,
            access_count INTEGER NOT NULL DEFAULT 0,
            last_accessed_at TEXT,
            immutable INTEGER NOT NULL DEFAULT 0,
            expires_at TEXT,
            valid_from TEXT NOT NULL,
            valid_to TEXT,
            superseded_by TEXT,
            supersedes_json TEXT NOT NULL DEFAULT '[]',
            tags_json TEXT NOT NULL DEFAULT '[]',
            entities_json TEXT NOT NULL DEFAULT '[]',
            metadata_json TEXT NOT NULL DEFAULT '{}',
            source_kind TEXT NOT NULL DEFAULT 'manual',
            source_ref TEXT,
            source_hash TEXT,
            extractor TEXT NOT NULL DEFAULT 'manual',
            embedding_version TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            UNIQUE(project_id, scope, body_hash)
        );
        CREATE INDEX IF NOT EXISTS memories_project_active_idx ON memories(project_id, valid_to, review_status, updated_at);
        CREATE INDEX IF NOT EXISTS memories_scope_idx ON memories(scope, valid_to);
        CREATE TABLE IF NOT EXISTS memory_vectors (
            memory_rowid INTEGER PRIMARY KEY REFERENCES memories(rowid) ON DELETE CASCADE,
            embedding_version TEXT NOT NULL,
            dimension INTEGER NOT NULL,
            vector BLOB NOT NULL
        );
        CREATE TABLE IF NOT EXISTS memory_history (
            seq INTEGER PRIMARY KEY AUTOINCREMENT,
            memory_id TEXT NOT NULL,
            project_id TEXT NOT NULL,
            event TEXT NOT NULL,
            actor TEXT NOT NULL,
            ts TEXT NOT NULL,
            before_cipher BLOB,
            before_nonce BLOB,
            after_cipher BLOB,
            after_nonce BLOB,
            key_id TEXT NOT NULL,
            meta_json TEXT NOT NULL DEFAULT '{}'
        );
        CREATE INDEX IF NOT EXISTS memory_history_memory_idx ON memory_history(memory_id, seq);
        CREATE TABLE IF NOT EXISTS memory_relations (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            project_id TEXT NOT NULL,
            memory_id TEXT NOT NULL,
            subject TEXT NOT NULL,
            predicate TEXT NOT NULL,
            object TEXT NOT NULL,
            slot_key TEXT NOT NULL,
            confidence REAL NOT NULL DEFAULT 0.5
        );
        CREATE INDEX IF NOT EXISTS memory_relations_slot_idx ON memory_relations(project_id, slot_key);
        CREATE INDEX IF NOT EXISTS memory_relations_slotkey_idx ON memory_relations(slot_key);
        CREATE INDEX IF NOT EXISTS memory_relations_memory_idx ON memory_relations(memory_id);
        CREATE TABLE IF NOT EXISTS memory_vault (
            memory_id TEXT PRIMARY KEY,
            project_id TEXT NOT NULL,
            secret_cipher BLOB NOT NULL,
            secret_nonce BLOB NOT NULL,
            key_id TEXT NOT NULL,
            labels_json TEXT NOT NULL DEFAULT '[]',
            created_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS memory_ingest (
            source_hash TEXT PRIMARY KEY,
            project_id TEXT NOT NULL,
            ts TEXT NOT NULL,
            decisions_json TEXT NOT NULL
        );
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
        );
        """


class SchemaTooNew(RuntimeError):
    """The store carries a schema stamp this engine must not act on — newer than
    this engine, or unreadable. Refuse to touch it."""


# The version gate has to read `engine_meta` before any other DDL runs, so this
# one statement is applied on its own first. It must stay identical to the
# `engine_meta` statement in SCHEMA_SQL; a test pins the two together.
_ENGINE_META_SQL = "CREATE TABLE IF NOT EXISTS engine_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)"

# Ordered (target_version, statements). Append a step and bump ENGINE_SCHEMA_VERSION
# to the last target when the schema changes. Empty today: v1 is the first version.
# Read and patched through the module (`memory_engine.store.SCHEMA_MIGRATIONS`);
# never re-export it, or the copy stops tracking this one.
SCHEMA_MIGRATIONS: tuple[tuple[int, tuple[str, ...]], ...] = ()


def _stored_schema_version(conn: sqlite3.Connection) -> int | None:
    row = conn.execute("SELECT value FROM engine_meta WHERE key = 'schema_version'").fetchone()
    if row is None:
        return None
    try:
        return int(row[0])
    except (TypeError, ValueError) as exc:
        raise SchemaTooNew(
            f"memory store schema version {row[0]!r} is not a version this engine understands "
            f"(expected an integer no greater than {ENGINE_SCHEMA_VERSION}); "
            "upgrade OpenBurnBar or point OPENBURNBAR_MEMORY_DB_PATH at a different store"
        ) from exc


def _apply_migration(conn: sqlite3.Connection, target: int, statements: Sequence[str]) -> None:
    """One step, one transaction: its statements and its version stamp land together or not at all.

    The transaction is opened explicitly because `with conn:` does not wrap DDL
    under the driver's default isolation level — it only begins a transaction
    for DML, so a `CREATE TABLE` would commit itself and survive the rollback.
    """
    conn.execute("BEGIN")
    try:
        for statement in statements:
            conn.execute(statement)
        conn.execute("UPDATE engine_meta SET value = ? WHERE key = 'schema_version'", (str(target),))
    except BaseException:
        conn.rollback()
        raise
    conn.commit()


def ensure_schema(conn: sqlite3.Connection) -> None:
    # The version gate runs before the schema does. Creating `engine_meta` is a
    # no-op on any store that already has it, so a store written by a newer
    # engine is refused without this engine having written a byte to it.
    conn.execute(_ENGINE_META_SQL)
    current = _stored_schema_version(conn)
    if current is not None and current > ENGINE_SCHEMA_VERSION:
        raise SchemaTooNew(
            f"memory store schema version {current} is newer than this engine's {ENGINE_SCHEMA_VERSION}; "
            "upgrade OpenBurnBar or point OPENBURNBAR_MEMORY_DB_PATH at a different store"
        )
    if current is None:
        # A fresh store is bootstrapped straight to the current schema: there is
        # no older shape for a migration to move.
        conn.executescript(SCHEMA_SQL)
        conn.execute(
            "INSERT OR IGNORE INTO engine_meta(key, value) VALUES ('schema_version', ?)",
            (str(ENGINE_SCHEMA_VERSION),),
        )
        # The insert above opened an implicit write transaction; end it so a freshly
        # opened store does not hold the write lock until its first commit.
        conn.commit()
        return
    # An existing store migrates first. Applying SCHEMA_SQL ahead of the steps
    # would create, outside any step's transaction, the very objects a pending
    # step is written to create -- the step would then collide with DDL that was
    # never its own, and the leaked DDL would survive its rollback.
    for target, statements in SCHEMA_MIGRATIONS:
        if target <= current:
            continue
        _apply_migration(conn, target, statements)
        current = target
    # Last, as validation: every statement is IF NOT EXISTS, so this is a no-op
    # on a migrated store and restores anything a pre-versioning store lacks.
    conn.executescript(SCHEMA_SQL)


def audit_event(
    conn: sqlite3.Connection,
    *,
    action: str,
    project_id: str | None,
    subject_id: str | None,
    labels: Sequence[str] | None = None,
    actor: str = ENGINE_ACTOR,
    domain: str = "memory",
) -> str:
    # The chain head is read while holding the write lock. Otherwise two
    # connections can read the same head and the later insert carries a hash
    # computed for the other connection's sequence number, breaking the chain.
    if not conn.in_transaction:
        conn.execute("BEGIN IMMEDIATE")
    row = conn.execute("SELECT seq, hash FROM memory_audit ORDER BY seq DESC LIMIT 1").fetchone()
    prev_hash = str(row["hash"]) if row else ""
    seq = int(row["seq"]) + 1 if row else 1
    ts = now_iso()
    labels_sorted = sorted(set(labels or []))
    core = {
        "schema": "openburnbar.memory_audit.v2",
        "seq": seq,
        "ts": ts,
        "actor": actor,
        "action": action,
        "domain": domain,
        "projectID": project_id,
        "subjectID": subject_id,
        "labels": labels_sorted,
        "prevHash": prev_hash,
    }
    digest = sha256_hex(_json_dumps(core))
    conn.execute(
        "INSERT INTO memory_audit (ts, actor, action, domain, project_id, subject_id, labels_json, prev_hash, hash) VALUES (?,?,?,?,?,?,?,?,?)",
        (ts, actor, action, domain, project_id, subject_id, _json_dumps(labels_sorted), prev_hash or None, digest),
    )
    return digest


def verify_audit_chain(conn: sqlite3.Connection) -> dict[str, Any]:
    rows = conn.execute("SELECT * FROM memory_audit ORDER BY seq ASC").fetchall()
    prev = ""
    for row in rows:
        core = {
            "schema": "openburnbar.memory_audit.v2",
            "seq": int(row["seq"]),
            "ts": row["ts"],
            "actor": row["actor"],
            "action": row["action"],
            "domain": row["domain"],
            "projectID": row["project_id"],
            "subjectID": row["subject_id"],
            "labels": _json_loads(row["labels_json"], []),
            "prevHash": prev,
        }
        if sha256_hex(_json_dumps(core)) != row["hash"] or (row["prev_hash"] or "") != prev:
            return {"ok": False, "events": len(rows), "brokenAtSeq": int(row["seq"])}
        prev = str(row["hash"])
    return {"ok": True, "events": len(rows), "brokenAtSeq": None}


def resolve_project(conn: sqlite3.Connection, project_path: str | None) -> tuple[str, Path]:
    root = pcm.project_root(project_path)
    fingerprint = pcm.project_identity_fingerprint(root)
    project_id = pcm.project_id_for_fingerprint(fingerprint, pcm.project_id_for(root))
    # Read paths (recall, list, stats) resolve the project too. Only write when
    # something changed, so a read never opens a write transaction that would
    # hold the store's lock against another process until the connection closes.
    existing = conn.execute(
        "SELECT fingerprint, display_name, primary_path FROM projects WHERE project_id = ?", (project_id,)
    ).fetchone()
    if existing is not None and (str(existing[0]), str(existing[1]), str(existing[2])) == (
        fingerprint,
        root.name,
        str(root),
    ):
        return project_id, root
    ts = now_iso()
    conn.execute(
        """
        INSERT INTO projects (project_id, fingerprint, display_name, primary_path, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(project_id) DO UPDATE SET
            fingerprint = excluded.fingerprint,
            display_name = excluded.display_name,
            primary_path = excluded.primary_path,
            updated_at = excluded.updated_at
        """,
        (project_id, fingerprint, root.name, str(root), ts, ts),
    )
    conn.commit()
    return project_id, root


def project_payload(project_id: str, root: Path) -> dict[str, str]:
    return {"projectID": project_id, "projectRoot": str(root), "projectName": root.name}
