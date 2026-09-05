"""The SQLite store: schema, versioned migrations, connection opening, the
hash-chained audit log, and project identity."""

from __future__ import annotations

import contextlib
import os
import re
import sqlite3
import sys
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
        -- `timeline()` reads the newest `memory.recall_serve` row to answer
        -- "last helped". Additive, so no `ENGINE_SCHEMA_VERSION` bump: an index
        -- is created by `ensure_schema` on every open, old stores included.
        CREATE INDEX IF NOT EXISTS memory_audit_action_idx ON memory_audit(action, seq DESC);
        CREATE TABLE IF NOT EXISTS sync_state (
            user_id TEXT PRIMARY KEY,
            applied_updated_at TEXT NOT NULL,
            applied_memory_id TEXT NOT NULL,
            applied_count INTEGER NOT NULL DEFAULT 0,
            merged_at TEXT NOT NULL
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
# to the last target when the schema changes. v1 is the first version.
# Read and patched through the module (`memory_engine.store.SCHEMA_MIGRATIONS`);
# never re-export it, or the copy stops tracking this one.
#
# v2 — Memory Blind Sync (docs/superpowers/specs/2026-09-03-memory-blind-sync-design.md
# §5): `sync_state` carries the applied high-water mark of the merge, one row per
# member, so a re-offered batch is recognised as already applied. Deliberately not
# IF NOT EXISTS: `SCHEMA_SQL` runs after the steps as a validation pass, and a step
# that silently no-ops would hide a store this migration failed to move.
SCHEMA_MIGRATIONS: tuple[tuple[int, tuple[str, ...]], ...] = (
    (
        2,
        (
            "CREATE TABLE sync_state ("
            "user_id TEXT PRIMARY KEY, applied_updated_at TEXT NOT NULL, applied_memory_id TEXT NOT NULL, "
            "applied_count INTEGER NOT NULL DEFAULT 0, merged_at TEXT NOT NULL)",
        ),
    ),
)


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


def _engine_schema_shape() -> dict[str, frozenset[str]]:
    """What this engine's own `SCHEMA_SQL` declares: table -> column names.

    Built by running the script against a throwaway in-memory database rather
    than by parsing it, so the answer is exactly what SQLite would make of it.
    """
    probe = sqlite3.connect(":memory:")
    try:
        probe.executescript(SCHEMA_SQL)
        for _target, statements in SCHEMA_MIGRATIONS:
            for statement in statements:
                with contextlib.suppress(sqlite3.OperationalError):
                    probe.execute(statement)
        shape: dict[str, frozenset[str]] = {}
        for row in probe.execute("SELECT name FROM sqlite_master WHERE type = 'table'").fetchall():
            table = str(row[0])
            if table.startswith("sqlite_"):
                continue
            shape[table] = frozenset(str(col[1]) for col in probe.execute(f"PRAGMA table_info({table})").fetchall())
        return shape
    finally:
        probe.close()


def _newer_store_is_additive_only(conn: sqlite3.Connection) -> list[str]:
    """Whether a store stamped newer than this engine still contains everything
    this engine reads. Returns the list of missing objects — empty means the
    newer schema only ADDED things, which this engine can safely ignore.
    """
    present: dict[str, frozenset[str]] = {}
    for row in conn.execute("SELECT name FROM sqlite_master WHERE type = 'table'").fetchall():
        table = str(row[0])
        if table.startswith("sqlite_"):
            continue
        present[table] = frozenset(str(col[1]) for col in conn.execute(f"PRAGMA table_info({table})").fetchall())
    missing: list[str] = []
    for table, columns in sorted(_engine_schema_shape().items()):
        if table not in present:
            missing.append(table)
            continue
        for column in sorted(columns - present[table]):
            missing.append(f"{table}.{column}")
    return missing


def ensure_schema(conn: sqlite3.Connection) -> None:
    # The version gate runs before the schema does. Creating `engine_meta` is a
    # no-op on any store that already has it, so a store written by a newer
    # engine is inspected without this engine having written a byte to it.
    conn.execute(_ENGINE_META_SQL)
    current = _stored_schema_version(conn)
    if current is not None and current > ENGINE_SCHEMA_VERSION:
        # A newer engine wrote this store. Refusing outright is what makes a
        # revert of an engine bump BRICK the store rather than degrade it — the
        # member's whole memory surface fails at open, which is far worse than
        # the newer engine's extra objects going unread. So the refusal is
        # narrowed to the case that actually justifies it: something this engine
        # NEEDS is gone. A schema that only added tables or columns is one this
        # engine can still read every byte of, so it warns and continues, and it
        # deliberately does NOT re-stamp the version down or run the migration
        # steps — the store keeps its newer stamp and the newer engine can take
        # it back unharmed.
        missing = _newer_store_is_additive_only(conn)
        if missing:
            raise SchemaTooNew(
                f"memory store schema version {current} is newer than this engine's {ENGINE_SCHEMA_VERSION} "
                f"and removed objects this engine reads ({', '.join(missing[:8])}); "
                "upgrade OpenBurnBar or point OPENBURNBAR_MEMORY_DB_PATH at a different store"
            )
        print(
            f"openburnbar-memory: store schema version {current} is newer than this engine's "
            f"{ENGINE_SCHEMA_VERSION}; the extra objects are additive and are ignored",
            file=sys.stderr,
        )
        conn.commit()
        return
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


# The shape `pcm.project_id_for` and `pcm.project_id_for_fingerprint` mint, and
# therefore the only shape anything may be adopted under. A `.burnbar/project-id`
# in a repository is content an attacker who can get a clone onto this machine
# controls: unvalidated, it reached plaintext `engine_meta` verbatim and reached
# the calling agent's context as a command to run. Nothing that fails this
# pattern is a project id, and nothing that fails it is ever stored, echoed or
# adopted.
PROJECT_ID_RE = re.compile(r"^proj_[0-9a-f]{32}$")

# A project id is 37 bytes. Reading more than this from a repository file is
# reading an attacker's payload, so the probe stops well before it.
PROJECT_DOTFILE_MAX_BYTES = 256


def is_project_id(value: str | None) -> bool:
    return bool(value) and PROJECT_ID_RE.match(str(value)) is not None


def read_project_dotfile(root: Path) -> tuple[str | None, str | None]:
    """`(valid project id, sha256 of what was actually there)` for `.burnbar/project-id`.

    **Reads. Writes nothing, ever.** `resolve_project` runs on every recall,
    list, stat, timeline and doctor call: a write here left an uncommitted
    INSERT — and with it a RESERVED lock held for the life of the connection —
    across every read the engine performs, blocking the daemon and the app from
    writing the shared store. The dotfile is a *proposal*; only `adopt_project`
    acts on one, and only with an explicit confirmation.

    The hash is returned so a malformed file can be reported without any of its
    content being echoed anywhere.
    """
    dotfile = root / ".burnbar" / "project-id"
    try:
        if not dotfile.is_file():
            return None, None
        with dotfile.open("rb") as handle:
            raw = handle.read(PROJECT_DOTFILE_MAX_BYTES + 1)
    except OSError:
        return None, None
    digest = sha256_hex(raw)
    if len(raw) > PROJECT_DOTFILE_MAX_BYTES:
        return None, digest
    try:
        candidate = raw.decode("utf-8").strip()
    except UnicodeDecodeError:
        return None, digest
    return (candidate if is_project_id(candidate) else None), digest


def map_project(conn: sqlite3.Connection, project_path: str | Path | None, project_id: str) -> None:
    """Write the explicit folder → project mapping `resolve_project` reads first.

    Internal to `adopt_project`, and deliberately not re-exported: mapping a
    folder re-scopes every memory written there, so the only way to reach it is
    through the confirmation `adopt_project` requires (A4).
    """
    # `pcm.project_root` already expands and resolves; this is the canonical form.
    root = pcm.project_root(project_path)
    canonical_path = str(root)
    path_hash = sha256_hex(canonical_path)
    ts = now_iso()
    conn.execute(
        "INSERT OR REPLACE INTO engine_meta (key, value) VALUES (?, ?)",
        (f"project_map:{path_hash}", project_id),
    )
    conn.execute(
        "INSERT OR REPLACE INTO engine_meta (key, value) VALUES (?, ?)",
        (f"project_map:{canonical_path}", project_id),
    )
    tables = pcm.table_names(conn)
    if "pcm_projects" in tables:
        # `pcm_project_aliases.project_id` is a foreign key into `pcm_projects`,
        # and an adopted id is one the daemon-shared store may never have seen.
        # `INSERT OR IGNORE`, so a project that already has a git identity keeps
        # it — `pcm.resolve_project_id`'s own guard does the same.
        conn.execute(
            """
            INSERT OR IGNORE INTO pcm_projects
                (project_id, identity_version, identity_fingerprint, project_name, primary_path, created_at, updated_at)
            VALUES (?, 2, ?, ?, ?, ?, ?)
            """,
            (project_id, f"explicit:{project_id}", root.name, canonical_path, ts, ts),
        )
    if "pcm_project_aliases" in tables:
        conn.execute(
            """
            INSERT INTO pcm_project_aliases (id, project_id, alias_path, path_hash, first_seen_at, last_seen_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(path_hash) DO UPDATE SET
                project_id = excluded.project_id,
                alias_path = excluded.alias_path,
                last_seen_at = excluded.last_seen_at
            """,
            ("alias_" + sha256_hex(path_hash)[:32], project_id, canonical_path, path_hash, ts, ts),
        )
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
        (project_id, f"explicit:{project_id}", root.name, canonical_path, ts, ts),
    )
    conn.commit()


