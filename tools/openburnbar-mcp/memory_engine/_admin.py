"""`MemoryEngine`'s maintenance surface, mixed into the engine class.

Only methods live here; construction and shared state stay in `engine.py`."""

from __future__ import annotations

import os
from collections.abc import Sequence
from typing import Any

from . import gate
from ._util import (
    _aux_strings,
    _ingest_decision,
    _json_dumps,
    _json_loads,
    now_iso,
    sha256_hex,
)
from .constants import (
    DEFAULT_EMBEDDING_MODEL,
    EMBEDDING_PROVIDER_ENV,
    ENGINE_SCHEMA_VERSION,
    MAX_MEMORIES_PER_PROJECT_SOFT,
)
from .embeddings import encode_vector
from .extract import Fact
from .store import audit_event, default_db_path, project_payload, resolve_project, verify_audit_chain


# The auxiliary-exposure sweep is a regex pass over short strings, so the cap is
# generous: 5,000 rows costs a small fraction of a `doctor` call. It exists so a
# pathological store cannot make `doctor` hang, and whenever it bites, the scan
# says so rather than returning a quietly partial answer.
AUX_SCAN_ROW_LIMIT = 5_000


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
