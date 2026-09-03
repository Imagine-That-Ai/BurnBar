"""The engine itself: configuration, the active-memory row model, and the
`MemoryEngine` class composed from the write, read, and maintenance mixins."""

from __future__ import annotations

import math
import os
import sqlite3
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any

from ._admin import _Maintenance
from ._read import _ReadPath
from ._util import _clamp, _json_dumps, _json_loads, _parse_iso
from ._write import _WritePath
from .constants import (
    ENGINE_ACTOR,
    HALF_LIFE_DAYS_LONG,
    HALF_LIFE_DAYS_SHORT,
    KIND_WEIGHTS,
    PII_POLICIES,
    PII_POLICY_ENV,
    SECRET_POLICIES,
    SECRET_POLICY_ENV,
    SHORT_HALF_LIFE_KINDS,
)
from .crypto import KeyRing, secure_store_files
from .embeddings import EmbeddingProvider, decode_vector, embedding_provider
from .gate import auxiliary_injection_labels
from .store import default_db_path, open_store, resolve_project
from .text import tokenize


@dataclass
class EngineConfig:
    secret_policy: str = "redact"  # noqa: S105 — policy selector, not a credential
    pii_policy: str = "keep"
    retain_allowed: bool = False
    actor: str = ENGINE_ACTOR

    def __post_init__(self) -> None:
        if self.secret_policy not in SECRET_POLICIES:
            self.secret_policy = "redact"  # noqa: S105 — policy selector, not a credential
        if self.pii_policy not in PII_POLICIES:
            # A misspelled privacy policy must never become implicit consent
            # to retain or send raw PII to an extractor/embedding provider.
            self.pii_policy = "reject"

    @classmethod
    def from_env(cls, retain_allowed: bool = False) -> EngineConfig:
        gate_policy = os.environ.get(SECRET_POLICY_ENV, "redact").strip().lower() or "redact"
        if gate_policy not in SECRET_POLICIES:
            gate_policy = "redact"
        pii_policy = os.environ.get(PII_POLICY_ENV, "keep").strip().lower() or "keep"
        return cls(secret_policy=gate_policy, pii_policy=pii_policy, retain_allowed=retain_allowed)


@dataclass
class ActiveMemory:
    rowid: int
    id: str
    project_id: str
    scope: str
    kind: str
    body: str
    sensitivity: str
    review_status: str
    confidence: float
    salience: float
    access_count: int
    last_accessed_at: str | None
    immutable: bool
    expires_at: str | None
    valid_from: str
    valid_to: str | None
    superseded_by: str | None
    tags: list[str]
    entities: list[str]
    metadata: dict[str, Any]
    source_kind: str
    source_ref: str | None
    extractor: str
    embedding_version: str | None
    created_at: str
    updated_at: str
    # Content tokens (body + tags + entities). These decide near-duplicate
    # similarity, so provenance must stay out of them.
    tokens: list[str] = field(default_factory=list)
    # The lexical index: content plus `source_ref`, so a memory stays findable by
    # the path or ticket it came from. Ranking only -- never similarity.
    recall_tokens: list[str] = field(default_factory=list)
    vector: list[float] | None = None

    def public(self, include_body: bool = True) -> dict[str, Any]:
        payload = {
            "memoryID": self.id,
            "projectID": self.project_id,
            "scope": self.scope,
            "kind": self.kind,
            "sensitivity": self.sensitivity,
            "reviewStatus": self.review_status,
            "confidence": self.confidence,
            "salience": round(self.salience, 4),
            "accessCount": self.access_count,
            "lastAccessedAt": self.last_accessed_at,
            "immutable": self.immutable,
            "expiresAt": self.expires_at,
            "validFrom": self.valid_from,
            "validTo": self.valid_to,
            "supersededBy": self.superseded_by,
            "tags": self.tags,
            "entities": self.entities,
            "metadata": self.metadata,
            "sourceKind": self.source_kind,
            "sourceRef": self.source_ref,
            "extractor": self.extractor,
            "embeddingVersion": self.embedding_version,
            "createdAt": self.created_at,
            "updatedAt": self.updated_at,
        }
        if include_body:
            payload["body"] = self.body
        return payload


_PROJECT_CACHE: dict[str, tuple[tuple[int, str, int, str], list[ActiveMemory]]] = {}


