"""`MemoryEngine`'s maintenance surface, mixed into the engine class.

Only methods live here; construction and shared state stay in `engine.py`."""

from __future__ import annotations

import os
from collections.abc import Sequence
from dataclasses import dataclass, field
from datetime import UTC, datetime
from typing import Any

from . import gate
from ._util import (
    _aux_strings,
    _ingest_decision,
    _json_dumps,
    _json_loads,
    _parse_iso,
    normalize_kind,
    normalize_tags,
    now_iso,
    sha256_hex,
)
from .constants import (
    DEFAULT_EMBEDDING_MODEL,
    EMBEDDING_PROVIDER_ENV,
    ENGINE_SCHEMA_VERSION,
    MAX_MEMORIES_PER_PROJECT_SOFT,
    MEMORY_SCOPES,
    REMOTE_PAYLOAD_SCHEMA_MAX,
    REMOTE_SOURCE_KIND,
)
from .embeddings import encode_vector
from .extract import Fact, _slot_key, extract_entities, extract_relations
from .store import audit_event, default_db_path, project_payload, resolve_project, verify_audit_chain


# The auxiliary-exposure sweep is a regex pass over short strings, so the cap is
# generous: 5,000 rows costs a small fraction of a `doctor` call. It exists so a
# pathological store cannot make `doctor` hang, and whenever it bites, the scan
# says so rather than returning a quietly partial answer.
AUX_SCAN_ROW_LIMIT = 5_000


def _forget_identity_key(project_id: str, scope: str, body_hash: str) -> str:
    """The convergence identity of a forgotten fact, as one point-lookup key."""
    return sha256_hex(f"{project_id}|{scope}|{body_hash}")[:32]


# Older than any real timestamp: what an unparseable stored `updated_at` compares
# as, so a corrupt local row loses to a remote revision instead of freezing it.
_EPOCH = datetime.min.replace(tzinfo=UTC)


def _canonical_iso(value: str | None) -> str | None:
    """One instant, one spelling. Devices seal `updatedAt` in whatever ISO-8601
    form their encoder emits; the stored column has to be comparable across all
    of them, and every ordering decision here is made on the parsed instant
    rather than on the text."""
    parsed = _parse_iso(value)
    return None if parsed is None else parsed.astimezone(UTC).isoformat().replace("+00:00", "Z")


@dataclass
class _RemoteFact:
    """One inbox document, parsed and past the gate: what the merge acts on."""

    doc_id: str
    user_id: str
    memory_id: str
    project_id: str
    scope: str
    kind: str
    body: str
    body_hash: str
    confidence: float
    valid_from: str
    valid_to: str | None
    superseded_by: str | None
    updated_at: str
    sensitivity: str
    review_status: str
    # The parsed `updated_at`. Every ordering decision uses this, never the text:
    # two spellings of one instant, or one with microseconds and one without,
    # do not sort the way their strings do.
    updated_ts: datetime
    tags: list[str] = field(default_factory=list)
    entities: list[str] = field(default_factory=list)
    gate_labels: list[str] = field(default_factory=list)
    injection: list[str] = field(default_factory=list)

    @property
    def order_key(self) -> tuple[datetime, str, str]:
        """§5's total order: last-writer-wins on `updated_at`, tie-broken by
        `memory_id`. `body_hash` closes the remaining tie — two devices editing
        the same memory in the same second — so the order is total and every
        replica applies the batch identically."""
        return (self.updated_ts, self.memory_id, self.body_hash)


