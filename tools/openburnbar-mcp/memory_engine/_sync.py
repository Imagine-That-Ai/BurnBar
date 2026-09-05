"""Memory Blind Sync — the merge half of
`docs/superpowers/specs/2026-09-03-memory-blind-sync-design.md` (§5).

The daemon opens the sealed `memory_facts` documents this member's other devices
wrote and parks them in `agent_memory_inbox`; everything here is what the engine
then does with that plaintext. No key material and no cryptography: only
ordering, convergence, and the same gate a local `remember` passes.

Only methods live here; construction and shared state stay in `engine.py`."""

from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass, field
from datetime import UTC, datetime
import time
from typing import Any, NamedTuple


from . import gate
from ._ledger import _SyncLedger
from ._util import (
    _aux_strings,
    _convergence_key,
    _json_dumps,
    _json_loads,
    _parse_iso,
    _receipt_payload,
    normalize_kind,
    normalize_tags,
    now_iso,
    canonical_body_hash,
)
from .constants import (
    DEFAULT_LINEAGE_GAP_TIMEOUT_SECONDS,
    MEMORY_SCOPES,
    REMOTE_MEMORY_ID_RE,
    REMOTE_PAYLOAD_SCHEMA_MAX,
    REMOTE_RECEIPT_ENTRY_KIND,
    REMOTE_RECEIPT_SCHEMA_MAX,
    REMOTE_SOURCE_KIND,
    REMOTE_WRITER_DEVICE_RE,
)
from .embeddings import encode_vector
from .extract import Fact, _slot_key, extract_entities, extract_relations
from .store import audit_event


# An alias or supersede chain this long is a cycle or a corruption, not a history.
# Bounded so a read can never hang on one.
_ALIAS_CHAIN_MAX_HOPS = 16


def _is_receipt_entry(raw: Any) -> bool:
    """A forget receipt parked beside the facts — told apart by `entryKind`.

    The daemon lifts the discriminator out of the payload onto the entry; the
    payload's own copy is authoritative. A missing `entryKind` is a fact, never
    an error.
    """
    if not isinstance(raw, dict):
        return False
    if raw.get("entryKind") == REMOTE_RECEIPT_ENTRY_KIND:
        return True
    payload = _receipt_payload(raw)
    return payload is not None and payload.get("entryKind") == REMOTE_RECEIPT_ENTRY_KIND


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
    previous_body_hash: str | None = None
    writer_device: str | None = None
    # The payload named a device and it was not a token. The fact still lands —
    # attribution is never worth refusing a member's memory over — but the field
    # is dropped and the decision says so, so a peer sending prose here is
    # visible rather than silently ignored.
    writer_device_rejected: bool = False

    @property
    def order_key(self) -> tuple[datetime, str, str]:
        """§5's total order: last-writer-wins on `updated_at`, tie-broken by
        `memory_id`. `body_hash` closes the remaining tie — two devices editing
        the same memory in the same second — so the order is total and every
        replica applies the batch identically."""
        return (self.updated_ts, self.memory_id, self.body_hash)


class _SyncMark(NamedTuple):
    """The last remote revision a local row absorbed, in §5's total order.

    `memories.updated_at` cannot serve as the last-writer mark on its own: it is
    stamped by whichever writer touched the row last, and a merge is a writer on
    this device only in the sense that it *copied* someone else's revision. The
    mark is what LWW compares a newly arriving revision against, so it records
    the remote instant, not the local clock.
    """

    updated_at: str
    updated_ts: datetime
    memory_id: str
    body_hash: str

    @property
    def order_key(self) -> tuple[datetime, str, str]:
        return (self.updated_ts, self.memory_id, self.body_hash)