def adopt_project(
    conn: sqlite3.Connection,
    project_path: str | Path | None = None,
    project_id: str | None = None,
    *,
    confirmed: bool = False,
) -> dict[str, Any]:
    """Adopt a project ID for a folder path.

    A dotfile naming an ID this device does not already map requires confirmation;
    `project adopt <id>` prints the ID and the memories it would join and requires
    an explicit confirmation. A dotfile naming an ID already mapped to that path
    is a no-op.
    """
    # `pcm.project_root` already expands and resolves; this is the canonical form.
    root = pcm.project_root(project_path)
    canonical_path = str(root)
    path_hash = sha256_hex(canonical_path)

    target_id = project_id
    from_dotfile = False
    if not target_id:
        target_id, _digest = read_project_dotfile(root)
        from_dotfile = target_id is not None
        if target_id is None:
            raise ValueError(
                "No project ID specified, and .burnbar/project-id is absent or is not a project id "
                "(expected proj_ followed by 32 hex characters)."
            )
    # Validated BEFORE anything is written. `target_id` becomes
    # `projects.project_id`, `pcm_project_aliases.project_id`, two `project_map:*`
    # keys and the `project_id` of every subsequent write in this folder; when it
    # came from the dotfile it is content a cloned repository controls.
    if not is_project_id(target_id):
        raise ValueError(
            f"{'.burnbar/project-id' if from_dotfile else 'project_id'} is not a project id: "
            "expected proj_ followed by 32 hex characters."
        )

    existing_map = conn.execute(
        "SELECT value FROM engine_meta WHERE key = ? OR key = ?",
        (f"project_map:{path_hash}", f"project_map:{canonical_path}"),
    ).fetchone()
    current_mapped_id: str | None = None
    if existing_map is not None:
        current_mapped_id = str(existing_map[0])
    elif "pcm_project_aliases" in pcm.table_names(conn):
        alias = conn.execute(
            "SELECT project_id FROM pcm_project_aliases WHERE path_hash = ? LIMIT 1",
            (path_hash,),
        ).fetchone()
        if alias is not None:
            current_mapped_id = str(alias[0])

    if current_mapped_id == target_id:
        return {
            "status": "ok",
            "event": "NONE",
            "reason": "already_mapped",
            "projectID": target_id,
            "path": canonical_path,
        }

    # Both sides of the trade, because adoption is not additive. `memoriesCount`
    # is what joins; `detachingCount` is what this folder already holds under
    # its current identity — those rows are NOT rewritten and NOT aliased, so
    # after adoption the folder's own history is no longer visible from it.
    # Silence about that half was a split-brain the member was never shown.
    detaching_id = current_mapped_id or resolve_project(conn, canonical_path)[0]
    memories_count = 0
    detaching_count = 0
    if "memories" in pcm.table_names(conn):
        count_row = conn.execute("SELECT COUNT(*) FROM memories WHERE project_id = ?", (target_id,)).fetchone()
        if count_row:
            memories_count = int(count_row[0])
        if detaching_id != target_id:
            detach_row = conn.execute("SELECT COUNT(*) FROM memories WHERE project_id = ?", (detaching_id,)).fetchone()
            if detach_row:
                detaching_count = int(detach_row[0])

    if not confirmed:
        return {
            "status": "confirmation_required",
            "projectID": target_id,
            "detachingProjectID": detaching_id,
            "path": canonical_path,
            "memoriesCount": memories_count,
            "detachingCount": detaching_count,
            "message": (
                f"Adopting project '{target_id}' for path '{canonical_path}' will join "
                f"{memories_count} existing memories, and will detach the {detaching_count} memories this "
                f"folder holds under '{detaching_id}': they are left where they are, unaliased, and stop "
                "being visible from here. Explicit confirmation required."
            ),
        }

    map_project(conn, root, target_id)
    # Nothing writes this key any more (see `resolve_project`); the delete stays
    # so a store stamped by an earlier build does not keep a stale proposal.
    conn.execute(
        "DELETE FROM engine_meta WHERE key = ?",
        (f"pending_project_adoption:{path_hash}",),
    )
    conn.commit()

    return {
        "status": "ok",
        "event": "ADOPTED",
        "projectID": target_id,
        "detachingProjectID": detaching_id,
        "path": canonical_path,
        "memoriesCount": memories_count,
        "detachingCount": detaching_count,
    }


