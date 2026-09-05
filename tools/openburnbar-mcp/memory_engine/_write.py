"""`MemoryEngine`'s write path, mixed into the engine class.

Only methods live here; construction and shared state stay in `engine.py`."""

from __future__ import annotations

import os
import secrets
import sqlite3
from collections.abc import Iterable, Sequence
from datetime import UTC, datetime
from pathlib import Path
from typing import TYPE_CHECKING, Any

from ._util import (
    _aux_strings,
    _clamp,
    _ingest_decision,
    _is_expired,
    _json_dumps,
    _json_loads,
    _normalize_expiration,
    normalize_kind_strict,
    normalize_scope,
    normalize_tags,
    now_iso,
    raw_tags,
    sha256_hex,
    canonical_body_hash,
    fail_closed_refusal,
)
from .judge import JudgeDecision, llm_judge
from .providers import ModelRouter, ModelUnavailable
from .constants import (
    JUDGE_MAX_CANDIDATES,
    CONFLICT_MIN_SIM,
    CONFLICT_OBJECT_MAX_SIM,
    DEDUP_COSINE,
    DEDUP_JACCARD,
    DEFAULT_MAX_FACTS,
    EXTRACTOR_ENV,
    KINDS,
    MAX_BODY_CHARS,
    MEMORY_SCOPES,
    NEGATION_RE,
    REVIEW_STATUSES,
    SAME_CLAIM_MIN_OVERLAP,
    SENSITIVITIES,
    SWITCH_RE,
)
from .embeddings import _cosine, encode_vector
from .extract import (
    EXTRACTOR_MARKER_RE,
    ExtractorFn,
    Fact,
    _slot_key,
    extract_entities,
    extract_relations,
    gate_transcript,
    heuristic_extract,
    render_transcript,
    resolve_extractor,
)
from .gate import (
    AUX_TOO_LARGE_CODE,
    GateDecision,
    apply_gate,
    aux_input_overflow,
    auxiliary_injection_labels,
    gate_aux_fields,
    injection_labels,
)
from .store import audit_event, project_payload, resolve_project
from .text import _jaccard, tokenize

if TYPE_CHECKING:
    from .engine import ActiveMemory


def _merged_source_ref(caller_ref: str | None, fact_ref: str | None) -> str | None:
    """The provenance stored on a fact the caller did not reference by hand.

    `heuristic_extract` marks each fact with the position of the message it came
    from (`m3`), which says nothing about which batch that was. When the caller
    named the batch -- the `SessionEnd` hook passes
    `source_ref="claude-code:<session_id>"` -- the row keeps both:
    `claude-code:<session_id>#m3`. A fact carrying a reference of its own (an LLM
    extractor, caller-supplied `facts`) keeps it, and a call with no `source_ref`
    keeps the bare marker.
    """
    if not caller_ref:
        return fact_ref
    if not fact_ref:
        return caller_ref
    if EXTRACTOR_MARKER_RE.match(fact_ref):
        return f"{caller_ref}#{fact_ref}"
    return fact_ref