class _Maintenance:
    """`MemoryEngine`'s maintenance surface: doctor, export/import, reindex, stats."""

    def _embed_rows(self, memory_ids: Sequence[str]) -> int:
        if not self.provider.available or not memory_ids:
            return 0
        if self.conn.in_transaction:
            self._commit()
        rows = self.conn.execute(
            f"SELECT rowid, id, project_id, body_hash, body_cipher, body_nonce FROM memories WHERE id IN ({','.join('?' * len(memory_ids))})",  # noqa: S608 — placeholders only
            list(memory_ids),
        ).fetchall()
        bodies: list[tuple[int, str, str, str]] = []
        for row in rows:
            body = self._open_body(str(row["id"]), str(row["project_id"]), row["body_cipher"], row["body_nonce"])
            if body is not None:
                bodies.append((int(row["rowid"]), str(row["id"]), str(row["body_hash"]), body))
        vectors = self.provider.embed([body for _, _, _, body in bodies])
        count = 0
        for (rowid, memory_id, embedded_hash, _), vector in zip(bodies, vectors, strict=False):
            if vector is None:
                continue
            if not self.conn.in_transaction:
                self.conn.execute("BEGIN IMMEDIATE")
            current = self.conn.execute(
                "SELECT body_hash, valid_to FROM memories WHERE rowid = ? AND id = ?", (rowid, memory_id)
            ).fetchone()
            if current is None or current["valid_to"] is not None or str(current["body_hash"]) != embedded_hash:
                # Another process changed or retired the body while the
                # provider was working. Preserve its current vector and let a
                # later reindex embed the new body.
                continue
            self.conn.execute("DELETE FROM memory_vectors WHERE memory_rowid = ?", (rowid,))
            self.conn.execute(
                "INSERT INTO memory_vectors (memory_rowid, embedding_version, dimension, vector) VALUES (?, ?, ?, ?)",
                (rowid, self.provider.version_id, len(vector), encode_vector(vector)),
            )
            self.conn.execute(
                "UPDATE memories SET embedding_version = ? WHERE id = ?", (self.provider.version_id, memory_id)
            )
            count += 1
        return count

    def embedding_pending(self, *, project_id: str | None = None) -> int:
        """Active rows without a vector for the current embedding version (what `reindex` would embed)."""
        sql = (
            "SELECT COUNT(*) FROM memories m LEFT JOIN memory_vectors v "
            "ON v.memory_rowid = m.rowid AND v.embedding_version = ? WHERE m.valid_to IS NULL AND v.memory_rowid IS NULL"
        )
        params: list[Any] = [self.provider.version_id]
        if project_id is not None:
            sql += " AND m.project_id = ?"
            params.append(project_id)
        return int(self.conn.execute(sql, params).fetchone()[0])

    def reindex(
        self, *, project_path: str | None = None, all_projects: bool = False, batch_size: int = 32
    ) -> dict[str, Any]:
        if not self.provider.available:
            return {"status": "unavailable", "code": "EMBEDDINGS_UNAVAILABLE", "embedding": self.provider.describe()}
        if all_projects:
            rows = self.conn.execute(
                "SELECT m.id FROM memories m LEFT JOIN memory_vectors v ON v.memory_rowid = m.rowid AND v.embedding_version = ? WHERE m.valid_to IS NULL AND v.memory_rowid IS NULL",
                (self.provider.version_id,),
            ).fetchall()
            payload: dict[str, Any] = {}
            stale_params: tuple[Any, ...] = (self.provider.version_id,)
            stale_count_sql = "SELECT COUNT(*) FROM memory_vectors WHERE embedding_version != ?"
            stale_delete_sql = "DELETE FROM memory_vectors WHERE embedding_version != ?"
        else:
            project_id, root = resolve_project(self.conn, project_path)
            rows = self.conn.execute(
                "SELECT m.id FROM memories m LEFT JOIN memory_vectors v ON v.memory_rowid = m.rowid AND v.embedding_version = ? WHERE m.valid_to IS NULL AND v.memory_rowid IS NULL AND m.project_id = ?",
                (self.provider.version_id, project_id),
            ).fetchall()
            payload = project_payload(project_id, root)
            stale_params = (self.provider.version_id, project_id)
            stale_count_sql = """
                SELECT COUNT(*)
                FROM memory_vectors AS v
                JOIN memories AS m ON m.rowid = v.memory_rowid
                WHERE v.embedding_version != ? AND m.project_id = ?
            """
            stale_delete_sql = """
                DELETE FROM memory_vectors
                WHERE embedding_version != ?
                  AND memory_rowid IN (SELECT rowid FROM memories WHERE project_id = ?)
            """
        ids = [str(row["id"]) for row in rows]
        stale = int(self.conn.execute(stale_count_sql, stale_params).fetchone()[0])
        embedded = 0
        for start in range(0, len(ids), max(1, batch_size)):
            embedded += self._embed_rows(ids[start : start + batch_size])
        self.conn.execute(stale_delete_sql, stale_params)
        audit_event(
            self.conn,
            action="memory.reindex",
            project_id=payload.get("projectID"),
            subject_id=None,
            labels=[f"embedded:{embedded}", f"version:{self.provider.version_id}"],
            actor=self.config.actor,
        )
        self._commit()
        self._invalidate_cache()
        return {
            "status": "ok",
            "pending": len(ids),
            "embedded": embedded,
            "staleVectorsPurged": stale,
            "embedding": self.provider.describe(),
            **payload,
        }

    def stats(self, *, project_path: str | None = None) -> dict[str, Any]:
        project_id, root = resolve_project(self.conn, project_path)

        def grouped_sql(column: str) -> str:
            return (
                f"SELECT {column}, COUNT(*) FROM memories WHERE project_id = ? AND valid_to IS NULL GROUP BY {column}"  # noqa: S608 — column from fixed allowlist
            )

        def grouped(column: str) -> dict[str, int]:
            return {str(row[0]): int(row[1]) for row in self.conn.execute(grouped_sql(column), (project_id,))}

        total = int(
            self.conn.execute(
                "SELECT COUNT(*) FROM memories WHERE project_id = ? AND valid_to IS NULL", (project_id,)
            ).fetchone()[0]
        )
        superseded = int(
            self.conn.execute(
                "SELECT COUNT(*) FROM memories WHERE project_id = ? AND valid_to IS NOT NULL", (project_id,)
            ).fetchone()[0]
        )
        embedded = int(
            self.conn.execute(
                "SELECT COUNT(*) FROM memories m JOIN memory_vectors v ON v.memory_rowid = m.rowid WHERE m.project_id = ? AND m.valid_to IS NULL AND v.embedding_version = ?",
                (project_id, self.provider.version_id),
            ).fetchone()[0]
        )
        vault = int(
            self.conn.execute("SELECT COUNT(*) FROM memory_vault WHERE project_id = ?", (project_id,)).fetchone()[0]
        )
        all_projects = int(self.conn.execute("SELECT COUNT(DISTINCT project_id) FROM memories").fetchone()[0])
        return {
            "status": "ok",
            "total": total,
            "superseded": superseded,
            "byKind": grouped("kind"),
            "byScope": grouped("scope"),
            "bySensitivity": grouped("sensitivity"),
            "byReviewStatus": grouped("review_status"),
            "embeddedActive": embedded,
            "embeddingCoverage": round(embedded / total, 3) if total else None,
            "vaultEntries": vault,
            "projectsInStore": all_projects,
            "embedding": self.provider.describe(),
            "policy": {
                "secret": self.config.secret_policy,
                "pii": self.config.pii_policy,
                "retainAllowed": self.config.retain_allowed,
            },
            **project_payload(project_id, root),
        }

    def audit_trail(self, *, project_path: str | None = None, limit: int = 50) -> dict[str, Any]:
        project_id, root = resolve_project(self.conn, project_path)
        rows = self.conn.execute(
            "SELECT * FROM memory_audit WHERE project_id = ? OR project_id IS NULL ORDER BY seq DESC LIMIT ?",
            (project_id, max(1, min(int(limit), 500))),
        ).fetchall()
        events = [
            {
                "seq": int(row["seq"]),
                "ts": row["ts"],
                "actor": row["actor"],
                "action": row["action"],
                "domain": row["domain"],
                "projectID": row["project_id"],
                "subjectID": row["subject_id"],
                "labels": _json_loads(row["labels_json"], []),
                "prevHash": row["prev_hash"],
                "hash": row["hash"],
            }
            for row in rows
        ]
        return {
            "status": "ok",
            "events": events,
            "chain": verify_audit_chain(self.conn),
            **project_payload(project_id, root),
        }

    def export(
        self,
        *,
        project_path: str | None = None,
        include_secrets: bool = False,
        include_superseded: bool = False,
        all_projects: bool = False,
    ) -> dict[str, Any]:
        params: list[Any] = [self.provider.version_id]
        where = "WHERE 1=1"
        payload: dict[str, Any] = {}
        if not all_projects:
            project_id, root = resolve_project(self.conn, project_path)
            where += " AND m.project_id = ?"
            params.append(project_id)
            payload = project_payload(project_id, root)
        if not include_superseded:
            where += " AND m.valid_to IS NULL"
        rows = self.conn.execute(self._SELECT + where + " ORDER BY m.created_at ASC", params).fetchall()
        items = []
        for row in rows:
            memory = self._row_to_memory(row)
            if memory is None:
                continue
            item = memory.public()
            if memory.sensitivity == "secret":
                item["secretText"] = self._open_vault(memory.id, memory.project_id) if include_secrets else None
            items.append(item)
        audit_event(
            self.conn,
            action="memory.export",
            project_id=payload.get("projectID"),
            subject_id=None,
            labels=[f"count:{len(items)}", f"secrets:{'yes' if include_secrets else 'no'}"],
            actor=self.config.actor,
        )
        self._commit()
        return {
            "status": "ok",
            "schema": "openburnbar.memory_export.v1",
            "allProjects": all_projects,
            "exportedAt": now_iso(),
            "count": len(items),
            "memories": items,
            **payload,
        }

    def import_memories(
        self, items: Sequence[dict[str, Any]], *, project_path: str | None, source_kind: str = "import"
    ) -> dict[str, Any]:
        decisions = []
        historical_skipped = 0
        project_id, root = resolve_project(self.conn, project_path)
        source_projects = sorted(
            {str(raw.get("projectID")) for raw in items if isinstance(raw, dict) and raw.get("projectID")}
        )
        if len(source_projects) > 1:
            return {
                "status": "unavailable",
                "code": "PROJECT_OWNERSHIP_MISMATCH",
                "reason": "multi-project exports cannot be flattened into one destination project",
                "projectIDs": source_projects,
                "summary": {event: 0 for event in ("ADD", "UPDATE", "NONE", "DELETE", "REJECT")},
                "decisions": [],
                "historicalSkipped": 0,
                **project_payload(project_id, root),
            }
        for raw in items:
            if not isinstance(raw, dict):
                continue
            if raw.get("validTo") or raw.get("valid_to"):
                # Historical export rows are archival evidence, not active
                # import candidates. Skipping them prevents retired facts from
                # becoming recallable again when an archive is restored.
                historical_skipped += 1
                continue
            fact = Fact.from_mapping({**raw, "text": raw.get("body") or raw.get("text")})
            if fact is None:
                continue
            if raw.get("secretText"):
                fact.text = str(raw["secretText"])
            # Engine-owned metadata is recomputed on write and must not leak across stores.
            for key in ("daemonMemoryID", "gateLabels", "injectionLabels"):
                fact.metadata.pop(key, None)
            decisions.append(
                self._commit_fact(
                    project_id=project_id,
                    root=root,
                    fact=fact,
                    source_kind=source_kind,
                    source_hash=None,
                    extractor="import",
                )
            )
        audit_event(
            self.conn,
            action="memory.import",
            project_id=project_id,
            subject_id=None,
            labels=[f"count:{len(decisions)}"],
            actor=self.config.actor,
        )
        self._commit()
        self._invalidate_cache()
        summary = {
            event: sum(1 for item in decisions if item["event"] == event)
            for event in ("ADD", "UPDATE", "NONE", "DELETE", "REJECT")
        }
        return {
            "status": "ok",
            "summary": summary,
            "decisions": decisions,
            "historicalSkipped": historical_skipped,
            **project_payload(project_id, root),
        }

    def import_legacy(self, items: Sequence[dict[str, Any]], *, project_path: str | None) -> dict[str, Any]:
        """Import rows from the daemon-owned `agent_memories` store exactly once.

        Each item carries `legacyMemoryID`; the engine records
        `memory_ingest.source_hash = "legacy:<id>"` after the write, so a row
        is never imported twice even across processes. Rows go through the
        same gate and reconciliation as any other write.
        """
        project_id, root = resolve_project(self.conn, project_path)
        imported = 0
        skipped = 0
        retryable = 0
        decisions: list[dict[str, Any]] = []
        for raw in items:
            if not isinstance(raw, dict):
                continue
            legacy_id = str(
                raw.get("legacyMemoryID") or (raw.get("metadata") or {}).get("legacyMemoryID") or ""
            ).strip()
            if not legacy_id:
                continue
            key = f"legacy:{legacy_id}"
            if self.conn.execute("SELECT 1 FROM memory_ingest WHERE source_hash = ?", (key,)).fetchone() is not None:
                skipped += 1
                continue
            owner_path = raw.get("legacyProjectPath")
            legacy_owner_id = str((raw.get("metadata") or {}).get("legacyProjectID") or "").strip()
            if owner_path:
                try:
                    owner_project_id, owner_root = resolve_project(self.conn, str(owner_path))
                except ValueError:
                    owner_project_id, owner_root = "", root
            elif legacy_owner_id and legacy_owner_id != project_id:
                owner_project_id, owner_root = "", root
            else:
                owner_project_id, owner_root = project_id, root
            if not owner_project_id:
                decisions.append(
                    {
                        "event": "REJECT",
                        "code": "LEGACY_PROJECT_UNAVAILABLE",
                        "reason": "legacy memory owner path is unavailable; refusing to reassign it to the active project",
                        "legacyMemoryID": legacy_id,
                    }
                )
                retryable += 1
                continue
            fact = Fact.from_mapping(raw)
            if fact is None:
                continue
            fact.metadata = {**fact.metadata, "legacyMemoryID": legacy_id}
            decision = self._commit_fact(
                project_id=owner_project_id,
                root=owner_root,
                fact=fact,
                source_kind="legacy_daemon",
                source_hash=key,
                extractor="legacy-import",
            )
            decision["legacyMemoryID"] = legacy_id
            decisions.append(decision)
            terminal = decision["event"] in ("ADD", "UPDATE", "DELETE") or (
                decision["event"] == "NONE" and decision.get("code") != "PREVIOUSLY_REJECTED"
            )
            if terminal:
                self.conn.execute(
                    "INSERT OR REPLACE INTO memory_ingest (source_hash, project_id, ts, decisions_json) VALUES (?, ?, ?, ?)",
                    (key, owner_project_id, now_iso(), _json_dumps([_ingest_decision(decision)])),
                )
                if decision.get("memoryID"):
                    self.record_daemon_mirror(
                        str(decision["memoryID"]),
                        legacy_id,
                        body_hash=sha256_hex(str(decision.get("text") or raw.get("text") or "")),
                        project_path=str(owner_root),
                    )
            else:
                retryable += 1
            if terminal and decision["event"] in ("ADD", "UPDATE", "NONE"):
                imported += 1
        audit_event(
            self.conn,
            action="memory.legacy_import",
            project_id=project_id,
            subject_id=None,
            labels=[f"imported:{imported}", f"skipped:{skipped}"]
            + sorted({f"event:{item['event']}" for item in decisions}),
            actor=self.config.actor,
        )
        self._commit()
        self._invalidate_cache()
        return {
            "status": "ok",
            "imported": imported,
            "skipped": skipped,
            "retryable": retryable,
            "decisions": decisions,
            **project_payload(project_id, root),
        }

    # ------------------------------------------------------------------
    # Memory Blind Sync — §5 of
    # docs/superpowers/specs/2026-09-03-memory-blind-sync-design.md
    # ------------------------------------------------------------------

    def sync_watermark(self) -> dict[str, dict[str, str]]:
        """The applied high-water mark of the merge, one entry per member."""
        rows = self.conn.execute(
            "SELECT user_id, applied_updated_at, applied_memory_id FROM sync_state ORDER BY user_id"
        ).fetchall()
        return {
            str(row["user_id"]): {
                "updatedAt": str(row["applied_updated_at"]),
                "memoryID": str(row["applied_memory_id"]),
            }
            for row in rows
        }

    def _record_forget_receipt(self, memory_id: str) -> None:
        """Persist what a hard forget destroyed, so blind sync cannot undo it.

        Two receipts, both point lookups: one on the engine id a remote document
        carries, one on the `(project_id, scope, body_hash)` identity §5 converges
        on — the same fact re-learned on another device arrives under a different
        engine id and must still be recognised as the thing this device forgot.
        `memory_history` cannot serve here: the forget purges it with the row.
        """
        row = self.conn.execute(
            "SELECT project_id, scope, body_hash FROM memories WHERE id = ?", (memory_id,)
        ).fetchone()
        if row is None:
            return
        project_id, scope, body_hash = str(row["project_id"]), str(row["scope"]), str(row["body_hash"])
        receipt = {"projectID": project_id, "scope": scope, "bodyHash": body_hash, "ts": now_iso()}
        self.conn.executemany(
            "INSERT OR REPLACE INTO engine_meta (key, value) VALUES (?, ?)",
            (
                (f"forget_receipt:{memory_id}", _json_dumps(receipt)),
                (f"forget_identity:{_forget_identity_key(project_id, scope, body_hash)}", memory_id),
            ),
        )

    def _forgotten(self, memory_id: str, project_id: str, scope: str, body_hash: str) -> str | None:
        """The forget receipt that forbids a remote row, if there is one."""
        identity = _forget_identity_key(project_id, scope, body_hash)
        row = self.conn.execute(
            "SELECT key FROM engine_meta WHERE key IN (?, ?) LIMIT 1",
            (f"forget_receipt:{memory_id}", f"forget_identity:{identity}"),
        ).fetchone()
        return str(row["key"]) if row is not None else None

    def _record_memory_alias(self, foreign_id: str, memory_id: str) -> None:
        """Remember that a foreign engine id folded into a local row.

        Without this, a fact learned independently on two devices reinforces the
        row that arrived first (§5) and every later reference to the id that lost
        — a supersede edge, a further update — would resolve to nothing and park
        for ever. The alias is what lets convergence hold on both sides.
        """
        if foreign_id == memory_id:
            return
        self.conn.execute(
            "INSERT OR REPLACE INTO engine_meta (key, value) VALUES (?, ?)",
            (f"memory_alias:{foreign_id}", memory_id),
        )

    def _local_memory_id(self, foreign_id: str) -> str | None:
        """The local row a remote engine id names: itself, or what it folded into."""
        if not foreign_id:
            return None
        if self.conn.execute("SELECT 1 FROM memories WHERE id = ?", (foreign_id,)).fetchone() is not None:
            return foreign_id
        row = self.conn.execute(
            "SELECT value FROM engine_meta WHERE key = ?", (f"memory_alias:{foreign_id}",)
        ).fetchone()
        if row is None:
            return None
        alias = str(row["value"])
        exists = self.conn.execute("SELECT 1 FROM memories WHERE id = ?", (alias,)).fetchone()
        return alias if exists is not None else None

    def _screen_remote_row(self, raw: Any) -> tuple[_RemoteFact | None, dict[str, Any]]:
        """Parse and gate one inbox entry before anything about it is believed.

        Returns either the screened fact or the decision that ends it. That
        decision's `ack` says whether the document is finished with: a row this
        engine will never accept is acknowledged so it stops being offered for
        ever, while one that is merely unusable *today* (a v1 payload carrying no
        engine project identity) is left unacknowledged for a later pull.
        """
        entry = raw if isinstance(raw, dict) else {}
        doc_id = str(entry.get("docID") or "")
        user_id = str(entry.get("userID") or "")

        def stop(code: str, reason: str, *, ack: bool = True) -> tuple[None, dict[str, Any]]:
            return None, {
                "event": "REFUSE" if ack else "PARK",
                "code": code,
                "reason": reason,
                "docID": doc_id,
                "userID": user_id,
                "ack": ack,
            }

        payload = entry.get("payload")
        if not isinstance(payload, dict):
            payload = _json_loads(entry.get("payloadJSON"), None)
        if not isinstance(payload, dict):
            return stop("MALFORMED_PAYLOAD", "the sealed payload is not a JSON object")
        try:
            schema_version = int(payload.get("schemaVersion") or 0)
        except (TypeError, ValueError):
            schema_version = 0
        if schema_version > REMOTE_PAYLOAD_SCHEMA_MAX:
            # A newer device sealed fields this engine cannot reason about. Park
            # it rather than merge a row only half of which is understood.
            return stop(
                "PAYLOAD_TOO_NEW",
                f"payload schema {schema_version} is newer than this engine's {REMOTE_PAYLOAD_SCHEMA_MAX}",
                ack=False,
            )
        memory_id = str(payload.get("memoryID") or "").strip()
        if not memory_id:
            return stop("MISSING_MEMORY_ID", "the payload names no engine memory id")
        updated_ts = _parse_iso(str(payload.get("updatedAt") or "").strip())
        if updated_ts is None:
            return stop("INVALID_UPDATED_AT", "updatedAt is not an ISO-8601 timestamp")
        updated_at = str(_canonical_iso(str(payload.get("updatedAt"))))
        project_id = str(payload.get("projectID") or "").strip()
        if not project_id:
            # §5 converges on `(project_id, scope, body_hash)`. A v1 payload, or a
            # chat memory that belongs to no engine project, cannot be keyed at all.
            return stop(
                "PROJECT_IDENTITY_MISSING",
                "the payload carries no engine project id, so it cannot be keyed for convergence",
                ack=False,
            )
        scope = str(payload.get("engineScope") or "").strip().lower()
        if scope not in MEMORY_SCOPES:
            return stop(
                "SCOPE_IDENTITY_MISSING",
                f"engineScope must be one of: {', '.join(MEMORY_SCOPES)}",
                ack=False,
            )
        fact = Fact.from_mapping(
            {
                "text": payload.get("text"),
                "kind": payload.get("kind"),
                "confidence": payload.get("confidence", 0.7),
                "tags": payload.get("tags") or [],
            }
        )
        if fact is None:
            return stop("EMPTY_MEMORY", "the payload carries no text")
        overflow = gate.aux_input_overflow(
            tags=fact.tags, entities=[], metadata=None, source_ref=None, source_kind=REMOTE_SOURCE_KIND
        )
        if overflow:
            return stop(gate.AUX_TOO_LARGE_CODE, overflow)

        # The gate a local `remember` passes, applied to a body this device did
        # not write. `retain_allowed` is pinned False: a remote row must never
        # create local vault material, so a retained secret is refused instead.
        decision = gate.apply_gate(
            fact.text,
            secret_policy=self.config.secret_policy,
            pii_policy=self.config.pii_policy,
            retain_allowed=False,
        )
        aux = gate.gate_aux_fields(
            tags=fact.tags,
            entities=[],
            metadata=None,
            source_ref=None,
            source_kind=REMOTE_SOURCE_KIND,
            secret_policy=self.config.secret_policy,
            pii_policy=self.config.pii_policy,
        )
        if decision.action == "reject" or aux.reject_reason:
            secret = decision.sensitivity == "secret" or aux.reject_code == "SECRET_DETECTED"
            audit_event(
                self.conn,
                action="memory.sync_gate_rejected",
                project_id=project_id,
                subject_id=None,
                labels=sorted(set(decision.labels + aux.labels)),
                actor=self.config.actor,
            )
            self._commit()
            return stop(
                "SECRET_DETECTED" if secret else "GATE_REJECTED",
                decision.reason or aux.reject_reason or "refused by the memory gate",
            )
        body = decision.body.strip()
        if not body:
            return stop("EMPTY_MEMORY", "nothing left after redaction")
        tags = normalize_tags(aux.tags)
        entities = extract_entities(body)[:16]
        injection = gate.injection_labels(body)
        aux_injection = gate.injection_labels("\n".join(_aux_strings(tags, entities, {}, None)))
        if aux_injection:
            injection = sorted(set(injection + [f"aux:{label}" for label in aux_injection]))
        superseded_by = payload.get("supersededBy")
        valid_to = payload.get("validTo")
        return (
            _RemoteFact(
                doc_id=doc_id,
                user_id=user_id,
                memory_id=memory_id,
                project_id=project_id,
                scope=scope,
                kind=normalize_kind(fact.kind, default="other"),
                body=body,
                # Recomputed here from the gated body with the engine's own
                # hashing. The payload's `bodyHash` is the sender's advice about
                # its own store and is deliberately never trusted as the key.
                body_hash=sha256_hex(body.lower()),
                confidence=fact.confidence,
                valid_from=_canonical_iso(payload.get("validFrom")) or updated_at,
                valid_to=_canonical_iso(valid_to) if valid_to else None,
                superseded_by=str(superseded_by) if superseded_by else None,
                updated_at=updated_at,
                updated_ts=updated_ts,
                sensitivity=decision.sensitivity,
                review_status="quarantined" if injection else "approved",
                tags=tags,
                entities=entities,
                gate_labels=sorted(set(decision.labels + aux.labels)),
                injection=injection,
            ),
            {},
        )

    def merge_remote(self, rows: Sequence[dict[str, Any]]) -> dict[str, Any]:
        """Fold the opened remote rows the daemon parked for this device into the
        local store, applying §5 of the blind-sync design.

        `rows` are `agent_memory_inbox` entries — `{docID, userID, engineMemoryID,
        payloadJSON, remoteUpdatedAt}` — whose `payloadJSON` is the opened
        `MemoryCloudFactPayload`. The engine never sees the vault key: the daemon
        hands it plaintext it has already verified, so everything here is
        ordering, convergence, and the same gate a local write passes.

        `ackDocIDs` names the documents the engine is finished with: applied,
        folded in, already applied, or refused for good. A document left parked —
        a supersede whose target has not arrived, a payload with no engine project
        identity — is deliberately NOT in it, so the next pull offers it again.
        """
        screened: list[_RemoteFact] = []
        decisions: list[dict[str, Any]] = []
        ack: list[str] = []
        parked: list[str] = []
        applied = reinforced = unchanged = refused = 0
        for raw in rows:
            fact, stopped = self._screen_remote_row(raw)
            if fact is None:
                terminal = bool(stopped.pop("ack"))
                (ack if terminal else parked).append(str(stopped.get("docID") or ""))
                refused += 1 if terminal else 0
                decisions.append(stopped)
                continue
            screened.append(fact)
        screened.sort(key=lambda item: item.order_key)

        merged: list[tuple[_RemoteFact, dict[str, Any]]] = []
        for fact in screened:
            decision = self._merge_remote_fact(fact)
            merged.append((fact, decision))
            event = decision["event"]
            if event in ("ADD", "UPDATE"):
                applied += 1
            elif event == "REINFORCE":
                reinforced += 1
            elif event == "REFUSE":
                refused += 1
            else:
                unchanged += 1
            if event != "REFUSE":
                self._advance_sync_watermark(fact)

        # Second pass. A supersede references an engine id, which is globally
        # unique, so a chain resolves on any device — but only once its target
        # has arrived. Every edge the batch itself supplied lands here; one whose
        # target is still missing leaves its document unacknowledged.
        for fact, decision in merged:
            resolved = True
            if fact.superseded_by and decision["event"] != "REFUSE":
                resolved = self._resolve_remote_supersede(fact, str(decision.get("memoryID") or fact.memory_id))
                decision["supersedeResolved"] = resolved
            (ack if resolved else parked).append(fact.doc_id)
            decisions.append(decision)

        if applied or reinforced or refused:
            audit_event(
                self.conn,
                action="memory.sync_merge",
                project_id=None,
                subject_id=None,
                labels=[
                    f"applied:{applied}",
                    f"reinforced:{reinforced}",
                    f"refused:{refused}",
                    f"parked:{len(parked)}",
                ],
                actor=self.config.actor,
            )
        self._commit()
        self._invalidate_cache()
        return {
            "status": "ok",
            "applied": applied,
            "reinforced": reinforced,
            # A parked document is one the engine is not finished with. Its
            # content may already have been applied — a supersede edge can be
            # pending on a row that landed — so this is not disjoint from
            # `applied`; it counts what the next pull must offer again.
            "parked": len(parked),
            "refused": refused,
            "unchanged": unchanged,
            "ackDocIDs": [doc_id for doc_id in ack if doc_id],
            "parkedDocIDs": [doc_id for doc_id in parked if doc_id],
            "watermark": self.sync_watermark(),
            "decisions": decisions,
        }

    def _merge_remote_fact(self, fact: _RemoteFact) -> dict[str, Any]:
        """Land one screened remote row: never resurrect, converge, then LWW."""
        local_id = self._local_memory_id(fact.memory_id)
        # `UNIQUE(project_id, scope, body_hash)` spans retired rows, so there is
        # at most one local holder of this convergence identity, ever.
        holder = self.conn.execute(
            "SELECT id, valid_to FROM memories WHERE project_id = ? AND scope = ? AND body_hash = ?",
            (fact.project_id, fact.scope, fact.body_hash),
        ).fetchone()
        if local_id is None and holder is None:
            # Nothing local answers to this row. Only now does a forget receipt
            # mean anything: a member who said this again on this device brought
            # the memory back themselves, and that decision outranks the receipt.
            forgotten = self._forgotten(fact.memory_id, fact.project_id, fact.scope, fact.body_hash)
            if forgotten is not None:
                audit_event(
                    self.conn,
                    action="memory.sync_resurrection_refused",
                    project_id=fact.project_id,
                    subject_id=fact.memory_id,
                    labels=["forgotten:by_identity" if forgotten.startswith("forget_identity:") else "forgotten:by_id"],
                    actor=self.config.actor,
                )
                return {
                    "event": "REFUSE",
                    "code": "LOCALLY_FORGOTTEN",
                    "reason": "this device forgot this memory; a remote copy must not revive it",
                    "docID": fact.doc_id,
                    "memoryID": fact.memory_id,
                }
            return self._write_remote_row(fact, fact.memory_id, existing=None)
        if local_id is None and holder is not None:
            local_id = str(holder["id"])
            self._record_memory_alias(fact.memory_id, local_id)
            if holder["valid_to"] is None and fact.valid_to is None and not fact.superseded_by:
                # The same fact, learned independently on two devices: it folds
                # into a reinforcement of the row that already holds the identity,
                # exactly as a local duplicate does today (§5).
                return self._reinforce_remote(fact, local_id)
        return self._update_remote_row(fact, str(local_id))

    def _reinforce_remote(self, fact: _RemoteFact, memory_id: str) -> dict[str, Any]:
        decision = self._reinforce(
            memory_id,
            Fact(text=fact.body, kind=fact.kind, confidence=fact.confidence, tags=list(fact.tags)),
            fact.entities,
            reason="remote duplicate",
            incoming_body=fact.body,
            labels=fact.gate_labels,
            quarantine_labels=[f"aux:{label}" for label in fact.injection],
        )
        return {
            "event": "REINFORCE",
            "code": "CONVERGED",
            "docID": fact.doc_id,
            "memoryID": memory_id,
            "remoteMemoryID": fact.memory_id,
            "kind": decision.get("kind"),
            "scope": decision.get("scope"),
            "text": decision.get("text"),
            "reviewStatus": decision.get("reviewStatus"),
        }

    def _update_remote_row(self, fact: _RemoteFact, memory_id: str) -> dict[str, Any]:
        row = self.conn.execute(
            "SELECT rowid, project_id, body_hash, updated_at, immutable FROM memories WHERE id = ?", (memory_id,)
        ).fetchone()
        if row is None:  # pragma: no cover — `_local_memory_id` proved it exists
            return self._write_remote_row(fact, fact.memory_id, existing=None)
        if str(row["project_id"]) != fact.project_id:
            return {
                "event": "REFUSE",
                "code": "PROJECT_MISMATCH",
                "reason": "the local memory with this id belongs to a different project",
                "docID": fact.doc_id,
                "memoryID": memory_id,
            }
        local_mark = (_parse_iso(str(row["updated_at"])) or _EPOCH, str(row["body_hash"]))
        remote_mark = (fact.updated_ts, fact.body_hash)
        if remote_mark <= local_mark:
            # Last-writer-wins: the local revision is at least as new. This is
            # also the idempotence gate — replaying a batch lands here.
            return {
                "event": "UNCHANGED",
                "code": "ALREADY_APPLIED" if remote_mark == local_mark else "LOCAL_IS_NEWER",
                "docID": fact.doc_id,
                "memoryID": memory_id,
            }
        if bool(row["immutable"]):
            return {
                "event": "UNCHANGED",
                "code": "IMMUTABLE_LOCAL",
                "reason": "the local memory is immutable and a remote revision may not replace it",
                "docID": fact.doc_id,
                "memoryID": memory_id,
            }
        clash = self.conn.execute(
            "SELECT id FROM memories WHERE project_id = ? AND scope = ? AND body_hash = ? AND id != ?",
            (fact.project_id, fact.scope, fact.body_hash, memory_id),
        ).fetchone()
        if clash is not None:
            # The revision's body is one another local row already holds. The
            # identity is unique, so the two converge: reinforce the holder and
            # retire the row this revision came from into it.
            holder = str(clash["id"])
            self._record_memory_alias(fact.memory_id, holder)
            self._retire(memory_id, reason="converged into an identical remote fact", replacement=holder)
            return self._reinforce_remote(fact, holder)
        return self._write_remote_row(fact, memory_id, existing=row)

    def _write_remote_row(self, fact: _RemoteFact, memory_id: str, *, existing: Any) -> dict[str, Any]:
        """Insert or overwrite one row from a remote revision.

        `memories.updated_at` takes the payload's `updatedAt` verbatim — that
        authenticated instant, not this device's clock, is what LWW compares, so
        stamping it locally would make a genuinely newer remote edit look stale.
        """
        metadata: dict[str, Any] = {}
        if fact.gate_labels:
            metadata["gateLabels"] = fact.gate_labels
        if fact.injection:
            metadata["injectionLabels"] = fact.injection
        salience = self.compute_salience(fact.kind, fact.confidence, 0)
        relations = extract_relations(fact.body)
        # External embedding must never run while the write lock is held; each
        # row stays independently durable (mirrors `_commit_fact`).
        if self.conn.in_transaction:
            self._commit()
        vector = self.provider.embed([fact.body])[0] if self.provider.available else None
        if not self.conn.in_transaction:
            self.conn.execute("BEGIN IMMEDIATE")
        cipher, nonce = self._seal_body(memory_id, fact.project_id, fact.body)
        columns = (
            fact.scope,
            fact.kind,
            cipher,
            nonce,
            self.keyring.key_id,
            fact.body_hash,
            fact.sensitivity,
            fact.review_status,
            fact.confidence,
            salience,
            fact.valid_from,
            fact.valid_to,
            _json_dumps(fact.tags),
            _json_dumps(fact.entities),
            _json_dumps(metadata),
            REMOTE_SOURCE_KIND,
            # `(memory_id, updated_at)` is the record key §5 names; keeping it on
            # the row makes the revision this body came from readable after the fact.
            f"sync:{fact.memory_id}:{fact.updated_at}",
            "blind-sync",
            self.provider.version_id if vector is not None else None,
            fact.updated_at,
            memory_id,
        )
        if existing is None:
            self.conn.execute(
                """
                INSERT INTO memories (
                    scope, kind, body_cipher, body_nonce, key_id, body_hash, sensitivity, review_status,
                    confidence, salience, valid_from, valid_to, tags_json, entities_json, metadata_json,
                    source_kind, source_hash, extractor, embedding_version, updated_at, id,
                    access_count, immutable, superseded_by, supersedes_json, created_at, project_id
                ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,0,0,NULL,'[]',?,?)
                """,
                (*columns, fact.valid_from, fact.project_id),
            )
            rowid = int(self.conn.execute("SELECT rowid FROM memories WHERE id = ?", (memory_id,)).fetchone()["rowid"])
            event = "ADD"
        else:
            self.conn.execute(
                """
                UPDATE memories SET
                    scope = ?, kind = ?, body_cipher = ?, body_nonce = ?, key_id = ?, body_hash = ?,
                    sensitivity = ?, review_status = ?, confidence = ?, salience = ?, valid_from = ?,
                    valid_to = ?, tags_json = ?, entities_json = ?, metadata_json = ?, source_kind = ?,
                    source_hash = ?, extractor = ?, embedding_version = ?, updated_at = ?,
                    -- The payload's `supersededBy` is authoritative for this row, and it is
                    -- landed by the edge pass once its target resolves. Clearing it here is
                    -- what lets a revision that dropped the edge actually drop it.
                    superseded_by = NULL
                WHERE id = ?
                """,
                columns,
            )
            rowid = int(existing["rowid"])
            event = "UPDATE"
        self.conn.execute("DELETE FROM memory_vectors WHERE memory_rowid = ?", (rowid,))
        if vector is not None:
            self.conn.execute(
                "INSERT INTO memory_vectors (memory_rowid, embedding_version, dimension, vector) VALUES (?, ?, ?, ?)",
                (rowid, self.provider.version_id, len(vector), encode_vector(vector)),
            )
        self.conn.execute("DELETE FROM memory_relations WHERE memory_id = ?", (memory_id,))
        for subject, predicate, obj in relations:
            self.conn.execute(
                "INSERT INTO memory_relations (project_id, memory_id, subject, predicate, object, slot_key, confidence) VALUES (?,?,?,?,?,?,?)",
                (fact.project_id, memory_id, subject, predicate, obj, _slot_key(subject, predicate), fact.confidence),
            )
        self._history(
            memory_id,
            fact.project_id,
            "merged_remote",
            None,
            fact.body,
            {"remoteMemoryID": fact.memory_id, "updatedAt": fact.updated_at, "event": event},
        )
        if fact.injection:
            audit_event(
                self.conn,
                action="memory.injection_quarantined",
                project_id=fact.project_id,
                subject_id=memory_id,
                labels=fact.injection,
                actor=self.config.actor,
            )
        audit_event(
            self.conn,
            action="memory.sync_add" if event == "ADD" else "memory.sync_update",
            project_id=fact.project_id,
            subject_id=memory_id,
            labels=[
                f"kind:{fact.kind}",
                f"scope:{fact.scope}",
                f"sensitivity:{fact.sensitivity}",
                f"review:{fact.review_status}",
                "retired" if fact.valid_to else "active",
            ],
            actor=self.config.actor,
        )
        return {
            "event": event,
            "docID": fact.doc_id,
            "memoryID": memory_id,
            "remoteMemoryID": fact.memory_id,
            "kind": fact.kind,
            "scope": fact.scope,
            "text": fact.body,
            "tags": list(fact.tags),
            "confidence": fact.confidence,
            "sensitivity": fact.sensitivity,
            "reviewStatus": fact.review_status,
            "labels": list(fact.gate_labels),
            "injectionLabels": list(fact.injection),
            "retired": fact.valid_to is not None,
            "embedded": vector is not None,
        }

    def _resolve_remote_supersede(self, fact: _RemoteFact, memory_id: str) -> bool:
        """Land one supersede edge, and rebuild its inverse on this side.

        `supersedes_json` deliberately does not travel: it is the inverse of
        `supersededBy` and is rebuilt here from the edge that did. Returns False
        when the target has not arrived, which is what parks the document.
        """
        target = self._local_memory_id(fact.superseded_by or "")
        if target is None:
            return False
        if target == memory_id:
            # The edge points at the row it is on: either a corrupt payload, or
            # the successor converged into this very row. There is nothing left
            # to resolve, so it is finished rather than parked for ever.
            return True
        row = self.conn.execute("SELECT superseded_by FROM memories WHERE id = ?", (memory_id,)).fetchone()
        if row is None:
            return False
        if row["superseded_by"] != target:
            self.conn.execute("UPDATE memories SET superseded_by = ? WHERE id = ?", (target, memory_id))
            self._history(
                memory_id,
                fact.project_id,
                "merged_remote_supersede",
                None,
                None,
                {"supersededBy": target, "remoteSupersededBy": fact.superseded_by},
            )
        inverse = self.conn.execute("SELECT supersedes_json FROM memories WHERE id = ?", (target,)).fetchone()
        supersedes = sorted({*_json_loads(inverse["supersedes_json"], []), memory_id}) if inverse is not None else []
        if inverse is not None and supersedes != _json_loads(inverse["supersedes_json"], []):
            self.conn.execute("UPDATE memories SET supersedes_json = ? WHERE id = ?", (_json_dumps(supersedes), target))
        return True

    def _advance_sync_watermark(self, fact: _RemoteFact) -> None:
        """Move this member's applied high-water mark forward, never back."""
        row = self.conn.execute(
            "SELECT applied_updated_at, applied_memory_id, applied_count FROM sync_state WHERE user_id = ?",
            (fact.user_id,),
        ).fetchone()
        count = int(row["applied_count"]) + 1 if row is not None else 1
        mark = (fact.updated_at, fact.memory_id)
        if row is not None:
            held = (str(row["applied_updated_at"]), str(row["applied_memory_id"]))
            if (_parse_iso(held[0]) or _EPOCH, held[1]) > (fact.updated_ts, fact.memory_id):
                mark = held
        self.conn.execute(
            """
            INSERT INTO sync_state (user_id, applied_updated_at, applied_memory_id, applied_count, merged_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(user_id) DO UPDATE SET
                applied_updated_at = excluded.applied_updated_at,
                applied_memory_id = excluded.applied_memory_id,
                applied_count = excluded.applied_count,
                merged_at = excluded.merged_at
            """,
            (fact.user_id, mark[0], mark[1], count, now_iso()),
        )

    def _scan_aux_value(self, text: str) -> list[str]:
        """Secret labels in one stored auxiliary string.

        Also scans the uppercased form. The rows this hunts for leaked precisely
        because a tag was lowercased before the gate saw it, so `AKIA…` no longer
        matched its case-sensitive corpus pattern; scanning only the stored form
        would miss exactly the rows worth reporting.
        """
        labels = list(gate.scan_text(text).secret_labels)
        if not labels and text != text.upper():
            labels = list(gate.scan_text(text.upper()).secret_labels)
        return labels

    def aux_secret_exposure(
        self, project_id: str | None, *, limit: int | None = None, after_rowid: int = 0
    ) -> dict[str, Any]:
        """Rows whose plaintext auxiliary columns still hold a secret, plus how
        much of the store the sweep actually covered.

        Auxiliary fields are gated on their raw form now, but rows written before
        that fix can carry a credential in the plaintext `tags_json` column, and
        nothing re-examines a row once it is written. Superseded revisions are
        scanned too: retiring a row does not remove its plaintext from the file.

        The coverage half matters as much as the result. An empty list from a
        capped, corpus-less, or project-less sweep is byte-identical to an empty
        list from a complete one, so `scan` always records which it was:
        `{"rowsScanned", "rowsTotal", "truncated", "skipped", "nextCursor"}`,
        where `skipped` is None, "corpus_unavailable" or "no_project".

        `after_rowid` resumes the sweep past a row already covered, and a
        truncated sweep returns the last rowid it looked at as
        `scan["nextCursor"]`. Without that, a store over the cap had rows no
        invocation could ever reach.
        """
        cap = AUX_SCAN_ROW_LIMIT if limit is None else limit
        cursor = max(0, int(after_rowid or 0))
        scan: dict[str, Any] = {
            "rowsScanned": 0,
            "rowsTotal": 0,
            "truncated": False,
            "skipped": None,
            "nextCursor": None,
        }
        if project_id is None:
            scan["skipped"] = "no_project"
            return {"exposures": [], "scan": scan}
        # `rowsTotal` counts what is still ahead of the cursor, so "N of M rows
        # scanned" stays true of the page the caller actually asked for.
        scan["rowsTotal"] = int(
            self.conn.execute(
                "SELECT COUNT(*) FROM memories WHERE project_id = ? AND rowid > ?", (project_id, cursor)
            ).fetchone()[0]
        )
        if not gate.GATE_CORPUS_AVAILABLE:
            # Fail loud, not quiet: with no corpus every row would read as clean.
            scan["skipped"] = "corpus_unavailable"
            return {"exposures": [], "scan": scan}
        # `rowid` rather than `id`: insertion order is stable, so a truncated
        # sweep covers a prefix an operator can reason about -- and resume from.
        rows = self.conn.execute(
            "SELECT rowid AS scan_rowid, id, valid_to, tags_json, entities_json, metadata_json, "
            "source_ref, source_kind "
            "FROM memories WHERE project_id = ? AND rowid > ? ORDER BY rowid LIMIT ?",
            (project_id, cursor, cap),
        ).fetchall()
        scan["rowsScanned"] = len(rows)
        scan["truncated"] = len(rows) < scan["rowsTotal"]
        if scan["truncated"] and rows:
            scan["nextCursor"] = int(rows[-1]["scan_rowid"])
        exposures: list[dict[str, Any]] = []
        for row in rows:
            tags = _json_loads(row["tags_json"], [])
            entities = _json_loads(row["entities_json"], [])
            metadata = _json_loads(row["metadata_json"], {})
            revision = "active" if row["valid_to"] is None else "superseded"
            surfaces: tuple[tuple[str, list[str]], ...] = (
                ("tags", _aux_strings(tags, [], None, None)),
                ("entities", _aux_strings([], entities, None, None)),
                ("metadata", _aux_strings([], [], metadata, None)),
                ("sourceRef", _aux_strings([], [], None, row["source_ref"])),
                ("sourceKind", [str(row["source_kind"])] if row["source_kind"] else []),
            )
            for surface, values in surfaces:
                labels = sorted({label for value in values for label in self._scan_aux_value(str(value))})
                if labels:
                    exposures.append({"id": str(row["id"]), "surface": surface, "revision": revision, "labels": labels})
        return {"exposures": exposures, "scan": scan}

    def doctor(self, *, project_path: str | None = None, aux_scan_cursor: int | None = None) -> dict[str, Any]:
        db_path = self.db_path or default_db_path()
        # Resolved first: the auxiliary-exposure scan below is per project, so it
        # has to know which one before the findings are assembled.
        project_extra: dict[str, Any] = {}
        active_project_id: str | None = None
        if project_path or os.environ.get("OPENBURNBAR_ACTIVE_PROJECT_PATH"):
            try:
                active_project_id, root = resolve_project(self.conn, project_path)
                project_extra = dict(project_payload(active_project_id, root))
            except ValueError as exc:
                project_extra = {"projectError": str(exc)}
        aux = self.aux_secret_exposure(active_project_id, after_rowid=aux_scan_cursor or 0)
        exposures, aux_scan = aux["exposures"], aux["scan"]
        undecryptable = 0
        rows = self.conn.execute("SELECT id, project_id, body_cipher, body_nonce FROM memories LIMIT 500").fetchall()
        for row in rows:
            if self._open_body(str(row["id"]), str(row["project_id"]), row["body_cipher"], row["body_nonce"]) is None:
                undecryptable += 1
        total = int(self.conn.execute("SELECT COUNT(*) FROM memories").fetchone()[0])
        findings: list[dict[str, Any]] = []
        if undecryptable:
            findings.append(
                {
                    "severity": "error",
                    "code": "UNDECRYPTABLE_ROWS",
                    "detail": f"{undecryptable} of {len(rows)} sampled rows cannot be decrypted with key {self.keyring.key_id} ({self.keyring.source}).",
                }
            )
        if not gate.GATE_CORPUS_AVAILABLE:
            findings.append(
                {
                    "severity": "error",
                    "code": "SECRET_CORPUS_UNAVAILABLE",
                    "detail": "secret-pattern-corpus.json not found; writes fail closed.",
                }
            )
        if not self.provider.available:
            findings.append(
                {
                    "severity": "warn",
                    "code": "EMBEDDINGS_UNAVAILABLE",
                    "detail": self.provider.describe().get("reason")
                    or self.provider.describe().get("error")
                    or "lexical-only recall",
                    "fix": f"Run `ollama pull {DEFAULT_EMBEDDING_MODEL}` and keep Ollama running, or set {EMBEDDING_PROVIDER_ENV}=none to silence.",
                }
            )
        if total > MAX_MEMORIES_PER_PROJECT_SOFT:
            findings.append(
                {
                    "severity": "warn",
                    "code": "LARGE_STORE",
                    "detail": f"{total} memories; in-process BM25 stays fast into the tens of thousands but consider pruning.",
                }
            )
        if exposures:
            affected = sorted({str(item["id"]) for item in exposures})
            surfaces = ", ".join(sorted({str(item["surface"]) for item in exposures}))
            superseded = sum(1 for item in exposures if item["revision"] == "superseded")
            findings.append(
                {
                    "severity": "error",
                    "code": "AUX_SECRET_EXPOSURE",
                    "detail": f"{len(affected)} of {aux_scan['rowsScanned']} scanned rows carry a secret in a "
                    f"plaintext auxiliary column ({surfaces}); {superseded} on superseded revisions. "
                    "Rows written before auxiliary fields were gated on their raw form can hold one.",
                    "fix": "Forget the affected memories, or `update` them with clean tags / entities / metadata.",
                }
            )
        if aux_scan["truncated"] or aux_scan["skipped"]:
            reasons = {
                "corpus_unavailable": "the secret-pattern corpus is unavailable, so no row could be classified",
                "no_project": "no project resolved, so there was nothing to scan",
            }
            because = reasons.get(str(aux_scan["skipped"]), f"the {AUX_SCAN_ROW_LIMIT}-row scan cap was reached")
            findings.append(
                {
                    "severity": "warn",
                    "code": "AUX_SCAN_INCOMPLETE",
                    "detail": f"{aux_scan['rowsScanned']} of {aux_scan['rowsTotal']} rows scanned for auxiliary "
                    f"secrets: {because}. An empty auxSecretExposure list does not mean the store is clean.",
                    "fix": (
                        "Re-run doctor with the project resolved and the corpus present, or resume the sweep with "
                        f"aux_scan_cursor={aux_scan['nextCursor']}."
                        if aux_scan["nextCursor"]
                        else "Re-run doctor with the project resolved and the corpus present, or scan in batches."
                    ),
                }
            )
        chain = verify_audit_chain(self.conn)
        if not chain["ok"]:
            findings.append(
                {
                    "severity": "error",
                    "code": "AUDIT_CHAIN_BROKEN",
                    "detail": f"hash chain breaks at seq {chain['brokenAtSeq']}",
                }
            )
        payload: dict[str, Any] = {
            "status": "ok" if not any(item["severity"] == "error" for item in findings) else "degraded",
            "engine": {
                "schemaVersion": ENGINE_SCHEMA_VERSION,
                "dbPath": str(db_path),
                "dbExists": db_path.exists(),
                "memories": total,
            },
            "encryption": {
                "algorithm": "AES-256-GCM",
                "keyID": self.keyring.key_id,
                "keySource": self.keyring.source,
                "undecryptableSampled": undecryptable,
            },
            "embedding": self.provider.describe(),
            "embeddingPending": self.embedding_pending(project_id=active_project_id),
            "policy": {
                "secret": self.config.secret_policy,
                "pii": self.config.pii_policy,
                "retainAllowed": self.config.retain_allowed,
                "corpusAvailable": gate.GATE_CORPUS_AVAILABLE,
                "auxSecretExposures": len(exposures),
            },
            "auditChain": chain,
            "auxScan": aux_scan,
            "auxSecretExposure": exposures,
            "findings": findings,
        }
        payload.update(project_extra)
        return payload