def resolve_project(conn: sqlite3.Connection, project_path: str | None) -> tuple[str, Path]:
    # `pcm.project_root` already expands and resolves; this is the canonical form.
    root = pcm.project_root(project_path)
    canonical_path = str(root)
    path_hash = sha256_hex(canonical_path)

    project_id: str | None = None
    fingerprint: str | None = None

    # 1. Explicit map
    row = conn.execute(
        "SELECT value FROM engine_meta WHERE key = ? OR key = ?",
        (f"project_map:{path_hash}", f"project_map:{canonical_path}"),
    ).fetchone()
    if row is not None:
        project_id = str(row[0])
        fingerprint = f"explicit:{project_id}"
    elif "pcm_project_aliases" in pcm.table_names(conn):
        # Only an alias an ADOPTION wrote is an explicit map. `pcm.resolve_project_id`
        # records an alias row automatically for every folder it ever sees, so
        # without the `explicit:` fingerprint join, tier 1 of the documented
        # resolution order would be reachable without anyone having adopted
        # anything — and an auto-recorded row could masquerade as a member's
        # confirmed decision.
        alias = conn.execute(
            "SELECT a.project_id FROM pcm_project_aliases AS a "
            "JOIN projects AS p ON p.project_id = a.project_id "
            "WHERE a.path_hash = ? AND p.fingerprint LIKE 'explicit:%' LIMIT 1",
            (path_hash,),
        ).fetchone()
        if alias is not None:
            project_id = str(alias[0])
            fingerprint = f"explicit:{project_id}"

    # 2. Git root or 3. Provisional hashed path
    if project_id is None:
        fingerprint = pcm.project_identity_fingerprint(root)
        project_id = pcm.project_id_for_fingerprint(fingerprint, pcm.project_id_for(root))

    # `.burnbar/project-id` is never read here at all. Resolution does not
    # consult it (that is what stops a cloned repo re-scoping memories), and
    # noting it would be a WRITE on a path every read runs through. The doctor
    # reads it, validates it, and reports it — see `read_project_dotfile`.

    existing = conn.execute(
        "SELECT fingerprint, display_name, primary_path FROM projects WHERE project_id = ?", (project_id,)
    ).fetchone()
    # Read paths (recall, list, stats) resolve the project too. Only write when
    # something changed, so a read never opens a write transaction that would
    # hold the store's lock against another process until the connection closes.
    if existing is not None and (str(existing[0]), str(existing[1]), str(existing[2])) == (
        fingerprint,
        root.name,
        canonical_path,
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
        (project_id, fingerprint, root.name, canonical_path, ts, ts),
    )
    conn.commit()
    return project_id, root


def project_payload(project_id: str, root: Path) -> dict[str, str]:
    return {"projectID": project_id, "projectRoot": str(root), "projectName": root.name}
