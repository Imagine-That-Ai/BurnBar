"""AES-256-GCM key handling and the private-mode helpers for the store files.

Bodies (and history bodies, and the vault) are sealed with a key the engine
owns; vectors and metadata are plaintext."""

from __future__ import annotations

import base64
import binascii
import contextlib
import os
import secrets
import sqlite3
from dataclasses import dataclass
from pathlib import Path

from ._util import sha256_hex
from .constants import MEMORY_KEY_ENV

try:
    import fcntl
except ImportError:  # pragma: no cover - POSIX only; the local MCP runs on macOS/Linux
    fcntl = None  # type: ignore[assignment]


def _aesgcm():
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM

    return AESGCM


@dataclass
class KeyRing:
    key: bytes
    key_id: str
    source: str

    @classmethod
    def load(cls, db_path: Path) -> KeyRing:
        env_key = os.environ.get(MEMORY_KEY_ENV, "").strip()
        if env_key:
            try:
                raw = base64.b64decode(env_key)
            except (ValueError, TypeError) as exc:
                raise ValueError(f"{MEMORY_KEY_ENV} must be base64") from exc
            if len(raw) != 32:
                raise ValueError(f"{MEMORY_KEY_ENV} must decode to 32 bytes")
            return cls(raw, sha256_hex(raw)[:12], "env")
        key_path = db_path.with_name(db_path.stem + ".key")
        raw = cls._read_key(key_path)
        if raw is None:
            raw = cls._publish_key(key_path, secrets.token_bytes(32), db_path=db_path)
        with contextlib.suppress(OSError):
            os.chmod(key_path, 0o600)
        return cls(raw, sha256_hex(raw)[:12], "file")

    def matches_store(self, db_path: Path) -> bool:
        """Validate stored key IDs and authenticate one encrypted row per populated section."""
        if not db_path.exists() or db_path.stat().st_size == 0:
            return True
        try:
            conn = sqlite3.connect(f"{db_path.resolve().as_uri()}?mode=ro", uri=True)
            conn.row_factory = sqlite3.Row
            try:
                tables = {
                    str(row[0])
                    for row in conn.execute("SELECT name FROM sqlite_master WHERE type = 'table'").fetchall()
                }
                probes = (
                    (
                        "memories",
                        "SELECT DISTINCT key_id FROM memories",
                        "SELECT id, project_id, body_cipher AS cipher, body_nonce AS nonce, key_id FROM memories LIMIT 1",
                        "memory",
                    ),
                    (
                        "memory_history",
                        "SELECT DISTINCT key_id FROM memory_history",
                        """
                        SELECT memory_id AS id, project_id,
                               COALESCE(before_cipher, after_cipher) AS cipher,
                               CASE WHEN before_cipher IS NOT NULL THEN before_nonce ELSE after_nonce END AS nonce,
                               key_id
                        FROM memory_history
                        WHERE before_cipher IS NOT NULL OR after_cipher IS NOT NULL
                        LIMIT 1
                        """,
                        "history",
                    ),
                    (
                        "memory_vault",
                        "SELECT DISTINCT key_id FROM memory_vault",
                        "SELECT memory_id AS id, project_id, secret_cipher AS cipher, secret_nonce AS nonce, key_id FROM memory_vault LIMIT 1",
                        "vault",
                    ),
                )
                for table, key_ids_sql, probe_sql, aad_suffix in probes:
                    if table not in tables:
                        continue
                    key_ids = {str(row[0]) for row in conn.execute(key_ids_sql).fetchall()}
                    if any(key_id != self.key_id for key_id in key_ids):
                        return False
                    row = conn.execute(probe_sql).fetchone()
                    if (
                        row is not None
                        and self.open(row["cipher"], row["nonce"], f"{row['id']}|{row['project_id']}|{aad_suffix}")
                        is None
                    ):
                        return False
                return True
            finally:
                conn.close()
        except (OSError, sqlite3.Error):
            return False

    @staticmethod
    def _read_key(key_path: Path) -> bytes | None:
        try:
            existing = key_path.read_text(encoding="utf-8").strip()
        except OSError:
            return None
        if not existing:
            return None
        try:
            raw = base64.b64decode(existing, validate=True)
        except (binascii.Error, ValueError):
            return None
        return raw if len(raw) == 32 else None

    @staticmethod
    def _store_has_encrypted_rows(db_path: Path) -> bool:
        if not db_path.exists() or db_path.stat().st_size == 0:
            return False
        try:
            conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
            try:
                tables = {
                    str(row[0])
                    for row in conn.execute("SELECT name FROM sqlite_master WHERE type = 'table'").fetchall()
                }
                encrypted_tables = {
                    "memories": "body_cipher",
                    "memory_history": "before_cipher IS NOT NULL OR after_cipher IS NOT NULL",
                    "memory_vault": "secret_cipher",
                }
                for table, predicate in encrypted_tables.items():
                    if table not in tables:
                        continue
                    where = predicate if " " in predicate else f"{predicate} IS NOT NULL"
                    if conn.execute(f"SELECT 1 FROM {table} WHERE {where} LIMIT 1").fetchone():  # noqa: S608 -- fixed table/predicate literals
                        return True
                return False
            finally:
                conn.close()
        except (OSError, sqlite3.Error):
            # An invalid key plus an unreadable, non-empty store is not a first
            # run. Refuse to destroy the only key reference.
            return True

    @staticmethod
    def _publish_key(key_path: Path, raw: bytes, *, db_path: Path | None = None) -> bytes:
        """Publish `raw` at `key_path` and return the key in force.

        Publication is serialized with an advisory lock (`<stem>.lock`) so
        two first-run processes cannot each write a different key: the loser
        re-reads under the lock and adopts the winner's key. The key is written
        to a private temp file and moved into place atomically, which also
        repairs an invalid key only while the store has no encrypted rows. A
        missing or damaged key for a populated store fails closed: replacing
        it would make every encrypted body permanently undecryptable.
        """
        key_path.parent.mkdir(parents=True, exist_ok=True)
        published = KeyRing._read_key(key_path)
        if published is not None:
            return published
        lock_path = store_lock_path(key_path)
        lock_fd = os.open(str(lock_path), os.O_RDWR | os.O_CREAT, 0o600)
        try:
            if fcntl is not None:
                fcntl.flock(lock_fd, fcntl.LOCK_EX)
            published = KeyRing._read_key(key_path)
            if published is not None:
                return published
            if db_path is not None and KeyRing._store_has_encrypted_rows(db_path):
                raise RuntimeError(
                    f"memory key is missing or invalid for populated store {db_path}; restore the original key"
                )
            tmp_path = key_path.with_name(f"{key_path.stem}.{os.getpid()}.{secrets.token_hex(4)}.tmp")
            fd = os.open(str(tmp_path), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            try:
                with os.fdopen(fd, "w", encoding="utf-8") as handle:
                    handle.write(base64.b64encode(raw).decode("ascii") + "\n")
                    handle.flush()
                    os.fsync(handle.fileno())
                os.replace(str(tmp_path), str(key_path))
            finally:
                with contextlib.suppress(OSError):
                    os.unlink(str(tmp_path))
            return raw
        finally:
            if fcntl is not None:
                with contextlib.suppress(OSError):
                    fcntl.flock(lock_fd, fcntl.LOCK_UN)
            os.close(lock_fd)

    def seal(self, plaintext: str, aad: str) -> tuple[bytes, bytes]:
        nonce = secrets.token_bytes(12)
        cipher = _aesgcm()(self.key).encrypt(nonce, plaintext.encode("utf-8"), aad.encode("utf-8"))
        return cipher, nonce

    def open(self, cipher: bytes, nonce: bytes, aad: str) -> str | None:
        try:
            return _aesgcm()(self.key).decrypt(bytes(nonce), bytes(cipher), aad.encode("utf-8")).decode("utf-8")
        except Exception:  # noqa: BLE001 — wrong key / tampered row; caller reports undecryptable
            return None


def store_sidecar_paths(db_path: Path) -> list[Path]:
    return [db_path] + [db_path.with_name(db_path.name + suffix) for suffix in ("-wal", "-shm", "-journal")]


def secure_store_files(db_path: Path) -> None:
    """Keep the database and its WAL / shared-memory / journal sidecars private.

    The WAL carries plaintext metadata (and, before a checkpoint, every page
    written in the transaction), so it gets the same mode as the database.
    """
    for candidate in store_sidecar_paths(db_path):
        with contextlib.suppress(OSError):
            if candidate.exists():
                os.chmod(candidate, 0o600)


def store_lock_path(db_path: Path) -> Path:
    """Advisory lock shared by store initialization and key publication."""
    return db_path.with_name(db_path.stem + ".lock")
