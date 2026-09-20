"""The sync ledger — what blind sync leaves behind for the doctor to read.

`_sync.py` decides what a remote revision means; this module holds the notes
that decision leaves in `engine_meta` and the read-only queries that surface
them: lineage holds and the gaps they lapse into, parked supersedes, receipt
coverage, orphan bodies, and both halves of the watermark.

Everything here is plaintext by construction — `engine_meta` is not sealed — so
**no member content may reach it**: ids, hashes, counts and timestamps only.
`memories` seals every body through the keyring, and a note that copied one
would be the single cleartext copy of the text blind sync exists to deny.

Only methods live here; construction and shared state stay in `engine.py`."""

from __future__ import annotations

import time
from typing import TYPE_CHECKING, Any

import project_code_memory as pcm

from ._util import _convergence_key, _json_dumps, _json_loads, _receipt_payload, now_iso
from .constants import LINEAGE_HOLD_QUEUE_MAX_SIZE, REMOTE_TEAM_ID_RE
from .store import audit_event

if TYPE_CHECKING:  # pragma: no cover — annotations only; importing it would be circular
    from ._sync import _RemoteFact


class _SyncLedger:
    """Blind sync's own bookkeeping, and the doctor's read of it."""

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

    def transport_watermarks(self) -> dict[str, dict[str, Any]]:
        """The transport layer's remote watermarks, if remote_sync_watermarks exists."""
        if "remote_sync_watermarks" not in pcm.table_names(self.conn):
            return {}
        rows = self.conn.execute(
            "SELECT accountUid, collectionKind, lastSyncedAt, lastProcessedRemoteUpdateAt, version "
            "FROM remote_sync_watermarks WHERE collectionKind = 'memory_facts' ORDER BY accountUid"
        ).fetchall()
        return {
            str(row["accountUid"]): {
                "accountUid": str(row["accountUid"]),
                "collectionKind": str(row["collectionKind"]),
                "lastSyncedAt": str(row["lastSyncedAt"]),
                "lastProcessedRemoteUpdateAt": str(row["lastProcessedRemoteUpdateAt"])
                if row["lastProcessedRemoteUpdateAt"]
                else None,
                "version": int(row["version"]),
            }
            for row in rows
        }

    def _record_lineage_hold(
        self,
        fact: _RemoteFact,
        memory_id: str,
        expected_hash: str,
        actual_hash: str,
        now_epoch: float | None = None,
    ) -> bool:
        """Note that this row's `previousBodyHash` names a body this device never saw.

        Returns whether the note was admitted. A full queue means the caller must
        NOT park the document: a parked row with no note is a row whose timeout
        can never elapse.

        **Keyed by the LOCAL row id the comparison ran against**, never by the
        engine id the revision arrived under. The two differ the moment a remote
        id converges into a local row — the ordinary outcome of
        `_decide_remote_fact`'s convergence path, and the reason the
        `memory_alias` namespace exists. A note filed under the arriving id is
        looked for under the local one, never found, and the timeout branch
        below becomes unreachable: the document is held for ever and the
        advisory signal has silently become an admission gate, which A1(iii)
        forbids.

        The note is a *marker*, never a copy of the document. `memories` seals
        every body through the keyring; `engine_meta` is plaintext, so nothing
        that reaches this table may carry the fact's text, tags, entities or any
        other member content — only ids, hashes and timestamps. The held
        document itself stays UNACKED in the daemon's inbox and is re-offered on
        every drain, so the re-evaluation the timeout needs is driven by that
        redelivery rather than by anything stored here.

        Persisted under `lineage_hold:<memory_id>`, bounded by
        `LINEAGE_HOLD_QUEUE_MAX_SIZE`, because a queue that grows without bound
        is a queue an unreachable peer can use to fill the store.

        **A full queue refuses the NEWEST note, it does not evict the oldest.**
        Dropping the oldest handed a hostile peer the whole queue: a hundred
        bogus gaps evicted every genuine hold, and an evicted row's next
        redelivery started its clock again from zero, so a flood could stall a
        replica for ever — the exact failure the timeout exists to prevent.
        Refusing the newcomer instead costs it nothing that matters: lineage is
        advice, so a row that cannot be held simply has LWW applied now, which
        is the answer the timeout reaches anyway, and the gap is reported.
        """
        existing_hold = self._get_lineage_hold(memory_id)
        if existing_hold is not None and "firstSeenEpoch" in existing_hold:
            first_seen_epoch = float(existing_hold["firstSeenEpoch"])
            first_seen_iso = str(existing_hold.get("firstSeen") or now_iso())
        else:
            first_seen_epoch = time.time() if now_epoch is None else now_epoch
            first_seen_iso = now_iso()

        if existing_hold is None:
            held = int(
                self.conn.execute("SELECT COUNT(*) FROM engine_meta WHERE key LIKE 'lineage_hold:%'").fetchone()[0]
            )
            if held >= LINEAGE_HOLD_QUEUE_MAX_SIZE:
                return False

        self.conn.execute(
            "INSERT OR REPLACE INTO engine_meta (key, value) VALUES (?, ?)",
            (
                f"lineage_hold:{memory_id}",
                _json_dumps(
                    {
                        "memoryID": memory_id,
                        "docID": fact.doc_id,
                        "previousBodyHash": expected_hash,
                        "expectedHash": expected_hash,
                        "actualHash": actual_hash,
                        "firstSeen": first_seen_iso,
                        "firstSeenEpoch": first_seen_epoch,
                    }
                ),
            ),
        )
        return True

    def _get_lineage_hold(self, memory_id: str) -> dict[str, Any] | None:
        row = self.conn.execute(
            "SELECT value FROM engine_meta WHERE key = ?",
            (f"lineage_hold:{memory_id}",),
        ).fetchone()
        if row is None:
            return None
        try:
            return _json_loads(row["value"], None)
        except (ValueError, TypeError):
            return None

    def _clear_lineage_hold(self, memory_id: str, *also: str) -> None:
        """Drop the hold on a row, and any note left under an id that folded into it.

        `also` exists for stores written before the note was keyed on the local
        row: a stale `lineage_hold:<remote id>` nothing reads any more would
        otherwise sit in the bounded queue for ever, evicting genuine holds.
        """
        keys = {memory_id, *(other for other in also if other)}
        self.conn.executemany(
            "DELETE FROM engine_meta WHERE key = ?", [(f"lineage_hold:{key}",) for key in sorted(keys)]
        )

    def lineage_holds(self) -> list[dict[str, Any]]:
        """Every open lineage hold: ids, hashes and timestamps, never a body."""
        rows = self.conn.execute("SELECT value FROM engine_meta WHERE key LIKE 'lineage_hold:%'").fetchall()
        return [hold for hold in (_json_loads(row["value"], None) for row in rows) if isinstance(hold, dict)]

    def _record_unresolved_gap(
        self, fact: _RemoteFact, memory_id: str, expected_hash: str, actual_hash: str | None
    ) -> None:
        """Report a lapsed hold against the LOCAL row, for the same reason the
        hold itself is keyed there: a converged remote id names a row this store
        does not have, and the doctor finding, the audit subject and the hold
        have to be about the same thing. The arriving id stays in the payload."""
        data = {
            "memoryID": memory_id,
            "remoteMemoryID": fact.memory_id,
            "docID": fact.doc_id,
            "expectedHash": expected_hash,
            "actualHash": actual_hash,
            "reportedAt": now_iso(),
        }
        self.conn.execute(
            "INSERT OR REPLACE INTO engine_meta (key, value) VALUES (?, ?)",
            (f"unresolved_gap:{memory_id}", _json_dumps(data)),
        )
        audit_event(
            self.conn,
            action="memory.sync_unresolved_gap",
            project_id=fact.project_id,
            subject_id=memory_id,
            labels=[
                "gap:unresolved",
                f"expected:{expected_hash[:8]}",
                f"actual:{(actual_hash or 'none')[:8]}",
            ],
            actor=self.config.actor,
        )

    def unresolved_gaps(self) -> list[dict[str, Any]]:
        rows = self.conn.execute("SELECT value FROM engine_meta WHERE key LIKE 'unresolved_gap:%'").fetchall()
        gaps = []
        for r in rows:
            val = _json_loads(r["value"], None)
            if isinstance(val, dict):
                gaps.append(val)
        return gaps

    def parked_supersedes(self) -> list[dict[str, Any]]:
        """Parked supersedes waiting for targets across inbox, engine_meta, and memories."""
        parked: list[dict[str, Any]] = []
        tables = pcm.table_names(self.conn)
        if "agent_memory_inbox" in tables:
            rows = self.conn.execute(
                "SELECT doc_id, user_id, engine_memory_id, payload_json, remote_updated_at, received_at "
                "FROM agent_memory_inbox WHERE applied_at IS NULL"
            ).fetchall()
            for r in rows:
                payload = _receipt_payload(dict(r))
                if isinstance(payload, dict) and payload.get("supersededBy"):
                    target = str(payload.get("supersededBy"))
                    # RESOLVED IN THE PARKED ROW'S OWN NAMESPACE. This is a
                    # read-only diagnostic, so getting it wrong misreports
                    # rather than misfiles — but an unnamespaced lookup asks the
                    # personal alias space about a TEAM edge and would report a
                    # resolvable team supersede as parked (and, in the other
                    # direction, quietly answer a team question with a personal
                    # row's id). Screened exactly as the merge path screens it:
                    # anything outside the token shape is no team at all.
                    row_team_id = payload.get("teamID")
                    row_team_id = str(row_team_id).strip() if row_team_id else None
                    if row_team_id is not None and not REMOTE_TEAM_ID_RE.match(row_team_id):
                        row_team_id = None
                    if self._local_memory_id(target, row_team_id) is None:
                        parked.append(
                            {
                                "source": "inbox",
                                "docID": str(r["doc_id"]),
                                "memoryID": str(r["engine_memory_id"]),
                                "targetID": target,
                                "receivedAt": str(r["received_at"] or r["remote_updated_at"] or ""),
                            }
                        )
        meta_rows = self.conn.execute(
            "SELECT key, value FROM engine_meta WHERE key LIKE 'parked_supersede:%'"
        ).fetchall()
        for mr in meta_rows:
            val = _json_loads(mr["value"], {})
            parked.append(
                {
                    "source": "engine_meta",
                    "key": str(mr["key"]),
                    "targetID": str(val.get("targetID") or val.get("supersededBy") or ""),
                    "memoryID": str(val.get("memoryID") or str(mr["key"]).split("parked_supersede:", 1)[1]),
                    "reportedAt": str(val.get("reportedAt") or val.get("ts") or ""),
                }
            )
        mem_rows = self.conn.execute(
            "SELECT id, superseded_by, updated_at FROM memories WHERE superseded_by IS NOT NULL "
            "AND superseded_by NOT IN (SELECT id FROM memories)"
        ).fetchall()
        for mr in mem_rows:
            parked.append(
                {
                    "source": "memories",
                    "memoryID": str(mr["id"]),
                    "targetID": str(mr["superseded_by"]),
                    "updatedAt": str(mr["updated_at"] or ""),
                }
            )
        return parked

    def receipt_coverage_gaps(self) -> list[dict[str, Any]]:
        """Gaps where forget receipts or convergence identities are missing."""
        gaps: list[dict[str, Any]] = []
        tables = pcm.table_names(self.conn)
        receipt_rows = self.conn.execute(
            "SELECT key, value FROM engine_meta WHERE key LIKE 'forget_receipt:%'"
        ).fetchall()
        for r in receipt_rows:
            mid = str(r["key"]).split("forget_receipt:", 1)[1]
            parsed = _json_loads(r["value"], None)
            if isinstance(parsed, dict) and parsed.get("bodyHash") and parsed.get("projectID") and parsed.get("scope"):
                ckey = f"forget_identity:{_convergence_key(str(parsed['projectID']), str(parsed['scope']), str(parsed['bodyHash']))}"
                has_identity = (
                    self.conn.execute("SELECT 1 FROM engine_meta WHERE key = ?", (ckey,)).fetchone() is not None
                )
                if not has_identity:
                    gaps.append(
                        {"type": "missing_identity", "memoryID": mid, "convergenceKey": ckey, "receipt": parsed}
                    )
        if "agent_memory_bodies" in tables:
            blank_rows = self.conn.execute(
                "SELECT memory_id, engine_memory_id FROM agent_memory_bodies WHERE body = ''"
            ).fetchall()
            for brow in blank_rows:
                emid = str(brow["engine_memory_id"])
                has_rcpt = (
                    self.conn.execute("SELECT 1 FROM engine_meta WHERE key = ?", (f"forget_receipt:{emid}",)).fetchone()
                    is not None
                )
                if not has_rcpt:
                    gaps.append({"type": "missing_receipt", "memoryID": emid})
        return gaps

    def orphan_memory_bodies(self) -> list[dict[str, Any]]:
        """Rows in agent_memory_bodies with no owning record in memories or agent_memories.

        `LENGTH(body)`, never `body`: this list is a doctor finding, and the
        doctor only ever counted the rows. Selecting the daemon's plaintext
        bodies into a returned Python list — one that a tool response is a
        `json.dumps` away from — is a disclosure the caller never asked for.
        """
        tables = pcm.table_names(self.conn)
        if "agent_memory_bodies" not in tables:
            return []
        if "agent_memories" in tables:
            sql = (
                "SELECT memory_id, project_id, engine_memory_id, LENGTH(body) AS body_length, "
                "body_hash, created_at, updated_at FROM agent_memory_bodies "
                "WHERE engine_memory_id NOT IN (SELECT id FROM memories) "
                "AND memory_id NOT IN (SELECT id FROM agent_memories)"
            )
        else:
            sql = (
                "SELECT memory_id, project_id, engine_memory_id, LENGTH(body) AS body_length, "
                "body_hash, created_at, updated_at FROM agent_memory_bodies "
                "WHERE engine_memory_id NOT IN (SELECT id FROM memories)"
            )
        return [dict(r) for r in self.conn.execute(sql).fetchall()]