class _BlindSync(_SyncLedger):
    """`MemoryEngine`'s blind-sync merge surface: watermark, screen, converge, LWW."""

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
                (f"forget_identity:{_convergence_key(project_id, scope, body_hash)}", memory_id),
            ),
        )

    def _forgotten(self, memory_id: str, project_id: str, scope: str, body_hash: str) -> str | None:
        """The forget receipt that forbids a remote row, if there is one."""
        identity = _convergence_key(project_id, scope, body_hash)
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

    def _alias_target(self, foreign_id: str) -> str | None:
        """The live row `foreign_id` folded into, if the alias still resolves.

        Two devices answer this from different evidence, and both have to agree.
        The device that did the folding holds a `memory_alias:<id>` note; a device
        that only received the rows has no note, but the folded row itself arrived
        carrying `foldedInto` in its metadata and `folded` in its tags, and its
        `superseded_by` points at the holder. So: follow the note if there is one,
        otherwise read the fold off the row, and in both cases walk the supersede
        chain to whatever is live *now* — a folded row's holder may itself have
        been superseded since.
        """
        if not foreign_id:
            return None
        row = self.conn.execute(
            "SELECT value FROM engine_meta WHERE key = ?", (f"memory_alias:{foreign_id}",)
        ).fetchone()
        if row is not None:
            # Aliases chain when a holder is itself folded away. Bounded, because a
            # loop here would hang every read that resolves an id.
            alias = str(row["value"])
            visited = {foreign_id}
            while alias not in visited and len(visited) < _ALIAS_CHAIN_MAX_HOPS:
                visited.add(alias)
                next_row = self.conn.execute(
                    "SELECT value FROM engine_meta WHERE key = ?", (f"memory_alias:{alias}",)
                ).fetchone()
                if next_row is None:
                    break
                alias = str(next_row["value"])
            target = self.conn.execute("SELECT valid_to FROM memories WHERE id = ?", (alias,)).fetchone()
            if target is None:
                return None
            return alias if target["valid_to"] is None else self._resolve_supersede_chain(alias)

        folded = self.conn.execute(
            "SELECT valid_to, superseded_by, metadata_json, tags_json FROM memories WHERE id = ?", (foreign_id,)
        ).fetchone()
        if folded is None or folded["valid_to"] is None or not folded["superseded_by"]:
            return None
        metadata = _json_loads(folded["metadata_json"], {}) or {}
        tags = _json_loads(folded["tags_json"], []) or []
        # `fold()` stamps both; a row retired for any other reason stamps neither,
        # and must not be treated as an alias.
        if metadata.get("foldedInto") or "folded" in tags:
            return self._resolve_supersede_chain(str(folded["superseded_by"]))
        return None

    def _resolve_supersede_chain(self, start_id: str) -> str | None:
        """Walk `superseded_by` from `start_id` to the row that is still live."""
        current = start_id
        visited: set[str] = set()
        while current not in visited and len(visited) < _ALIAS_CHAIN_MAX_HOPS:
            visited.add(current)
            row = self.conn.execute("SELECT valid_to, superseded_by FROM memories WHERE id = ?", (current,)).fetchone()
            if row is None:
                return None
            if row["valid_to"] is None:
                return current
            if not row["superseded_by"]:
                return None
            current = str(row["superseded_by"])
        return None

    def _local_memory_id(self, foreign_id: str) -> str | None:
        """The local row a remote engine id names: itself, or what it folded into.

        **A RETIRED row loses to its own alias.** When two rows converge, the
        loser is retired *into* the holder and an alias records the redirection —
        so a later revision of the losing engine id belongs to the holder, on
        every replica. Consulting the row before the alias sent that revision
        back to the retired loser and revived it (`_write_remote_row`'s UPDATE
        writes `valid_to = NULL`), leaving this device with two active rows for
        one convergence identity while a replica that never materialised the
        loser had one — a direct §8 divergence, and one only the replicas that
        happened to see the duplicate would suffer.

        An alias exists only where a foreign id folded into a DIFFERENT row
        (`_record_memory_alias` ignores self-aliases), so this redirection can
        never fire for a row that was merely retired by a `validTo` edit. A row
        that is retired AND aliased is exactly a converged-away loser.
        """
        if not foreign_id:
            return None
        row = self.conn.execute("SELECT valid_to FROM memories WHERE id = ?", (foreign_id,)).fetchone()
        if row is not None:
            if row["valid_to"] is None:
                return foreign_id
            return self._alias_target(foreign_id) or foreign_id
        return self._alias_target(foreign_id)

    def _sync_mark(self, memory_id: str) -> _SyncMark | None:
        """The last remote revision this row absorbed, if any.

        This — not `memories.updated_at` — is what an arriving revision is
        compared against. `updated_at` is stamped by the last *writer*, and a
        merge-driven reinforcement or retirement is not a local writer; letting
        this device's wall clock stand in for the remote instant is what would
        silently and terminally lose a genuinely newer remote edit.
        """
        row = self.conn.execute("SELECT value FROM engine_meta WHERE key = ?", (f"sync_mark:{memory_id}",)).fetchone()
        if row is None:
            return None
        held = _json_loads(str(row["value"]), None)
        if not isinstance(held, dict):
            return None
        parsed = _parse_iso(str(held.get("updatedAt") or ""))
        if parsed is None:
            return None
        return _SyncMark(
            updated_at=str(held.get("updatedAt") or ""),
            updated_ts=parsed,
            memory_id=str(held.get("memoryID") or ""),
            body_hash=str(held.get("bodyHash") or ""),
        )

    def _record_sync_mark(self, memory_id: str, fact: _RemoteFact) -> None:
        """Advance this row's applied-remote mark. It never moves backwards: the
        mark is the maximum of everything the row has absorbed, so replicas that
        received the same revisions in different orders hold the same mark."""
        held = self._sync_mark(memory_id)
        if held is not None and held.order_key >= fact.order_key:
            return
        self.conn.execute(
            "INSERT OR REPLACE INTO engine_meta (key, value) VALUES (?, ?)",
            (
                f"sync_mark:{memory_id}",
                _json_dumps({"updatedAt": fact.updated_at, "memoryID": fact.memory_id, "bodyHash": fact.body_hash}),
            ),
        )

    def _local_writer_mark(self, row: Any, applied: _SyncMark | None) -> tuple[datetime, str] | None:
        """The instant a *local* writer last touched this row, or None.

        A merge writes the remote revision's own instant into `updated_at`, so
        when the column still reads as the mark that was applied, nothing local
        has happened since and only the remote mark governs. Anything else — a
        `remember`, an `update`, a row this device authored — is a genuine local
        writer and must beat an older remote revision, which is what keeps a
        member's own edit from being overwritten by a stale copy of it.
        """
        if applied is not None and _canonical_iso(str(row["updated_at"])) == applied.updated_at:
            return None
        return (_parse_iso(str(row["updated_at"])) or _EPOCH, str(row["body_hash"]))

    def _record_convergence_identity(self, project_id: str, scope: str, body_hash: str, memory_id: str) -> None:
        """Remember which local row a body belongs to, for good.

        The live `UNIQUE(project_id, scope, body_hash)` lookup only answers while
        the row still holds that body. A device that receives an edit before it
        receives the duplicate the edit replaced would otherwise key the
        duplicate to nothing and store it as a second memory, while a device that
        received them the other way round folded them into one — the same
        documents, two different beliefs. This ledger is what makes the answer
        the same on every replica whatever order the documents arrive in.

        **Every writer keeps it, not only the merge.** A member who authors a
        fact here and then edits it here has moved the body on exactly as a pair
        of merged revisions would, and a device that only ever wrote locally is
        still a replica: if the local paths left no entry, another device's
        independently-learned copy of the superseded body would land as a second
        active row on the authoring device and fold into one everywhere else.
        `_write.py::_commit_fact` and `_read.py::update` call this for the same
        reason `_merge_remote_fact` does.
        """
        self.conn.execute(
            "INSERT OR REPLACE INTO engine_meta (key, value) VALUES (?, ?)",
            (f"sync_identity:{_convergence_key(project_id, scope, body_hash)}", memory_id),
        )

    def _converged_local_id(self, fact: _RemoteFact) -> str | None:
        """The local row a remote body was last keyed to, if it still exists."""
        row = self.conn.execute(
            "SELECT value FROM engine_meta WHERE key = ?",
            (f"sync_identity:{_convergence_key(fact.project_id, fact.scope, fact.body_hash)}",),
        ).fetchone()
        if row is None:
            return None
        memory_id = str(row["value"])
        exists = self.conn.execute("SELECT 1 FROM memories WHERE id = ?", (memory_id,)).fetchone()
        return memory_id if exists is not None else None

    def _screen_remote_row(self, raw: Any) -> tuple[_RemoteFact | None, dict[str, Any]]:
        """Parse and gate one inbox entry before anything about it is believed.

        Returns either the screened fact or the decision that ends it. That
        decision's `ack` says whether the document is finished with. Parking is
        for a gap that closes on its own: the only screening stop that parks is a
        payload sealed by a NEWER engine, which this engine will understand after
        an upgrade and which acking would silently destroy. Everything else here
        — a malformed payload, an id that is not engine-shaped, a document
        carrying no engine project identity (a v1 or chat-sourced row, which can
        never be keyed for convergence) — is terminal and acknowledged, so the
        inbox does not re-offer it for ever.
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
        if not REMOTE_MEMORY_ID_RE.match(memory_id):
            # This id becomes `memories.id` — the primary key — and is handed back
            # to the model. A local `remember` never accepts a caller-supplied id;
            # a remote one is held to exactly the shape the engine mints.
            return stop(
                "INVALID_MEMORY_ID",
                "memoryID must be an engine memory id: 'mem_' followed by 32 lowercase hex digits",
            )
        superseded_by = payload.get("supersededBy")
        superseded_by = str(superseded_by).strip() if superseded_by else None
        if superseded_by is not None and not REMOTE_MEMORY_ID_RE.match(superseded_by):
            # An edge naming an id no device can ever mint would park for ever.
            return stop(
                "INVALID_SUPERSEDE_TARGET",
                "supersededBy must be an engine memory id: 'mem_' followed by 32 lowercase hex digits",
            )
        updated_ts = _parse_iso(str(payload.get("updatedAt") or "").strip())
        if updated_ts is None:
            return stop("INVALID_UPDATED_AT", "updatedAt is not an ISO-8601 timestamp")
        updated_at = str(_canonical_iso(str(payload.get("updatedAt"))))
        project_id = str(payload.get("projectID") or "").strip()
        if not project_id:
            # §5 converges on `(project_id, scope, body_hash)`. A v1 payload, or a
            # chat memory that belongs to no engine project, cannot be keyed at
            # all — and never will be: the document is what it is. Parking it
            # would re-offer the same unmergeable row on every pull for ever, so
            # it is terminal and acknowledged.
            return stop(
                "PROJECT_IDENTITY_MISSING",
                "the payload carries no engine project id, so it can never be keyed for convergence",
            )
        scope = str(payload.get("engineScope") or "").strip().lower()
        if scope not in MEMORY_SCOPES:
            return stop("SCOPE_IDENTITY_MISSING", f"engineScope must be one of: {', '.join(MEMORY_SCOPES)}")
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
        valid_to = payload.get("validTo")
        previous_body_hash = payload.get("previousBodyHash")
        previous_body_hash = str(previous_body_hash).strip() if previous_body_hash else None
        writer_device = payload.get("writerDevice")
        writer_device = str(writer_device).strip() if writer_device else None
        # `writerDevice` is remote text that ends up in PLAINTEXT `meta_json` and
        # is reported to the calling model by the ungated timeline. A device id
        # is an opaque token; anything else — prose, an instruction, five
        # kilobytes of padding — is dropped here rather than stored. Dropping it
        # never costs the member the fact: attribution is not the memory.
        writer_device_rejected = False
        if writer_device is not None and not REMOTE_WRITER_DEVICE_RE.match(writer_device):
            writer_device = None
            writer_device_rejected = True
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
                body_hash=canonical_body_hash(body),
                confidence=fact.confidence,
                valid_from=_canonical_iso(payload.get("validFrom")) or updated_at,
                valid_to=_canonical_iso(valid_to) if valid_to else None,
                superseded_by=superseded_by,
                updated_at=updated_at,
                updated_ts=updated_ts,
                sensitivity=decision.sensitivity,
                review_status="quarantined" if injection else "approved",
                tags=tags,
                entities=entities,
                gate_labels=sorted(set(decision.labels + aux.labels)),
                injection=injection,
                previous_body_hash=previous_body_hash,
                writer_device=writer_device,
                writer_device_rejected=writer_device_rejected,
            ),
            {},
        )

    def merge_remote(
        self,
        rows: Sequence[dict[str, Any]],
        *,
        gap_timeout: float = DEFAULT_LINEAGE_GAP_TIMEOUT_SECONDS,
        now_epoch: float | None = None,
    ) -> dict[str, Any]:
        """Fold the opened remote rows the daemon parked for this device into the
        local store, applying §5 of the blind-sync design.

        `rows` are `agent_memory_inbox` entries — `{docID, userID, engineMemoryID,
        payloadJSON, remoteUpdatedAt}` — whose `payloadJSON` is the opened
        `MemoryCloudFactPayload`. The engine never sees the vault key: the daemon
        hands it plaintext it has already verified, so everything here is
        ordering, convergence, and the same gate a local write passes.

        `ackDocIDs` names the documents the engine is finished with: applied,
        folded in, already applied, or refused for good. Parking is for a gap
        that closes on its own — a supersede whose target has not arrived yet, or
        a payload sealed by a newer engine — and only those are left out of it,
        so the next pull offers them again. A row that can never become
        mergeable is refused and acknowledged rather than re-offered for ever.
        """
        screened: list[_RemoteFact] = []
        decisions: list[dict[str, Any]] = []
        ack: list[str] = []
        parked: list[str] = []
        applied = reinforced = unchanged = refused = receipts = retired = 0
        for raw in rows:
            if _is_receipt_entry(raw):
                # Receipts land BEFORE any fact in the batch is merged: a retire
                # must win regardless of arrival order, and a fact that arrives
                # in the same drain as the receipt that forgets it is refused
                # by `_decide_remote_fact`'s receipt check, not revived.
                decision = self._apply_remote_receipt(raw)
                receipts += 1
                if decision["event"] == "RETIRE":
                    retired += 1
                (ack if decision.pop("ack") else parked).append(str(decision.get("docID") or ""))
                decisions.append(decision)
                continue
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
            decision = self._merge_remote_fact(fact, now_epoch=now_epoch, gap_timeout=gap_timeout)
            merged.append((fact, decision))
            event = decision["event"]
            if event in ("ADD", "UPDATE"):
                applied += 1
            elif event == "REINFORCE":
                reinforced += 1
            elif event == "REFUSE":
                refused += 1
            elif event == "HOLD":
                # Counted by neither: the row is not applied and not refused. It
                # stays unacknowledged, so `parked` below is what reports it.
                pass
            else:
                unchanged += 1
            # ONLY a real application moves the member's mark. An `UNCHANGED`
            # (already applied, remote is stale, immutable local) applied
            # nothing, and counting it inflated `applied_count` with offers
            # while rewriting `merged_at` — which is what made §8's
            # "re-applying an inbox batch is byte-identical" false for
            # `sync_state`. A pure replay now leaves the table untouched.
            if event in ("ADD", "UPDATE", "REINFORCE"):
                self._advance_sync_watermark(fact)

        # A held row is re-evaluated the next time the daemon offers it, not from
        # anything this engine kept: the hold note carries no document, and the
        # document it describes stays UNACKED in the inbox precisely so the next
        # drain hands it back. See `_record_lineage_hold`.
        #
        # Second pass. A supersede references an engine id, which is globally
        # unique, so a chain resolves on any device — but only once its target
        # has arrived. Every edge the batch itself supplied lands here; one whose
        # target is still missing leaves its document unacknowledged.
        for fact, decision in merged:
            resolved = True
            if decision.get("event") == "HOLD" or decision.get("ack") is False:
                resolved = False
            elif fact.superseded_by and decision["event"] != "REFUSE":
                resolved = self._resolve_remote_supersede(fact, str(decision.get("memoryID") or fact.memory_id))
                decision["supersedeResolved"] = resolved
            (ack if resolved else parked).append(fact.doc_id)
            decisions.append(decision)

        if applied or reinforced or refused or retired:
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
                    f"retired:{retired}",
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
            # Forget receipts drained alongside the facts, and how many local rows
            # they retired (a receipt for a row this device never held records
            # the receipt and retires nothing).
            "receipts": receipts,
            "retired": retired,
            "ackDocIDs": [doc_id for doc_id in ack if doc_id],
            "parkedDocIDs": [doc_id for doc_id in parked if doc_id],
            "watermark": self.sync_watermark(),
            "decisions": decisions,
        }

    def _apply_remote_receipt(self, raw: Any) -> dict[str, Any]:
        """Apply one forget receipt another device replicated.

        The receipt names the engine memory id the app resolved for it (the app
        holds the vault key and maps the receipt's keyed HMAC to an id it knows;
        this engine holds no key material and cannot). Applying it here is the
        same hard forget a local `forget` performs — purge the row, record the
        receipt keyed by id and by convergence identity — so a replay of the body
        under this id, or under a foreign id that folded into it, is refused by
        `_decide_remote_fact` exactly as a locally forgotten memory is.

        Always acknowledged, and idempotent: the app re-parks a receipt whenever
        its `replicatedAt` moves and the clock-skew re-scan can offer it again.
        A receipt this engine cannot act on (source-level, unresolved, malformed)
        is acknowledged too — nothing about it can become actionable later.
        """
        entry = raw if isinstance(raw, dict) else {}
        doc_id = str(entry.get("docID") or "")
        memory_id = str(entry.get("engineMemoryID") or "").strip()

        def done(event: str, code: str, reason: str, *, ack: bool = True, **extra: Any) -> dict[str, Any]:
            decision = {
                "event": event,
                "code": code,
                "reason": reason,
                "docID": doc_id,
                "memoryID": memory_id or None,
                "entryKind": REMOTE_RECEIPT_ENTRY_KIND,
                "ack": ack,
            }
            decision.update(extra)
            return decision

        payload = _receipt_payload(entry)
        if payload is None:
            return done("REFUSE", "MALFORMED_RECEIPT", "the receipt payload is not a JSON object")
        try:
            schema_version = int(payload.get("schemaVersion") or 0)
        except (TypeError, ValueError):
            schema_version = 0
        if schema_version > REMOTE_RECEIPT_SCHEMA_MAX:
            return done(
                "PARK",
                "RECEIPT_TOO_NEW",
                f"receipt schema {schema_version} is newer than this engine's {REMOTE_RECEIPT_SCHEMA_MAX}",
                ack=False,
            )
        reason = str(payload.get("reason") or "unknown")
        if not payload.get("memoryIdHmac"):
            # A source-level receipt names a chat source reference. The engine
            # holds no source refs, so there is nothing here for it to forget.
            return done("UNCHANGED", "SOURCE_RECEIPT_NOOP", "a source-level receipt names nothing this engine holds")
        if not REMOTE_MEMORY_ID_RE.match(memory_id):
            # The app could not map the receipt's HMAC to an engine id it knows.
            # No row on this device can match it either, now or later.
            return done("REFUSE", "RECEIPT_UNRESOLVED", "the receipt names no engine memory id this device knows")

        receipt_key = f"forget_receipt:{memory_id}"
        already = self.conn.execute("SELECT 1 FROM engine_meta WHERE key = ?", (receipt_key,)).fetchone() is not None
        # The receipt's own id, and the local row a foreign id folded into: the
        # member forgot THAT memory, whichever engine id their other device knew
        # it by. A retired-and-aliased loser resolves to its holder here.
        targets = [memory_id]
        canonical = self._local_memory_id(memory_id)
        if canonical and canonical != memory_id:
            targets.append(canonical)
        purged: list[str] = []
        project_id: str | None = None
        for target in targets:
            row = self.conn.execute("SELECT rowid, project_id FROM memories WHERE id = ?", (target,)).fetchone()
            if row is None:
                continue
            project_id = project_id or str(row["project_id"])
            if not self.conn.in_transaction:
                self.conn.execute("BEGIN IMMEDIATE")
            self._purge(target, int(row["rowid"]), preserve_daemon_mirror=True)
            purged.append(target)
        if not self.conn.in_transaction:
            self.conn.execute("BEGIN IMMEDIATE")
        # `_purge` records the receipt for rows it removed; a receipt for a row
        # this device never held is recorded by id alone so a later arrival under
        # that id is refused. OR IGNORE keeps a richer local receipt intact.
        self.conn.execute(
            "INSERT OR IGNORE INTO engine_meta (key, value) VALUES (?, ?)",
            (receipt_key, _json_dumps({"remote": True, "reason": reason, "receiptID": doc_id, "ts": now_iso()})),
        )
        if purged:
            audit_event(
                self.conn,
                action="memory.sync_retire_applied",
                project_id=project_id,
                subject_id=memory_id,
                labels=[f"reason:{reason}", f"purged:{len(purged)}", "remote_receipt"],
                actor=self.config.actor,
            )
            return done(
                "RETIRE",
                "REMOTE_FORGOTTEN",
                "another device forgot this memory; its row is purged here and the receipt recorded",
                purgedMemoryIDs=purged,
            )
        if already:
            return done("UNCHANGED", "RECEIPT_ALREADY_APPLIED", "this receipt was already applied on this device")
        return done(
            "RECEIPT", "RECEIPT_RECORDED", "no local row to retire; the receipt is recorded so a replay is refused"
        )

    def _merge_remote_fact(
        self,
        fact: _RemoteFact,
        *,
        now_epoch: float | None = None,
        gap_timeout: float = DEFAULT_LINEAGE_GAP_TIMEOUT_SECONDS,
    ) -> dict[str, Any]:
        """Land one screened remote row, and record what it keyed to.

        The ledger write is deliberately outside the decision: a revision that
        loses last-writer-wins still tells this device which memory that body
        belongs to, and that is exactly the case a replica needs when the edit
        reached it before the duplicate the edit replaced.
        """
        decision = self._decide_remote_fact(fact, now_epoch=now_epoch, gap_timeout=gap_timeout)
        if fact.writer_device_rejected:
            # Counted, never echoed: the decision says the field was refused and
            # does not repeat what was in it.
            decision["writerDeviceRejected"] = True
        if decision["event"] not in ("REFUSE", "HOLD"):
            self._record_convergence_identity(
                fact.project_id, fact.scope, fact.body_hash, str(decision.get("memoryID") or fact.memory_id)
            )
        return decision

    def _decide_remote_fact(
        self,
        fact: _RemoteFact,
        *,
        now_epoch: float | None = None,
        gap_timeout: float = DEFAULT_LINEAGE_GAP_TIMEOUT_SECONDS,
    ) -> dict[str, Any]:
        """Never resurrect, converge, then LWW."""
        local_id = self._local_memory_id(fact.memory_id)
        # `UNIQUE(project_id, scope, body_hash)` spans retired rows, so there is
        # at most one local holder of this convergence identity, ever.
        holder = self.conn.execute(
            "SELECT id, valid_to FROM memories WHERE project_id = ? AND scope = ? AND body_hash = ?",
            (fact.project_id, fact.scope, fact.body_hash),
        ).fetchone()
        if local_id is None and holder is None:
            # No live row holds this body — but one may have held it before a
            # revision moved it on. That row is still the memory this body
            # belongs to, and resolving through the ledger is what makes a
            # replica that saw the edit first agree with one that saw the
            # duplicate first.
            remembered = self._converged_local_id(fact)
            if remembered is not None:
                self._record_memory_alias(fact.memory_id, remembered)
                return self._update_remote_row(fact, remembered, now_epoch=now_epoch, gap_timeout=gap_timeout)
            # Nothing local answers to this row at all. Only now does a forget receipt
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
        return self._update_remote_row(fact, str(local_id), now_epoch=now_epoch, gap_timeout=gap_timeout)

    def _reinforce_remote(self, fact: _RemoteFact, memory_id: str) -> dict[str, Any]:
        """Fold a remote duplicate into the row that already holds its identity.

        `stamp_updated_at=False`: the merge is copying another device's revision,
        not authoring one here. The revision it absorbed is recorded as the row's
        applied-remote mark instead, which is what a later arrival is compared
        against — so a genuinely newer remote edit still wins, and this one is
        still recognised as already applied.
        """
        decision = self._reinforce(
            memory_id,
            Fact(text=fact.body, kind=fact.kind, confidence=fact.confidence, tags=list(fact.tags)),
            fact.entities,
            reason="remote duplicate",
            incoming_body=fact.body,
            labels=fact.gate_labels,
            quarantine_labels=[f"aux:{label}" for label in fact.injection],
            stamp_updated_at=False,
        )
        self._record_sync_mark(memory_id, fact)
        result = {
            "event": "REINFORCE",
            "code": "CONVERGED",
            "docID": fact.doc_id,
            "memoryID": memory_id,
            "remoteMemoryID": fact.memory_id,
            "kind": decision.get("kind"),
            "scope": decision.get("scope"),
            "reviewStatus": decision.get("reviewStatus"),
        }
        return result

    def _update_remote_row(
        self,
        fact: _RemoteFact,
        memory_id: str,
        *,
        now_epoch: float | None = None,
        gap_timeout: float = DEFAULT_LINEAGE_GAP_TIMEOUT_SECONDS,
    ) -> dict[str, Any]:
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
        applied = self._sync_mark(memory_id)
        if applied is not None and fact.order_key <= applied.order_key:
            # Last-writer-wins against the last revision this row absorbed from
            # any device. This is also the idempotence gate — replaying a batch
            # lands here — and it is deliberately compared against the *remote*
            # mark: a wall-clock stamp left by the merge itself would beat every
            # revision authored before the merge ran, including newer ones.
            return self._converge_stale_duplicate(
                fact,
                memory_id,
                {
                    "event": "UNCHANGED",
                    "code": "ALREADY_APPLIED" if fact.order_key == applied.order_key else "REMOTE_IS_STALE",
                    "docID": fact.doc_id,
                    "memoryID": memory_id,
                },
            )
        local_writer = self._local_writer_mark(row, applied)
        remote_mark = (fact.updated_ts, fact.body_hash)
        if local_writer is not None and remote_mark <= local_writer:
            # A member edited this row on this device after the last merge, and
            # their edit is the later writer. Their own decision outranks an
            # older copy of the memory arriving from somewhere else.
            return self._converge_stale_duplicate(
                fact,
                memory_id,
                {
                    "event": "UNCHANGED",
                    "code": "ALREADY_APPLIED" if remote_mark == local_writer else "LOCAL_IS_NEWER",
                    "docID": fact.doc_id,
                    "memoryID": memory_id,
                },
            )
        if bool(row["immutable"]):
            return {
                "event": "UNCHANGED",
                "code": "IMMUTABLE_LOCAL",
                "reason": "the local memory is immutable and a remote revision may not replace it",
                "docID": fact.doc_id,
                "memoryID": memory_id,
            }

        current_body_hash = str(row["body_hash"])
        # `previousBodyHash` is *advice*, never an admission gate: a row is never
        # refused for lacking it, and a gap only ever delays a decision that LWW
        # will make anyway. §5 / A1(iii).
        if fact.previous_body_hash is not None:
            if fact.previous_body_hash == current_body_hash:
                # The sender edited exactly the body this device holds. Fast-forward,
                # and any earlier gap on this row is answered.
                self._clear_lineage_hold(memory_id, fact.memory_id)
            else:
                # The sender edited a body this device never saw. Park the row until
                # the missing revision arrives — but only for as long as the timeout,
                # so a peer that will never send it cannot stall this replica.
                hold = self._get_lineage_hold(memory_id)
                current_epoch = time.time() if now_epoch is None else now_epoch
                held_time = (current_epoch - float(hold["firstSeenEpoch"])) if hold else 0.0
                if hold is not None and held_time >= gap_timeout:
                    self._record_unresolved_gap(fact, memory_id, fact.previous_body_hash, actual_hash=current_body_hash)
                    self._clear_lineage_hold(memory_id, fact.memory_id)
                elif self._record_lineage_hold(
                    fact, memory_id, fact.previous_body_hash, current_body_hash, now_epoch=now_epoch
                ):
                    return {
                        "event": "HOLD",
                        "code": "LINEAGE_GAP",
                        "reason": (
                            f"previousBodyHash {fact.previous_body_hash[:8]} does not match local {current_body_hash[:8]}"
                            + (f" (held for {held_time:.1f}s)" if hold else "")
                        ),
                        "docID": fact.doc_id,
                        "memoryID": memory_id,
                        "ack": False,
                    }
                else:
                    # The hold queue is full of older notes. Parking a document
                    # with no note to measure would stall it for ever, so the
                    # advice is dropped and LWW applies now — the answer the
                    # timeout reaches anyway — with the gap reported.
                    self._record_unresolved_gap(fact, memory_id, fact.previous_body_hash, actual_hash=current_body_hash)
        else:
            # No lineage advice at all: behave exactly as before the field existed.
            self._clear_lineage_hold(memory_id, fact.memory_id)

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
            # `remote_at`: the retirement belongs to the remote revision that
            # caused it, and the loser's own writer mark stays where it was, so a
            # later revision of it is still judged against the right instant.
            self._retire(
                memory_id,
                reason="converged into an identical remote fact",
                replacement=holder,
                remote_at=fact.updated_at,
            )
            return self._reinforce_remote(fact, holder)
        return self._write_remote_row(fact, memory_id, existing=row)

    def _converge_stale_duplicate(self, fact: _RemoteFact, memory_id: str, decision: dict[str, Any]) -> dict[str, Any]:
        """A revision that LOSES last-writer-wins still names an identity.

        `UNIQUE(project_id, scope, body_hash)` means at most one row holds a
        body, so when a *stale* revision of this row carries a body some OTHER
        live row is holding, the two rows are one memory: this row has already
        moved on past that body, and the row still holding it is the older
        revision, materialised here only because this replica saw the duplicate
        before it saw the edge that linked them.

        Without this, arrival order decides how many memories a replica
        believes in. A replica that receives `edit(B), add(A), add(B)` keeps A
        alive for ever — the linking revision is stale, so it is dropped before
        the convergence branch further down is ever reached — while a replica
        that received them in any other order folds them into one. §8 says the
        order documents arrive in may not change what a device ends up
        believing, so the fold happens on the losing path too, and the decision
        itself stays UNCHANGED: nothing of this revision was applied.
        """
        if fact.valid_to is not None or fact.superseded_by:
            return decision
        loser = self.conn.execute(
            "SELECT id FROM memories WHERE project_id = ? AND scope = ? AND body_hash = ? "
            "AND id != ? AND valid_to IS NULL",
            (fact.project_id, fact.scope, fact.body_hash, memory_id),
        ).fetchone()
        if loser is None:
            return decision
        holder = self.conn.execute("SELECT 1 FROM memories WHERE id = ? AND valid_to IS NULL", (memory_id,)).fetchone()
        if holder is None:
            # This row is itself retired; folding a live row into a dead one
            # would lose the memory rather than converge it.
            return decision
        loser_id = str(loser["id"])
        self._record_memory_alias(loser_id, memory_id)
        # `remote_at`: the retirement belongs to the remote revision that proved
        # the two ids are one, exactly as the live-clash branch below does.
        if self._retire(
            loser_id,
            reason="converged into the memory a later revision had already moved on",
            replacement=memory_id,
            remote_at=fact.updated_at,
        ):
            self._record_convergence_identity(fact.project_id, fact.scope, fact.body_hash, memory_id)
            return {**decision, "convergedID": loser_id}
        return decision

    def _write_remote_row(self, fact: _RemoteFact, memory_id: str, *, existing: Any) -> dict[str, Any]:
        """Insert or overwrite one row from a remote revision.

        `memories.updated_at` takes the payload's `updatedAt` verbatim — that
        authenticated instant, not this device's clock, is what this row's last
        writer actually is — and the same instant is recorded as the row's
        applied-remote mark, which is what the next arrival is compared against.
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
        # A quarantined (injection-labelled) body is excluded from model paths on
        # arrival exactly as it is locally — and the embedding provider IS a model
        # path: with the gateway provider `embed()` ships the text off-device.
        # The row lands vector-less; `reindex` embeds it if a review approves it.
        vector = self.provider.embed([fact.body])[0] if self.provider.available and not fact.injection else None
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
        # The revision this row now holds, in §5's total order: what the next
        # arrival is judged against, whatever this device's clock says later.
        self._record_sync_mark(memory_id, fact)
        self.conn.execute("DELETE FROM memory_relations WHERE memory_id = ?", (memory_id,))
        for subject, predicate, obj in relations:
            self.conn.execute(
                "INSERT INTO memory_relations (project_id, memory_id, subject, predicate, object, slot_key, confidence) VALUES (?,?,?,?,?,?,?)",
                (fact.project_id, memory_id, subject, predicate, obj, _slot_key(subject, predicate), fact.confidence),
            )
        history_meta: dict[str, Any] = {
            "remoteMemoryID": fact.memory_id,
            "updatedAt": fact.updated_at,
            "event": event,
        }
        if fact.writer_device:
            # B8's whole question — "which device wrote this revision" — is about
            # revisions written somewhere ELSE, and this is the only path they
            # arrive by. The field was parsed onto `_RemoteFact` and then dropped.
            # A device id is not member content, so `meta_json` is where it goes.
            history_meta["writerDevice"] = fact.writer_device
        self._history(memory_id, fact.project_id, "merged_remote", None, fact.body, history_meta)
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
        decision: dict[str, Any] = {
            "event": event,
            "docID": fact.doc_id,
            "memoryID": memory_id,
            "remoteMemoryID": fact.memory_id,
            "kind": fact.kind,
            "scope": fact.scope,
            "confidence": fact.confidence,
            "sensitivity": fact.sensitivity,
            "reviewStatus": fact.review_status,
            "labels": list(fact.gate_labels),
            "injectionLabels": list(fact.injection),
            "retired": fact.valid_to is not None,
            "embedded": vector is not None,
        }
        # No body, no tags — for ANY remote row, not only a quarantined one. The
        # inbox is account-wide on purpose (an engine id carries no project), so
        # a pull invoked from project A merges facts that belong to projects B, C
        # and the member's personal scope. Fencing a body as untrusted stops
        # instruction injection; it does not stop cross-project disclosure into
        # the calling agent's context. The tool's stated purpose is counts and
        # ids: the decision names the row (id, kind, scope, labels, status) and
        # recall — which IS project-scoped — is how a body reaches a model.
        return decision

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
        """Move this member's applied high-water mark forward, never back.

        Called only for `ADD` / `UPDATE` / `REINFORCE`, so `applied_count` counts
        revisions this store actually applied — what its name says — rather than
        every row that was ever offered to it.
        """
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