class MemoryEngine(_WritePath, _ReadPath, _Maintenance):
    def __init__(
        self,
        conn: sqlite3.Connection,
        *,
        keyring: KeyRing,
        provider: EmbeddingProvider,
        config: EngineConfig | None = None,
        db_path: Path | None = None,
    ) -> None:
        self.conn = conn
        self.keyring = keyring
        self.provider = provider
        self.config = config or EngineConfig()
        self.db_path = db_path
        self.conn.create_function(
            "memory_aux_is_injection",
            4,
            lambda tags, entities, metadata, source_ref: int(
                bool(
                    auxiliary_injection_labels(
                        _json_loads(tags, []),
                        _json_loads(entities, []),
                        _json_loads(metadata, {}),
                        source_ref,
                    )
                )
            ),
            deterministic=True,
        )

    # ----- construction helpers -----------------------------------------

    @classmethod
    def open(
        cls,
        db_path: Path | str | None = None,
        *,
        provider: EmbeddingProvider | None = None,
        config: EngineConfig | None = None,
    ) -> MemoryEngine:
        path = Path(db_path) if db_path is not None else default_db_path()
        # Resolve the key before opening/migrating the database so a missing or
        # corrupt key for a populated store fails without mutating that store.
        keyring = KeyRing.load(path)
        if not keyring.matches_store(path):
            raise RuntimeError(
                f"memory key {keyring.key_id} ({keyring.source}) cannot decrypt populated store {path}; restore the original key"
            )
        conn = open_store(path)
        return cls(conn, keyring=keyring, provider=embedding_provider(provider), config=config, db_path=path)

    def _commit(self) -> None:
        self.conn.commit()
        if self.db_path is not None:
            secure_store_files(self.db_path)

    def close(self) -> None:
        try:
            self.conn.close()
        except sqlite3.Error:
            pass
        if self.db_path is not None:
            secure_store_files(self.db_path)

    def record_daemon_mirror(
        self,
        memory_id: str,
        daemon_memory_id: str,
        *,
        body_hash: str | None = None,
        project_path: str | None = None,
    ) -> None:
        """Persist the daemon id until cross-store deletion succeeds.

        The mapping doubles as a durable forget tombstone after the local row
        is purged, allowing a later ``burnbar_forget`` call to retry a daemon
        deletion that failed while the daemon was unavailable. New mappings
        also carry the mirrored body hash so an interrupted body-changing
        update can distinguish the stale daemon copy on retry.
        """
        self.conn.execute(
            "INSERT OR REPLACE INTO engine_meta (key, value) VALUES (?, ?)",
            (
                f"daemon_mirror:{memory_id}",
                _json_dumps({"daemonMemoryID": daemon_memory_id, "bodyHash": body_hash, "projectPath": project_path})
                if body_hash or project_path
                else daemon_memory_id,
            ),
        )
        self._commit()

    def pending_daemon_mirror_ids(self, project_path: str | None) -> list[str]:
        """Return durable mirror tombstones owned by one canonical project path."""
        _project_id, root = resolve_project(self.conn, project_path)
        pending: list[str] = []
        rows = self.conn.execute(
            "SELECT key, value FROM engine_meta WHERE key LIKE 'daemon_mirror:%' ORDER BY key"
        ).fetchall()
        for row in rows:
            parsed = _json_loads(row["value"], None)
            if not isinstance(parsed, dict) or parsed.get("projectPath") != str(root):
                continue
            pending.append(str(row["key"])[len("daemon_mirror:") :])
        return pending

    def daemon_mirror_id(self, memory_id: str) -> str | None:
        row = self.conn.execute(
            "SELECT value FROM engine_meta WHERE key = ?",
            (f"daemon_mirror:{memory_id}",),
        ).fetchone()
        if row is None:
            return None
        value = str(row["value"])
        parsed = _json_loads(value, None)
        if isinstance(parsed, dict) and parsed.get("daemonMemoryID"):
            return str(parsed["daemonMemoryID"])
        return value

    def daemon_mirror_body_hash(self, memory_id: str) -> str | None:
        row = self.conn.execute(
            "SELECT value FROM engine_meta WHERE key = ?",
            (f"daemon_mirror:{memory_id}",),
        ).fetchone()
        parsed = _json_loads(row["value"], None) if row is not None else None
        return str(parsed["bodyHash"]) if isinstance(parsed, dict) and parsed.get("bodyHash") else None

    def daemon_mirror_project_path(self, memory_id: str) -> str | None:
        row = self.conn.execute(
            "SELECT value FROM engine_meta WHERE key = ?",
            (f"daemon_mirror:{memory_id}",),
        ).fetchone()
        parsed = _json_loads(row["value"], None) if row is not None else None
        return str(parsed["projectPath"]) if isinstance(parsed, dict) and parsed.get("projectPath") else None

    def project_path_for_memory(self, memory_id: str) -> str | None:
        row = self.conn.execute(
            """
            SELECT p.primary_path
            FROM memories AS m
            JOIN projects AS p ON p.project_id = m.project_id
            WHERE m.id = ?
            """,
            (memory_id,),
        ).fetchone()
        return str(row["primary_path"]) if row is not None else None

    def clear_daemon_mirror(self, memory_id: str) -> None:
        """Clear a mirror mapping only after the daemon confirms deletion."""
        self.conn.execute("DELETE FROM engine_meta WHERE key = ?", (f"daemon_mirror:{memory_id}",))
        self._commit()

    def __enter__(self) -> MemoryEngine:
        return self

    def __exit__(self, exc_type: Any, exc: Any, tb: Any) -> None:
        self.close()

    # ----- crypto helpers -----------------------------------------------

    def _aad(self, memory_id: str, project_id: str) -> str:
        return f"{memory_id}|{project_id}|memory"

    def _seal_body(self, memory_id: str, project_id: str, body: str) -> tuple[bytes, bytes]:
        return self.keyring.seal(body, self._aad(memory_id, project_id))

    def _open_body(self, memory_id: str, project_id: str, cipher: bytes, nonce: bytes) -> str | None:
        return self.keyring.open(cipher, nonce, self._aad(memory_id, project_id))

    # ----- row loading --------------------------------------------------

    def _row_to_memory(self, row: sqlite3.Row, *, with_vector: bool = False) -> ActiveMemory | None:
        body = self._open_body(str(row["id"]), str(row["project_id"]), row["body_cipher"], row["body_nonce"])
        if body is None:
            return None
        vector = None
        if with_vector and "vector" in row.keys() and row["vector"] is not None:
            vector = decode_vector(row["vector"], int(row["dimension"] or 0))
        tags = _json_loads(row["tags_json"], [])
        entities = _json_loads(row["entities_json"], [])
        metadata = _json_loads(row["metadata_json"], {})
        source_ref = row["source_ref"]
        review_status = str(row["review_status"])
        if auxiliary_injection_labels(tags, entities, metadata, source_ref):
            # Read-time backstop for rows written before auxiliary injection
            # screening existed. Such rows stay hidden until their fields are
            # cleaned, even if their persisted status says approved.
            review_status = "quarantined"
        memory = ActiveMemory(
            rowid=int(row["rowid"]),
            id=str(row["id"]),
            project_id=str(row["project_id"]),
            scope=str(row["scope"]),
            kind=str(row["kind"]),
            body=body,
            sensitivity=str(row["sensitivity"]),
            review_status=review_status,
            confidence=float(row["confidence"]),
            salience=float(row["salience"]),
            access_count=int(row["access_count"] or 0),
            last_accessed_at=row["last_accessed_at"],
            immutable=bool(row["immutable"]),
            expires_at=row["expires_at"],
            valid_from=str(row["valid_from"]),
            valid_to=row["valid_to"],
            superseded_by=row["superseded_by"],
            tags=tags,
            entities=entities,
            metadata=metadata,
            source_kind=str(row["source_kind"]),
            source_ref=source_ref,
            extractor=str(row["extractor"]),
            embedding_version=row["embedding_version"],
            created_at=str(row["created_at"]),
            updated_at=str(row["updated_at"]),
            vector=vector,
        )
        # Content only, and built exactly like the incoming side in
        # `_commit_fact`, because these tokens decide near-duplicate similarity.
        content = " ".join([memory.body, " ".join(memory.tags), " ".join(memory.entities)])
        memory.tokens = tokenize(content)
        # The lexical index keeps `source_ref` so `recall("docs release runbook")`
        # still finds the memory captured from `docs/release/runbook.md`.
        memory.recall_tokens = tokenize(" ".join([content, memory.source_ref or ""]))
        return memory

    _SELECT = """
        SELECT m.rowid AS rowid, m.*, v.vector AS vector, v.dimension AS dimension, v.embedding_version AS vector_version
        FROM memories AS m
        LEFT JOIN memory_vectors AS v ON v.memory_rowid = m.rowid AND v.embedding_version = ?
    """
    _SELECT_NO_VECTOR = "SELECT m.rowid AS rowid, m.* FROM memories AS m "

    def _load_active(
        self, project_id: str, *, include_personal_cross_project: bool = True, include_cross_project: bool = False
    ) -> list[ActiveMemory]:
        version = self.provider.version_id
        if include_cross_project:
            where = "WHERE m.valid_to IS NULL"
            params: list[Any] = [version]
        elif include_personal_cross_project:
            where = "WHERE m.valid_to IS NULL AND (m.project_id = ? OR m.scope = 'personal')"
            params = [version, project_id]
        else:
            where = "WHERE m.valid_to IS NULL AND m.project_id = ?"
            params = [version, project_id]
        # Reinforcement moves access_count / last_accessed_at / salience without
        # touching updated_at, so the stamp has to include them or another
        # process's reinforcement would be invisible to this one's cache.
        stamp_sql = f"SELECT COUNT(*) AS c, COALESCE(MAX(m.updated_at), '') AS u, COALESCE(SUM(m.access_count), 0) AS a, COALESCE(MAX(m.last_accessed_at), '') AS l, COALESCE(SUM(m.salience), 0) AS s FROM memories AS m {where}"  # noqa: S608 — `where` is one of three fixed literals above; values are bound
        stamp_row = self.conn.execute(stamp_sql, params[1:]).fetchone()
        stamp = (
            int(stamp_row["c"]),
            str(stamp_row["u"]),
            int(stamp_row["a"]),
            f"{stamp_row['l']}|{float(stamp_row['s']):.6f}",
        )
        vector_where = where + " AND v.embedding_version = ?"
        vector_row = self.conn.execute(
            f"SELECT COUNT(*) AS c, COALESCE(MAX(v.rowid), 0) AS r FROM memory_vectors AS v JOIN memories AS m ON m.rowid = v.memory_rowid {vector_where}",  # noqa: S608 -- `where` is one of the fixed literals above
            params[1:] + [version],
        ).fetchone()
        stamp = (*stamp[:3], f"{stamp[3]}|vectors:{int(vector_row['c'])}:{int(vector_row['r'])}")
        cache_key = f"{project_id}|{include_personal_cross_project}|{include_cross_project}|{version}"
        cached = _PROJECT_CACHE.get(cache_key)
        if cached and cached[0] == stamp:
            return cached[1]
        rows = self.conn.execute(self._SELECT + where + " ORDER BY m.updated_at DESC", params).fetchall()
        memories = [item for item in (self._row_to_memory(row, with_vector=True) for row in rows) if item is not None]
        _PROJECT_CACHE[cache_key] = (stamp, memories)
        return memories

    def _invalidate_cache(self) -> None:
        _PROJECT_CACHE.clear()

    def _get_row(self, memory_id: str) -> sqlite3.Row | None:
        return self.conn.execute(self._SELECT + "WHERE m.id = ?", (self.provider.version_id, memory_id)).fetchone()

    # ----- salience -----------------------------------------------------

    @staticmethod
    def compute_salience(kind: str, confidence: float, access_count: int) -> float:
        base = KIND_WEIGHTS.get(kind, 0.5) * _clamp(confidence, 0.05, 1.0)
        boost = min(1.5, 1.0 + 0.1 * math.log2(1 + max(0, access_count)))
        return _clamp(base * boost, 0.0, 1.5)

    @staticmethod
    def recency_factor(kind: str, updated_at: str, last_accessed_at: str | None, now: datetime) -> float:
        anchor = max(filter(None, [_parse_iso(updated_at), _parse_iso(last_accessed_at)]), default=None)
        if anchor is None:
            return 1.0
        half_life = HALF_LIFE_DAYS_SHORT if kind in SHORT_HALF_LIFE_KINDS else HALF_LIFE_DAYS_LONG
        age_days = max(0.0, (now - anchor).total_seconds() / 86_400.0)
        return 0.5 + 0.5 * math.pow(0.5, age_days / half_life)