class _WritePath:
    """`MemoryEngine`'s write path: memorize, remember, and reconciliation."""

    def memorize(
        self,
        *,
        project_path: str | None,
        messages: Sequence[dict[str, Any]] | None = None,
        text: str | None = None,
        facts: Sequence[Any] | None = None,
        extractor: str | None = None,
        extractor_fn: ExtractorFn | None = None,
        max_facts: int = DEFAULT_MAX_FACTS,
        source_kind: str = "conversation",
        source_ref: str | None = None,
        default_scope: str | None = None,
        default_tags: Sequence[str] | None = None,
        metadata: dict[str, Any] | None = None,
        force: bool = False,
        default_review_status: str | None = None,
        fail_closed: bool = False,
    ) -> dict[str, Any]:
        project_id, root = resolve_project(self.conn, project_path)
        # The batch-wide auxiliary input the caller controls. Per-fact aux from
        # `facts` is bounded in `_commit_fact`, which every fact goes through.
        overflow = aux_input_overflow(
            tags=raw_tags(default_tags), metadata=metadata, source_ref=source_ref, source_kind=source_kind
        )
        if overflow:
            return {
                "status": "rejected",
                "code": AUX_TOO_LARGE_CODE,
                "reason": overflow,
                "summary": {event: 0 for event in ("ADD", "UPDATE", "NONE", "DELETE", "REJECT")},
                "decisions": [],
                **project_payload(project_id, root),
            }
        normalized_messages: list[dict[str, Any]] = []
        if messages:
            normalized_messages = [dict(message) for message in messages if isinstance(message, dict)]
        elif text:
            normalized_messages = [{"role": "user", "content": str(text)}]
        # The idempotency key is per project: the same transcript memorized for
        # two repositories must produce two sets of project-scoped memories.
        extractor_identity = (extractor or os.environ.get(EXTRACTOR_ENV, "heuristic")).strip().lower() or "heuristic"
        source_material = _json_dumps(
            {
                "project": project_id,
                "messages": normalized_messages,
                "facts": list(facts or []),
                "extractor": extractor_identity,
                "maxFacts": max(1, min(int(max_facts), 64)),
                "sourceKind": source_kind,
                "sourceRef": source_ref,
                "defaultScope": default_scope,
                "defaultTags": normalize_tags(default_tags),
                "metadata": metadata or {},
                "defaultReviewStatus": default_review_status,
                "secretPolicy": self.config.secret_policy,
                "piiPolicy": self.config.pii_policy,
                "retainAllowed": self.config.retain_allowed,
            }
        )
        source_hash = sha256_hex(source_material)
        if not force:
            prior = self.conn.execute(
                "SELECT decisions_json, ts FROM memory_ingest WHERE source_hash = ?", (source_hash,)
            ).fetchone()
            if prior is not None:
                prior_decisions = _json_loads(prior["decisions_json"], [])
                retry_rejected = any(
                    isinstance(item, dict) and item.get("event") == "REJECT" for item in prior_decisions
                )
                if retry_rejected:
                    # Pre-fix stores may contain a receipt for a transient gate
                    # failure. Remove it so scanner/capability recovery gets a
                    # real retry instead of a false ALREADY_INGESTED response.
                    self.conn.execute("DELETE FROM memory_ingest WHERE source_hash = ?", (source_hash,))
                    prior_decisions = []
                referenced = [
                    str(item["memoryID"]) for item in prior_decisions if isinstance(item, dict) and item.get("memoryID")
                ]
                if not retry_rejected and not self._missing_ids(referenced):
                    return {
                        "status": "ok",
                        "code": "ALREADY_INGESTED",
                        "sourceHash": source_hash,
                        "ingestedAt": prior["ts"],
                        "decisions": [self._hydrate_ingest_decision(item) for item in prior_decisions],
                        **project_payload(project_id, root),
                    }
                # The receipt points at memories that were forgotten since: replay is real work again.

        extractor_name = "facts"
        extracted: list[Fact] = []
        extraction_error: str | None = None
        transcript_gate: dict[str, Any] | None = None
        extraction_outcome: dict[str, Any] | None = None
        if facts:
            extracted = [fact for fact in (Fact.from_mapping(item) for item in facts) if fact is not None]
        else:
            extractor_name, extractor_fn_resolved = resolve_extractor(extractor, extractor_fn, models=self.models)
            if extractor_name == "none":
                raw = "\n".join(str(message.get("content") or "") for message in normalized_messages).strip()
                if raw:
                    extracted = [Fact(text=raw[:MAX_BODY_CHARS], kind="note", confidence=0.6)]
            elif extractor_fn_resolved is not None:
                # Anything that is not the in-process heuristic may leave this
                # process (claude -p, an Ollama endpoint, a caller-supplied
                # function). It only ever sees a gated transcript, and nothing
                # leaves when the gate itself cannot run.
                safe_transcript, transcript_gate = gate_transcript(
                    render_transcript(normalized_messages), pii_policy=self.config.pii_policy
                )
                if safe_transcript is None:
                    if fail_closed:
                        return fail_closed_refusal(
                            "rejected", "TRANSCRIPT_GATE_REJECTED", transcript_gate.get("reason"), project_id, root
                        )
                    extraction_error = f"{extractor_name}: {transcript_gate.get('reason')}"
                    extractor_name = "heuristic"
                    extracted = heuristic_extract(normalized_messages, max_facts=max_facts)
                else:
                    try:
                        extracted = extractor_fn_resolved(safe_transcript, max_facts)
                    except ModelUnavailable as exc:
                        if fail_closed:
                            return fail_closed_refusal("unavailable", exc.code, exc.reason, project_id, root)
                        extraction_error = f"{extractor_name}: {exc.code}: {exc.reason}"
                        extraction_outcome = {
                            "purpose": "memory-extract",
                            "applied": False,
                            "code": exc.code,
                            "model": None,
                            "provider": None,
                        }
                        extractor_name = "heuristic"
                        extracted = heuristic_extract(normalized_messages, max_facts=max_facts)
                    except Exception as exc:  # noqa: BLE001 — degrade to the heuristic path, report the reason
                        if fail_closed:
                            return fail_closed_refusal("unavailable", "EXTRACTION_FAILED", str(exc), project_id, root)
                        extraction_error = f"{extractor_name}: {exc}"
                        extractor_name = "heuristic"
                        extracted = heuristic_extract(normalized_messages, max_facts=max_facts)
                    else:
                        provenance = getattr(extractor_fn_resolved, "provenance", None)
                        if isinstance(provenance, dict):
                            model_id = str(provenance.get("model") or provenance.get("label") or "")
                            extracted_by = str(provenance.get("label") or provenance.get("provider") or model_id)
                            extraction_outcome = {
                                "purpose": "memory-extract",
                                "applied": True,
                                "code": None,
                                "model": model_id,
                                "provider": provenance.get("provider"),
                                "label": extracted_by,
                                "droppedUngrounded": int(provenance.get("droppedUngrounded") or 0),
                            }
                            extractor_name = f"llm:{extracted_by}"
                            gate_hash = sha256_hex(safe_transcript)[:16]
                            for fact in extracted:
                                fact.metadata = {
                                    **fact.metadata,
                                    "extracted_by": extracted_by,
                                    "model_id": model_id,
                                    "extractPromptVersion": provenance.get("promptVersion"),
                                    "transcriptGateHash": gate_hash,
                                    "modelLatencyMs": int(provenance.get("latencyMs") or 0),
                                }
            else:
                extracted = heuristic_extract(normalized_messages, max_facts=max_facts)
        extracted = extracted[: max(1, min(int(max_facts), 64))]

        decisions: list[dict[str, Any]] = []
        for fact in extracted:
            # Every row says what produced it, heuristic or model alike: an
            # unlabelled row is one a reviewer cannot weigh (C15).
            fact.metadata.setdefault("extracted_by", extractor_name)
            fact.metadata.setdefault("model_id", extractor_name)
            if default_tags:
                # Raw until `_commit_fact` gates them; see `raw_tags`.
                fact.tags = raw_tags(list(fact.tags) + list(default_tags))
            if metadata:
                merged = dict(metadata)
                merged.update(fact.metadata)
                fact.metadata = merged
            if default_scope and not fact.scope:
                fact.scope = default_scope
            # Unconditional, and an extractor's own status is discarded; only
            # CALLER `facts` keep one. See `Fact.from_mapping` for why.
            if default_review_status or not facts:
                fact.review_status = default_review_status
            fact.source_ref = _merged_source_ref(source_ref, fact.source_ref)
            decision = self._commit_fact(
                project_id=project_id,
                root=root,
                fact=fact,
                source_kind=source_kind,
                source_hash=source_hash,
                extractor=extractor_name,
            )
            decisions.append(decision)
        receipt_stored = not any(item.get("event") == "REJECT" for item in decisions)
        if receipt_stored:
            self.conn.execute(
                "INSERT OR REPLACE INTO memory_ingest (source_hash, project_id, ts, decisions_json) VALUES (?, ?, ?, ?)",
                (source_hash, project_id, now_iso(), _json_dumps([_ingest_decision(item) for item in decisions])),
            )
        else:
            self.conn.execute("DELETE FROM memory_ingest WHERE source_hash = ?", (source_hash,))
        audit_event(
            self.conn,
            action="memory.memorize",
            project_id=project_id,
            subject_id=source_hash[:16],
            labels=[f"extractor:{extractor_name}", f"facts:{len(extracted)}"]
            + sorted({f"event:{item['event']}" for item in decisions}),
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
            "extractor": extractor_name,
            "extractionError": extraction_error,
            "transcriptGate": transcript_gate,
            "extraction": extraction_outcome,
            "sourceHash": source_hash,
            "receiptStored": receipt_stored,
            "factsConsidered": len(extracted),
            "summary": summary,
            "decisions": decisions,
            "embedding": self.provider.describe(),
            **project_payload(project_id, root),
        }

    def remember(
        self,
        text: str,
        *,
        project_path: str | None,
        kind: str = "fact",
        scope: str | None = None,
        tags: Sequence[str] | str | None = None,
        confidence: float = 1.0,
        entities: Sequence[str] | None = None,
        metadata: dict[str, Any] | None = None,
        source_kind: str = "manual",
        source_ref: str | None = None,
        supersedes: Sequence[str] | None = None,
        expires_at: str | None = None,
        immutable: bool = False,
    ) -> dict[str, Any]:
        project_id, root = resolve_project(self.conn, project_path)
        body = (text or "").strip()
        if not body:
            return {
                "status": "unavailable",
                "code": "EMPTY_MEMORY",
                "reason": "memory text is empty",
                **project_payload(project_id, root),
            }
        # Checked here, against the caller's own lists, because the entity clip
        # below would otherwise hide an oversized batch from the bound.
        overflow = aux_input_overflow(
            tags=raw_tags(tags),
            entities=[str(item) for item in (entities or [])],
            metadata=metadata,
            source_ref=source_ref,
            source_kind=source_kind,
        )
        if overflow:
            return {
                "status": "rejected",
                "event": "REJECT",
                "code": AUX_TOO_LARGE_CODE,
                "reason": overflow,
                **project_payload(project_id, root),
            }
        fact = Fact(
            text=body[:MAX_BODY_CHARS],
            kind=str(kind or "fact").strip().lower(),
            confidence=_clamp(float(confidence), 0.0, 1.0),
            scope=scope,
            # Raw until `_commit_fact` gates them; see `raw_tags`.
            tags=raw_tags(tags),
            entities=[str(item) for item in (entities or [])][:16],
            metadata=dict(metadata or {}),
            source_ref=source_ref,
            supersedes=[str(item) for item in (supersedes or [])],
            expires_at=expires_at,
            immutable=bool(immutable),
        )
        decision = self._commit_fact(
            project_id=project_id,
            root=root,
            fact=fact,
            source_kind=source_kind,
            source_hash=None,
            extractor="manual",
        )
        self._commit()
        self._invalidate_cache()
        status = "ok" if decision["event"] != "REJECT" else "rejected"
        payload = {
            "status": status,
            **decision,
            "embedding": self.provider.describe(),
            **project_payload(project_id, root),
        }
        if decision["event"] == "REJECT":
            payload["code"] = decision.get("code") or "SECRET_DETECTED"
        return payload

    def _commit_fact(
        self,
        *,
        project_id: str,
        root: Path,
        fact: Fact,
        source_kind: str,
        source_hash: str | None,
        extractor: str,
    ) -> dict[str, Any]:
        try:
            kind = normalize_kind_strict(fact.kind)
        except ValueError as exc:
            return {
                "event": "REJECT",
                "code": "INVALID_KIND",
                "reason": str(exc),
                "allowed": list(KINDS),
            }
        if fact.review_status is not None and fact.review_status not in REVIEW_STATUSES:
            return {
                "event": "REJECT",
                "code": "INVALID_REVIEW_STATUS",
                "reason": f"reviewStatus must be one of: {', '.join(REVIEW_STATUSES)}",
                "kind": kind,
                "allowed": list(REVIEW_STATUSES),
            }
        if fact.sensitivity is not None and fact.sensitivity not in SENSITIVITIES:
            return {
                "event": "REJECT",
                "code": "INVALID_SENSITIVITY",
                "reason": f"sensitivity must be one of: {', '.join(SENSITIVITIES)}",
                "kind": kind,
                "allowed": list(SENSITIVITIES),
            }
        try:
            scope = normalize_scope(fact.scope, kind)
        except ValueError as exc:
            return {
                "event": "REJECT",
                "code": "INVALID_SCOPE",
                "reason": str(exc),
                "kind": kind,
                "allowed": ["auto", *MEMORY_SCOPES],
            }
        try:
            fact.expires_at = _normalize_expiration(fact.expires_at)
        except ValueError as exc:
            audit_event(
                self.conn,
                action="memory.expiration_rejected",
                project_id=project_id,
                subject_id=None,
                labels=["invalid_expiration"],
                actor=self.config.actor,
            )
            return {
                "event": "REJECT",
                "code": "INVALID_EXPIRATION",
                "reason": str(exc),
                "kind": kind,
                "scope": scope,
            }
        # Bound the auxiliary input before the gate walks it. This is the
        # backstop that covers every write path, `import_memories` included.
        overflow = aux_input_overflow(
            tags=fact.tags,
            entities=fact.entities,
            metadata=fact.metadata,
            source_ref=fact.source_ref,
            source_kind=source_kind,
        )
        if overflow:
            return {
                "event": "REJECT",
                "code": AUX_TOO_LARGE_CODE,
                "reason": overflow,
                "kind": kind,
                "scope": scope,
            }
        gate = apply_gate(
            fact.text,
            secret_policy=self.config.secret_policy,
            pii_policy=self.config.pii_policy,
            retain_allowed=self.config.retain_allowed,
        )
        aux = gate_aux_fields(
            tags=fact.tags,
            entities=fact.entities,
            metadata=fact.metadata,
            source_ref=fact.source_ref,
            source_kind=source_kind,
            secret_policy=self.config.secret_policy,
            pii_policy=self.config.pii_policy,
        )
        if gate.action != "reject" and aux.reject_reason:
            gate = GateDecision(
                "reject",
                "secret" if aux.reject_code == "SECRET_DETECTED" else "pii",
                "",
                None,
                gate.labels + aux.labels,
                aux.reject_reason,
            )
        gate.labels = sorted(set(gate.labels + aux.labels))
        if gate.action == "reject":
            audit_event(
                self.conn,
                action="memory.secret_rejected" if gate.sensitivity == "secret" else "memory.gate_rejected",
                project_id=project_id,
                subject_id=None,
                labels=gate.labels,
                actor=self.config.actor,
            )
            return {
                "event": "REJECT",
                "code": "SECRET_DETECTED" if gate.sensitivity == "secret" else "GATE_REJECTED",
                "reason": gate.reason,
                "labels": gate.labels,
                "kind": kind,
                "scope": scope,
            }
        if fact.sensitivity == "secret":
            # A redacted export intentionally omits the vault plaintext while
            # retaining its classification. Restoring it must stay local-only
            # even though the already-redacted body no longer trips the gate.
            gate.sensitivity = "secret"
        fact.tags = normalize_tags(aux.tags)
        fact.entities = list(aux.entities)
        fact.metadata = dict(aux.metadata)
        fact.source_ref = aux.source_ref
        source_kind = aux.source_kind or source_kind
        body = gate.body.strip()
        if not body:
            return {
                "event": "REJECT",
                "code": "EMPTY_MEMORY",
                "reason": "nothing left after redaction",
                "labels": gate.labels,
            }
        injection = injection_labels(body)
        aux_injection = injection_labels(
            "\n".join(_aux_strings(fact.tags, fact.entities, fact.metadata, fact.source_ref))
        )
        if aux_injection:
            injection = sorted(set(injection + [f"aux:{label}" for label in aux_injection]))
        if injection or fact.review_status == "quarantined":
            review_status = "quarantined"
        elif fact.review_status == "rejected":
            review_status = "rejected"  # an imported review decision is preserved
        else:
            review_status = "approved"
        body_hash = canonical_body_hash(body)
        ts = now_iso()
        now = datetime.now(UTC)
        entities = list(dict.fromkeys(list(fact.entities) + extract_entities(body)))[:16]
        # Reinforcement persists only tags and entities from the incoming
        # fact. Do not let a discarded metadata/source-ref directive
        # quarantine an otherwise clean existing row.
        reinforce_injection = [f"aux:{label}" for label in auxiliary_injection_labels(fact.tags, entities, {}, None)]
        relations = extract_relations(body)
        # Project resolution or a prior item in a batch may have left a write
        # transaction open. External embedding must never run while that lock
        # is held; each fact remains independently durable and the batch
        # receipt is written after all facts complete.
        if self.conn.in_transaction:
            self._commit()
        vector = self.provider.embed([body])[0] if self.provider.available else None
        # Content only. `source_ref` is provenance, not something the memory says:
        # a hook ref (`claude-code:<uuid>`) tokenizes into a dozen tokens shared by
        # every fact in one batch, which inflates pairwise Jaccard and collapses
        # distinct memories into near duplicates. Keep it out of similarity and
        # out of BM25 (`engine._row_to_memory` builds the stored side the same way).
        tokens = tokenize(" ".join([body, " ".join(fact.tags), " ".join(entities)]))

        # Serialize the exact-duplicate lookup with insertion. Embeddings and
        # all other external work are complete before taking the write lock.
        if not self.conn.in_transaction:
            self.conn.execute("BEGIN IMMEDIATE")

        # Exact duplicate in the same project/scope → reinforce, unless the row
        # was rejected in review (stays hidden) or has expired (reactivated).
        exact = self.conn.execute(
            "SELECT id, review_status, expires_at FROM memories WHERE project_id = ? AND scope = ? AND body_hash = ? AND valid_to IS NULL",
            (project_id, scope, body_hash),
        ).fetchone()
        if exact is not None:
            if str(exact["review_status"]) == "rejected":
                audit_event(
                    self.conn,
                    action="memory.reinforce_blocked",
                    project_id=project_id,
                    subject_id=str(exact["id"]),
                    labels=["review:rejected"],
                    actor=self.config.actor,
                )
                return {
                    "event": "NONE",
                    "code": "PREVIOUSLY_REJECTED",
                    "memoryID": str(exact["id"]),
                    "reason": "an identical memory was rejected in review; re-approve it with burnbar_memory_review",
                    "kind": kind,
                    "scope": scope,
                }
            if review_status != "approved" and str(exact["review_status"]) == "approved":
                audit_event(
                    self.conn,
                    action="memory.reinforce_blocked",
                    project_id=project_id,
                    subject_id=str(exact["id"]),
                    labels=[f"incoming_review:{review_status}"],
                    actor=self.config.actor,
                )
                return {
                    "event": "NONE",
                    "code": "NON_APPROVED_DUPLICATE",
                    "memoryID": str(exact["id"]),
                    "reason": "non-approved duplicate cannot change an approved memory",
                    "kind": kind,
                    "scope": scope,
                }
            decision = self._reinforce(
                str(exact["id"]),
                fact,
                entities,
                reason="exact duplicate",
                incoming_body=body,
                labels=gate.labels,
                quarantine_labels=reinforce_injection,
                reactivate=_is_expired(exact["expires_at"], now),
            )
            # This row holds this body: say so in the convergence ledger, so a
            # later local edit that moves the body on cannot leave another
            # device's copy of it keyed to nothing here. See
            # `_sync.py::_record_convergence_identity`.
            self._record_convergence_identity(project_id, scope, body_hash, str(exact["id"]))
            if gate.action == "retain" and gate.vault_body is not None:
                # Different secrets redact to the same body: keep the vault current.
                changed = self._rotate_vault(str(exact["id"]), project_id, gate)
                decision["secretRotated"] = changed
                decision["sensitivity"] = "secret"
                if changed:
                    decision["event"] = "UPDATE"
            return decision

        active = self._load_active(project_id, include_personal_cross_project=(scope == "personal"))
        candidates = [
            item
            for item in active
            if item.scope == scope and item.review_status != "rejected" and not _is_expired(item.expires_at, now)
        ]

        # Only approved facts may change the lifecycle of an approved row.
        # Quarantined/rejected content is stored for review, but its explicit
        # supersedes and inferred conflicts have no retirement authority.
        supersede_targets: list[str] = []
        retire_targets: list[str] = []
        decided_by = "rules"
        rationale: str | None = None
        self._judge_outcome = None
        if review_status == "approved":
            supersede_targets = [item for item in fact.supersedes if any(mem.id == item for mem in active)]
            if not supersede_targets:
                conflict_first = NEGATION_RE.search(body) is not None or SWITCH_RE.search(body) is not None
                near = None if conflict_first else self._nearest(vector, tokens, candidates)
                if near is not None:
                    decision = self._reinforce(
                        near[1].id,
                        fact,
                        entities,
                        reason=f"near duplicate (sim={near[0]:.2f})",
                        incoming_body=body,
                        labels=gate.labels,
                        quarantine_labels=reinforce_injection,
                    )
                    if gate.action == "retain" and gate.vault_body is not None:
                        # A personal match may be owned by another project;
                        # vault AAD always follows the memory owner.
                        changed = self._rotate_vault(near[1].id, near[1].project_id, gate)
                        decision["secretRotated"] = changed
                        decision["sensitivity"] = "secret"
                        if changed:
                            decision["event"] = "UPDATE"
                    decision["decidedBy"] = decided_by
                    decision["rationale"] = rationale
                    return decision
                # Memory Pro judge: only the ambiguous band (a conflict cue, or a
                # best candidate above CONFLICT_MIN_SIM that is not a duplicate).
                ranked = self._judge_candidates(vector, tokens, candidates)
                verdict = None
                if ranked and (conflict_first or ranked[0][0] >= CONFLICT_MIN_SIM):
                    verdict = self._consult_judge(body=body, kind=kind, scope=scope, ranked=ranked)
                if verdict is not None:
                    decided_by = f"judge:{verdict.model}"
                    rationale = verdict.rationale or None
                    if verdict.event == "UPDATE":
                        supersede_targets = list(verdict.targets)
                    elif verdict.event == "DELETE":
                        retire_targets = list(verdict.targets)
                    elif verdict.event == "NONE":
                        decision = self._reinforce(
                            verdict.targets[0],
                            fact,
                            entities,
                            reason=f"judge: {verdict.rationale}",
                            incoming_body=body,
                            labels=gate.labels,
                            quarantine_labels=reinforce_injection,
                        )
                        decision["decidedBy"] = decided_by
                        decision["rationale"] = rationale
                        decision["judge"] = self._judge_outcome
                        return decision
                else:
                    supersede_targets, retire_targets = self._resolve_conflicts(
                        project_id=project_id,
                        body=body,
                        relations=relations,
                        vector=vector,
                        tokens=tokens,
                        candidates=candidates,
                    )

        if retire_targets and not supersede_targets:
            retired_targets = [
                target
                for target in retire_targets
                if self._retire(target, reason="negated by new statement", replacement=None)
            ]
            if not retired_targets:
                return {
                    "event": "NONE",
                    "code": "IMMUTABLE_CONFLICT",
                    "reason": "matching memories are immutable and were not retired",
                    "kind": kind,
                    "scope": scope,
                }
            audit_event(
                self.conn,
                action="memory.retire",
                project_id=project_id,
                subject_id=None,
                labels=[f"retired:{len(retired_targets)}"],
                actor=self.config.actor,
            )
            deletion: dict[str, Any] = {
                "event": "DELETE",
                "retired": retired_targets,
                "kind": kind,
                "scope": scope,
                "text": body,
                "decidedBy": decided_by,
                "rationale": rationale,
            }
            if self._judge_outcome is not None:
                deletion["judge"] = self._judge_outcome
            return deletion

        # UNIQUE(project_id, scope, body_hash) spans retired rows too. A fact that
        # reverts to an earlier statement (A -> B -> A) brings the retired row back
        # under its original id instead of colliding on insert.
        retired = self.conn.execute(
            "SELECT id, rowid, superseded_by FROM memories WHERE project_id = ? AND scope = ? AND body_hash = ? AND valid_to IS NOT NULL",
            (project_id, scope, body_hash),
        ).fetchone()
        reactivated_id = str(retired["id"]) if retired is not None else None
        memory_id = reactivated_id or ("mem_" + secrets.token_hex(16))
        salience = self.compute_salience(kind, fact.confidence, 0)
        cipher, nonce = self._seal_body(memory_id, project_id, body)
        metadata = dict(fact.metadata)
        if gate.labels:
            metadata["gateLabels"] = gate.labels
        if injection:
            metadata["injectionLabels"] = injection
        if retired is not None:
            rowid = int(retired["rowid"])
            self.conn.execute(
                """
                UPDATE memories SET
                    scope = ?, kind = ?, body_cipher = ?, body_nonce = ?, key_id = ?, sensitivity = ?, review_status = ?,
                    confidence = ?, salience = ?, access_count = 0, last_accessed_at = NULL, immutable = ?, expires_at = ?,
                    valid_from = ?, valid_to = NULL, superseded_by = NULL, supersedes_json = ?, tags_json = ?, entities_json = ?,
                    metadata_json = ?, source_kind = ?, source_ref = ?, source_hash = ?, extractor = ?, embedding_version = ?,
                    updated_at = ?
                WHERE id = ?
                """,
                (
                    scope,
                    kind,
                    cipher,
                    nonce,
                    self.keyring.key_id,
                    gate.sensitivity,
                    review_status,
                    fact.confidence,
                    salience,
                    1 if fact.immutable else 0,
                    fact.expires_at,
                    ts,
                    _json_dumps(supersede_targets),
                    _json_dumps(fact.tags),
                    _json_dumps(entities),
                    _json_dumps(metadata),
                    source_kind,
                    fact.source_ref,
                    source_hash,
                    extractor,
                    self.provider.version_id if vector is not None else None,
                    ts,
                    memory_id,
                ),
            )
            self.conn.execute("DELETE FROM memory_vectors WHERE memory_rowid = ?", (rowid,))
            self.conn.execute("DELETE FROM memory_relations WHERE memory_id = ?", (memory_id,))
            self.conn.execute("DELETE FROM memory_vault WHERE memory_id = ?", (memory_id,))
        else:
            self.conn.execute(
                """
                INSERT INTO memories (
                    id, project_id, scope, kind, body_cipher, body_nonce, key_id, body_hash, sensitivity, review_status,
                    confidence, salience, access_count, last_accessed_at, immutable, expires_at, valid_from, valid_to,
                    superseded_by, supersedes_json, tags_json, entities_json, metadata_json, source_kind, source_ref,
                    source_hash, extractor, embedding_version, created_at, updated_at
                ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,0,NULL,?,?,?,NULL,NULL,?,?,?,?,?,?,?,?,?,?,?)
                """,
                (
                    memory_id,
                    project_id,
                    scope,
                    kind,
                    cipher,
                    nonce,
                    self.keyring.key_id,
                    body_hash,
                    gate.sensitivity,
                    review_status,
                    fact.confidence,
                    salience,
                    1 if fact.immutable else 0,
                    fact.expires_at,
                    ts,
                    _json_dumps(supersede_targets),
                    _json_dumps(fact.tags),
                    _json_dumps(entities),
                    _json_dumps(metadata),
                    source_kind,
                    fact.source_ref,
                    source_hash,
                    extractor,
                    self.provider.version_id if vector is not None else None,
                    ts,
                    ts,
                ),
            )
            rowid = int(self.conn.execute("SELECT rowid FROM memories WHERE id = ?", (memory_id,)).fetchone()["rowid"])
        # §5's convergence identity, recorded by the LOCAL writer as well as by
        # the merge. The live `UNIQUE(project_id, scope, body_hash)` lookup only
        # answers while this row still holds this body, and a later local edit
        # moves it on; without this entry another device's independently-learned
        # copy of the superseded body would key to nothing here and land as a
        # second active row, while every device that received the same two
        # revisions by merge folded it into one.
        self._record_convergence_identity(project_id, scope, body_hash, memory_id)
        if vector is not None:
            self.conn.execute(
                "INSERT INTO memory_vectors (memory_rowid, embedding_version, dimension, vector) VALUES (?, ?, ?, ?)",
                (rowid, self.provider.version_id, len(vector), encode_vector(vector)),
            )
        for subject, predicate, obj in relations:
            self.conn.execute(
                "INSERT INTO memory_relations (project_id, memory_id, subject, predicate, object, slot_key, confidence) VALUES (?,?,?,?,?,?,?)",
                (project_id, memory_id, subject, predicate, obj, _slot_key(subject, predicate), fact.confidence),
            )
        if gate.action == "retain" and gate.vault_body is not None:
            vault_cipher, vault_nonce = self.keyring.seal(gate.vault_body, f"{memory_id}|{project_id}|vault")
            self.conn.execute(
                "INSERT INTO memory_vault (memory_id, project_id, secret_cipher, secret_nonce, key_id, labels_json, created_at) VALUES (?,?,?,?,?,?,?)",
                (memory_id, project_id, vault_cipher, vault_nonce, self.keyring.key_id, _json_dumps(gate.labels), ts),
            )
        retired_supersede_targets = [
            target for target in supersede_targets if self._retire(target, reason="superseded", replacement=memory_id)
        ]
        if retired_supersede_targets != supersede_targets:
            self.conn.execute(
                "UPDATE memories SET supersedes_json = ? WHERE id = ?",
                (_json_dumps(retired_supersede_targets), memory_id),
            )
        hist_meta = {
            "supersedes": retired_supersede_targets,
            "previouslySupersededBy": (retired["superseded_by"] if retired is not None else None),
            "decidedBy": decided_by,
            "rationale": rationale,
        }
        # Attribution the timeline reads back: who wrote it, and what extracted it.
        for key in ("writerDevice", "writer_device", "deviceId", "device_id", "extracted_by", "model_id"):
            if metadata.get(key) is not None:
                hist_meta[key] = metadata[key]
        self._history(
            memory_id,
            project_id,
            "reactivated"
            if reactivated_id
            else ("created" if not retired_supersede_targets else "created_superseding"),
            None,
            body,
            hist_meta,
        )
        if gate.action == "redact":
            audit_event(
                self.conn,
                action="memory.secret_redacted" if gate.sensitivity == "redacted" else "memory.pii_redacted",
                project_id=project_id,
                subject_id=memory_id,
                labels=gate.labels,
                actor=self.config.actor,
            )
        elif gate.action == "retain":
            audit_event(
                self.conn,
                action="memory.secret_retained",
                project_id=project_id,
                subject_id=memory_id,
                labels=gate.labels,
                actor=self.config.actor,
            )
        if injection:
            audit_event(
                self.conn,
                action="memory.injection_quarantined",
                project_id=project_id,
                subject_id=memory_id,
                labels=injection,
                actor=self.config.actor,
            )
        audit_event(
            self.conn,
            action="memory.reactivate"
            if reactivated_id
            else ("memory.update" if retired_supersede_targets else "memory.add"),
            project_id=project_id,
            subject_id=memory_id,
            labels=[f"kind:{kind}", f"scope:{scope}", f"sensitivity:{gate.sensitivity}", f"review:{review_status}"],
            actor=self.config.actor,
        )
        decision: dict[str, Any] = {
            "event": "UPDATE" if (retired_supersede_targets or reactivated_id) else "ADD",
            "memoryID": memory_id,
            "kind": kind,
            "scope": scope,
            "text": body,
            "tags": list(fact.tags),
            "confidence": fact.confidence,
            "sourceRef": fact.source_ref,
            "expiresAt": fact.expires_at,
            "sensitivity": gate.sensitivity,
            "reviewStatus": review_status,
            "labels": gate.labels,
            "injectionLabels": injection,
            "superseded": retired_supersede_targets,
            "entities": entities,
            "relations": [{"subject": s, "predicate": p, "object": o} for s, p, o in relations],
            "embedded": vector is not None,
            "decidedBy": decided_by,
            "rationale": rationale,
        }
        if metadata.get("extracted_by"):
            decision["extractedBy"] = metadata["extracted_by"]
        if metadata.get("model_id"):
            decision["modelId"] = metadata["model_id"]
        if self._judge_outcome is not None:
            decision["judge"] = self._judge_outcome
        if reactivated_id:
            decision["reactivated"] = True
        return decision

    def _similarity(self, vector: list[float] | None, tokens: Sequence[str], existing: ActiveMemory) -> float:
        lexical = _jaccard(tokens, existing.tokens)
        if vector is not None and existing.vector is not None:
            return max(_cosine(vector, existing.vector), lexical)
        return lexical

    def _is_near_duplicate(
        self, vector: list[float] | None, tokens: Sequence[str], existing: ActiveMemory
    ) -> tuple[bool, float]:
        lexical = _jaccard(tokens, existing.tokens)
        cosine = _cosine(vector, existing.vector) if vector is not None and existing.vector is not None else 0.0
        return (cosine >= DEDUP_COSINE or lexical >= DEDUP_JACCARD), max(cosine, lexical)

    def _judge_candidates(
        self, vector: list[float] | None, tokens: Sequence[str], candidates: Sequence[ActiveMemory]
    ) -> list[tuple[float, ActiveMemory]]:
        """The closest eligible candidates for the judge: never immutable, never injection-labelled."""
        ranked = [
            (self._similarity(vector, tokens, item), item)
            for item in candidates
            if not item.immutable and not item.metadata.get("injectionLabels")
        ]
        ranked.sort(key=lambda pair: (-pair[0], pair[1].updated_at, pair[1].id))
        return ranked[:JUDGE_MAX_CANDIDATES]

    def _consult_judge(
        self, *, body: str, kind: str, scope: str, ranked: Sequence[tuple[float, ActiveMemory]]
    ) -> JudgeDecision | None:
        """One judge call inside the guardrails; None means the rules decide."""
        models = self.models
        if models is None or not models.serves("memory-judge"):
            self._judge_outcome = None
            return None
        try:
            call = models.call("memory-judge")
            verdict = llm_judge(
                call, incoming={"text": body, "kind": kind, "scope": scope}, candidates=[item for _, item in ranked]
            )
        except ModelUnavailable as exc:
            self._judge_outcome = ModelRouter.outcome("memory-judge", applied=False, code=exc.code)
            return None
        if verdict is None:
            self._judge_outcome = ModelRouter.outcome(
                "memory-judge", applied=False, code="JUDGE_OUT_OF_CONTRACT", model=call.label
            )
            return None
        self._judge_outcome = ModelRouter.outcome("memory-judge", applied=True, model=call.label)
        return verdict

    def _nearest(
        self, vector: list[float] | None, tokens: Sequence[str], candidates: Sequence[ActiveMemory]
    ) -> tuple[float, ActiveMemory] | None:
        best: tuple[float, ActiveMemory] | None = None
        for existing in candidates:
            duplicate, sim = self._is_near_duplicate(vector, tokens, existing)
            if duplicate and (best is None or sim > best[0]):
                best = (sim, existing)
        return best

    def _slot_rows(self, project_id: str, slot_keys: Iterable[str]) -> list[sqlite3.Row]:
        """Relation rows for the given slots across every project.

        Callers filter the rows down to their candidate memories, which already
        carry the right scope (this project, plus personal-scope memories from
        any project). Restricting here by `project_id` would hide a personal
        memory recorded in another repository from conflict resolution.
        """
        del project_id  # kept for call-site symmetry; candidates carry the scope
        keys = sorted(set(slot_keys))
        if not keys:
            return []
        placeholders = ",".join("?" * len(keys))
        slot_sql = (
            f"SELECT DISTINCT memory_id, slot_key, object FROM memory_relations WHERE slot_key IN ({placeholders})"  # noqa: S608 — placeholders only; values are bound
        )
        return self.conn.execute(slot_sql, keys).fetchall()

    def _resolve_conflicts(
        self,
        *,
        project_id: str,
        body: str,
        relations: Sequence[tuple[str, str, str]],
        vector: list[float] | None,
        tokens: Sequence[str],
        candidates: Sequence[ActiveMemory],
    ) -> tuple[list[str], list[str]]:
        """Return (supersede_targets, retire_targets).

        - Same (subject, predicate) slot with a *dissimilar* object → contradiction → supersede.
        - Negated statement ("X no longer uses Y") whose slot/object matches an existing
          memory → retire that memory and store nothing.
        - "switched from X to Y" → supersede memories whose object ≈ X.
        """
        by_id = {item.id: item for item in candidates}
        supersede: list[str] = []
        retire: list[str] = []

        def refers_to(a: str, b: str) -> float:
            # Overlap coefficient: "Cursor" refers to "Cursor for quick edits"; "Xcode 16" is
            # contained in "Xcode 16 with the iOS 26 SDK" (a refinement, not a contradiction),
            # while "Xcode 16" vs "Xcode 17" or "SQLCipher for X" vs "plain SQLite for X" score 0.5.
            sa, sb = set(tokenize(a)), set(tokenize(b))
            if not sa or not sb:
                return 0.0
            return len(sa & sb) / min(len(sa), len(sb))

        def same_claim(a: str, b: str) -> float:
            return refers_to(a, b)

        negated = NEGATION_RE.search(body) is not None
        switch = SWITCH_RE.search(body)
        if negated and not switch:
            stripped = NEGATION_RE.sub(" ", body)
            for subject, predicate, obj in extract_relations(stripped):
                for row in self._slot_rows(project_id, [_slot_key(subject, predicate)]):
                    existing = by_id.get(str(row["memory_id"]))
                    if existing is None:
                        continue
                    if refers_to(str(row["object"]), obj) >= CONFLICT_OBJECT_MAX_SIM and existing.id not in retire:
                        retire.append(existing.id)
            return [], retire

        if switch:
            old_object = switch.group("old").strip()
            for existing in candidates:
                for row in self.conn.execute(
                    "SELECT object FROM memory_relations WHERE memory_id = ?", (existing.id,)
                ).fetchall():
                    if (
                        refers_to(str(row["object"]), old_object) >= CONFLICT_OBJECT_MAX_SIM
                        and existing.id not in supersede
                    ):
                        supersede.append(existing.id)
            if supersede:
                return supersede, []

        new_objects = {_slot_key(s, p): o for s, p, o in relations}
        for row in self._slot_rows(project_id, new_objects.keys()):
            existing = by_id.get(str(row["memory_id"]))
            if existing is None:
                continue
            incoming_object = new_objects.get(str(row["slot_key"]), "")
            if same_claim(str(row["object"]), incoming_object) >= SAME_CLAIM_MIN_OVERLAP:
                continue  # same claim, differently worded or refined: not a contradiction
            if self._similarity(vector, tokens, existing) >= CONFLICT_MIN_SIM and existing.id not in supersede:
                supersede.append(existing.id)
        return supersede, []

    def _reinforce(
        self,
        memory_id: str,
        fact: Fact,
        entities: Sequence[str],
        *,
        reason: str,
        incoming_body: str,
        labels: Sequence[str] = (),
        quarantine_labels: Sequence[str] = (),
        reactivate: bool = False,
        stamp_updated_at: bool = True,
    ) -> dict[str, Any]:
        """Merge a duplicate into `memory_id`.

        `incoming_body` is the *gated* body of the duplicate; it is recorded in
        the encrypted history column, never in plaintext meta. `reactivate`
        clears an expired row's expiry (to the incoming fact's, if any).

        `stamp_updated_at=False` is the blind-sync merge: `updated_at` is the
        row's last *writer* mark, and a duplicate arriving from another device is
        not a writer on this one. Stamping this device's wall clock there would
        make the row look newer than every remote revision authored before the
        merge ran, and the genuinely newer edit would then lose last-writer-wins
        for ever.
        """
        row = self._get_row(memory_id)
        if row is None:
            return {"event": "NONE", "memoryID": memory_id, "reason": reason}
        existing = self._row_to_memory(row)
        if existing is None:
            return {"event": "NONE", "memoryID": memory_id, "reason": reason}
        merged_tags = normalize_tags(list(existing.tags) + list(fact.tags))
        merged_entities = list(dict.fromkeys(list(existing.entities) + list(entities)))[:16]
        confidence = max(existing.confidence, fact.confidence)
        access = existing.access_count + 1
        ts = now_iso()
        if fact.review_status == "rejected":
            review_status = "rejected"
        elif quarantine_labels or fact.review_status == "quarantined":
            review_status = "quarantined"
        else:
            review_status = existing.review_status
        sensitivity = "secret" if fact.sensitivity == "secret" else existing.sensitivity
        columns: list[Any] = [
            _json_dumps(merged_tags),
            _json_dumps(merged_entities),
            confidence,
            access,
            self.compute_salience(existing.kind, confidence, access),
            review_status,
            sensitivity,
        ]
        if stamp_updated_at:
            columns.append(ts)
            self.conn.execute(
                "UPDATE memories SET tags_json = ?, entities_json = ?, confidence = ?, access_count = ?, "
                "salience = ?, review_status = ?, sensitivity = ?, updated_at = ? WHERE id = ?",
                (*columns, memory_id),
            )
        else:
            self.conn.execute(
                "UPDATE memories SET tags_json = ?, entities_json = ?, confidence = ?, access_count = ?, "
                "salience = ?, review_status = ?, sensitivity = ? WHERE id = ?",
                (*columns, memory_id),
            )
        if reactivate:
            self.conn.execute("UPDATE memories SET expires_at = ? WHERE id = ?", (fact.expires_at, memory_id))
        meta = {"reason": reason, "incomingHash": sha256_hex(incoming_body.lower())[:16], "labels": sorted(set(labels))}
        if reactivate:
            meta["expiresAt"] = {"before": existing.expires_at, "after": fact.expires_at}
        self._history(
            memory_id, existing.project_id, "reactivated" if reactivate else "reinforced", None, incoming_body, meta
        )
        audit_event(
            self.conn,
            action="memory.reactivate" if reactivate else "memory.reinforce",
            project_id=existing.project_id,
            subject_id=memory_id,
            labels=[reason.split(" (")[0]],
            actor=self.config.actor,
        )
        if quarantine_labels:
            audit_event(
                self.conn,
                action="memory.injection_quarantined",
                project_id=existing.project_id,
                subject_id=memory_id,
                labels=sorted(set(quarantine_labels)),
                actor=self.config.actor,
            )
        daemon_visible_changed = (
            merged_tags != existing.tags or confidence != existing.confidence or sensitivity != existing.sensitivity
        )
        decision: dict[str, Any] = {
            "event": "UPDATE"
            if (reactivate or review_status != existing.review_status or daemon_visible_changed)
            else "NONE",
            "memoryID": memory_id,
            "reason": reason,
            "kind": existing.kind,
            "scope": existing.scope,
            "text": existing.body,
            "tags": merged_tags,
            "confidence": confidence,
            "sourceRef": existing.source_ref,
            "expiresAt": fact.expires_at if reactivate else existing.expires_at,
            "sensitivity": sensitivity,
            "reviewStatus": review_status,
        }
        if reactivate:
            decision["reactivated"] = True
        return decision

    def _rotate_vault(self, memory_id: str, project_id: str, gate: GateDecision) -> bool:
        """Replace a retained secret when a duplicate redacted body arrives with a
        different verbatim text. Returns True when the vault changed."""
        if gate.vault_body is None:
            return False
        current = self._open_vault(memory_id, project_id)
        sensitivity = self.conn.execute(
            "SELECT sensitivity FROM memories WHERE id = ? AND project_id = ?", (memory_id, project_id)
        ).fetchone()
        promoted = sensitivity is not None and str(sensitivity["sensitivity"]) != "secret"
        if current == gate.vault_body:
            if promoted:
                self.conn.execute(
                    "UPDATE memories SET sensitivity = 'secret', updated_at = ? WHERE id = ? AND project_id = ?",
                    (now_iso(), memory_id, project_id),
                )
            return promoted
        vault_cipher, vault_nonce = self.keyring.seal(gate.vault_body, f"{memory_id}|{project_id}|vault")
        self.conn.execute(
            "INSERT OR REPLACE INTO memory_vault (memory_id, project_id, secret_cipher, secret_nonce, key_id, labels_json, created_at) VALUES (?,?,?,?,?,?,?)",
            (
                memory_id,
                project_id,
                vault_cipher,
                vault_nonce,
                self.keyring.key_id,
                _json_dumps(gate.labels),
                now_iso(),
            ),
        )
        self.conn.execute(
            "UPDATE memories SET sensitivity = 'secret', updated_at = ? WHERE id = ? AND project_id = ?",
            (now_iso(), memory_id, project_id),
        )
        self._history(memory_id, project_id, "vault_rotated", None, None, {"labels": sorted(set(gate.labels))})
        audit_event(
            self.conn,
            action="memory.secret_rotated",
            project_id=project_id,
            subject_id=memory_id,
            labels=gate.labels,
            actor=self.config.actor,
        )
        return True

    def _hydrate_ingest_decision(self, decision: dict[str, Any]) -> dict[str, Any]:
        memory_id = str(decision.get("memoryID") or "")
        if not memory_id or decision.get("event") not in ("ADD", "UPDATE"):
            return decision
        result = self.get(memory_id)
        memory = result.get("memory")
        if not isinstance(memory, dict):
            return decision
        return {
            **decision,
            "kind": memory.get("kind"),
            "scope": memory.get("scope"),
            "text": memory.get("body"),
            "tags": list(memory.get("tags") or []),
            "confidence": memory.get("confidence"),
            "sourceRef": memory.get("sourceRef"),
            "expiresAt": memory.get("expiresAt"),
            "sensitivity": memory.get("sensitivity"),
            "reviewStatus": memory.get("reviewStatus"),
        }

    def _missing_ids(self, memory_ids: Sequence[str]) -> list[str]:
        wanted = [str(item) for item in memory_ids if item]
        if not wanted:
            return []
        found: set[str] = set()
        for start in range(0, len(wanted), 500):
            chunk = wanted[start : start + 500]
            placeholders = ",".join("?" * len(chunk))
            missing_sql = f"SELECT id FROM memories WHERE id IN ({placeholders})"  # noqa: S608 — placeholders only; values are bound
            found.update(str(row["id"]) for row in self.conn.execute(missing_sql, chunk).fetchall())
        return [item for item in wanted if item not in found]

    def _retire(self, memory_id: str, *, reason: str, replacement: str | None, remote_at: str | None = None) -> bool:
        """Close a row out. `remote_at` is the blind-sync merge: the retirement
        instant comes from the remote revision that caused it, and `updated_at` —
        the row's last *writer* mark, which last-writer-wins reads — is left
        alone, because a merge is not a local write. Stamping this device's clock
        there would make every remote revision authored before the merge ran look
        stale for ever.
        """
        row = self._get_row(memory_id)
        if row is None or row["valid_to"] is not None:
            return False
        if bool(row["immutable"]):
            self._history(
                memory_id,
                str(row["project_id"]),
                "retire_blocked_immutable",
                None,
                None,
                {"reason": reason, "replacement": replacement},
            )
            return False
        if remote_at is None:
            ts = now_iso()
            self.conn.execute(
                "UPDATE memories SET valid_to = ?, superseded_by = ?, updated_at = ? WHERE id = ?",
                (ts, replacement, ts, memory_id),
            )
        else:
            self.conn.execute(
                "UPDATE memories SET valid_to = ?, superseded_by = ? WHERE id = ?",
                (remote_at, replacement, memory_id),
            )
        self._history(
            memory_id, str(row["project_id"]), "retired", None, None, {"reason": reason, "replacement": replacement}
        )
        return True

    def _history(
        self, memory_id: str, project_id: str, event: str, before: str | None, after: str | None, meta: dict[str, Any]
    ) -> None:
        aad = f"{memory_id}|{project_id}|history"
        before_cipher = before_nonce = after_cipher = after_nonce = None
        if before is not None:
            before_cipher, before_nonce = self.keyring.seal(before, aad)
        if after is not None:
            after_cipher, after_nonce = self.keyring.seal(after, aad)
        self.conn.execute(
            "INSERT INTO memory_history (memory_id, project_id, event, actor, ts, before_cipher, before_nonce, after_cipher, after_nonce, key_id, meta_json) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
            (
                memory_id,
                project_id,
                event,
                self.config.actor,
                now_iso(),
                before_cipher,
                before_nonce,
                after_cipher,
                after_nonce,
                self.keyring.key_id,
                _json_dumps(meta),
            ),
        )

    def fold(
        self,
        folded_id: str,
        canonical_id: str | None = None,
        *,
        into: str | None = None,
        reason: str = "folded",
    ) -> dict[str, Any]:
        """Fold a memory id into a canonical row.

        Writes `memory_alias:<folded_id>` to engine_meta, retires `folded_id`
        if present in memories, and records a memory_history entry.
        """
        target = canonical_id or into
        if not target or not folded_id:
            return {"status": "error", "reason": "missing_ids"}
        if folded_id == target:
            return {"status": "ok", "event": "NONE", "reason": "self_fold_no_op", "memoryID": target}

        resolved_target = self._alias_target(target) or target
        target_row = self.conn.execute(
            "SELECT rowid, id, project_id, valid_to FROM memories WHERE id = ?", (resolved_target,)
        ).fetchone()
        if target_row is None:
            return {"status": "not_found", "memoryID": resolved_target}

        existing_alias = self._alias_target(folded_id)
        if existing_alias == resolved_target:
            return {
                "status": "ok",
                "event": "NONE",
                "reason": "already_folded",
                "memoryID": resolved_target,
                "foldedID": folded_id,
            }

        folded_row = self.conn.execute(
            "SELECT rowid, id, project_id, valid_to, metadata_json, tags_json FROM memories WHERE id = ?", (folded_id,)
        ).fetchone()
        # Written after the lookup, so the alias and the retirement it describes
        # happen together. A folded id with no local row is still legitimate —
        # a remote id folding into a local one is exactly that — but the alias
        # is no longer recorded before this method knows what it is folding.
        self._record_memory_alias(folded_id, resolved_target)
        if folded_row is not None and folded_row["valid_to"] is None:
            meta = _json_loads(folded_row["metadata_json"], {})
            meta["foldedInto"] = resolved_target
            tags = normalize_tags(list(_json_loads(folded_row["tags_json"], [])) + ["folded"])
            self.conn.execute(
                "UPDATE memories SET metadata_json = ?, tags_json = ? WHERE id = ?",
                (_json_dumps(meta), _json_dumps(tags), folded_id),
            )
            self._retire(folded_id, reason=reason, replacement=resolved_target)

        target_proj = str(target_row["project_id"])
        self._history(
            resolved_target,
            target_proj,
            "fold_absorbed",
            None,
            None,
            {"foldedID": folded_id, "reason": reason},
        )
        if folded_row is not None:
            self._history(
                folded_id,
                str(folded_row["project_id"]),
                "folded",
                None,
                None,
                {"canonicalID": resolved_target, "reason": reason},
            )

        if folded_row is not None:
            inv = self.conn.execute("SELECT supersedes_json FROM memories WHERE id = ?", (resolved_target,)).fetchone()
            if inv is not None:
                supersedes = sorted({*_json_loads(inv["supersedes_json"], []), folded_id})
                self.conn.execute(
                    "UPDATE memories SET supersedes_json = ? WHERE id = ?",
                    (_json_dumps(supersedes), resolved_target),
                )

        # A fold changes which row an id resolves to, for good. Every other
        # id-lifecycle decision — add, update, forget, sync add, resurrection
        # refused — leaves a label-only row in the hash chain; this one left
        # `memory_history` and nothing else, so the record of decisions did not
        # contain the redirection.
        audit_event(
            self.conn,
            project_id=target_proj,
            action="memory.fold",
            subject_id=resolved_target,
            labels=[f"folded:{folded_id}", f"reason:{reason}", "retired" if folded_row is not None else "alias_only"],
            actor=self.config.actor,
        )
        self._commit()
        self._invalidate_cache()
        return {
            "status": "ok",
            "event": "FOLD",
            "canonicalID": resolved_target,
            "foldedID": folded_id,
            "reason": reason,
        }
