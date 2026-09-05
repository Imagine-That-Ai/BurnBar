"""Guarded assistant-export importer for ChatGPT and Claude.ai data exports.

Strict export-schema version gate: unknown versions are rejected, never guessed.
Parser output is quarantine-only (review_status = 'quarantined').
Entry secret sweep flags secrets and refuses to store them.
Convergent deduplication collapses identical bodies on (project, scope, body_hash).
Bounded batches respect an export cap and report full summary metrics.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from collections.abc import Sequence
from typing import Any

from memory_engine import Fact, canonical_body_hash, normalize_scope, resolve_project
from memory_engine._util import _convergence_key
from memory_engine.gate import scan_text
from memory_engine.store import audit_event

DEFAULT_IMPORT_BATCH_CAP = 10

SUPPORTED_ASSISTANT_EXPORT_SCHEMAS: frozenset[str] = frozenset(
    {
        "chatgpt.export.v1",
        "openai.chatgpt.export.v1",
        "chatgpt.conversations.v1",
        "claude.export.v1",
        "anthropic.claude.export.v1",
        "claude.conversations.v1",
        "openburnbar.assistant_export.v1",
    }
)


@dataclass
class CandidateMemory:
    text: str
    source_ref: str
    tags: list[str] = field(default_factory=list)
    entities: list[str] = field(default_factory=list)
    metadata: dict[str, Any] = field(default_factory=dict)
    kind: str = "fact"
    scope: str = "project"


def is_assistant_export(payload: dict[str, Any], explicit_schema: str | None = None) -> bool:
    """True if payload or argument indicates an assistant export format."""
    schema = explicit_schema or payload.get("schema") or payload.get("schema_version") or payload.get("version")
    if schema:
        schema_str = str(schema).strip()
        if schema_str in SUPPORTED_ASSISTANT_EXPORT_SCHEMAS:
            return True
        if schema_str.startswith(
            ("chatgpt.", "openai.chatgpt.", "claude.", "anthropic.claude.", "openburnbar.assistant_export.")
        ):
            return True
    if any(k in payload for k in ("conversations", "chat_messages")):
        return True
    return False


def validate_export_schema(schema: str | None) -> dict[str, Any] | None:
    """Fail-closed schema gate: return rejection dict if unknown/unsupported."""
    if not schema or not str(schema).strip():
        return {
            "status": "rejected",
            "code": "UNKNOWN_SCHEMA_VERSION",
            "reason": (
                "missing export schema version; assistant exports require an explicit "
                f"supported schema version (supported: {', '.join(sorted(SUPPORTED_ASSISTANT_EXPORT_SCHEMAS))})"
            ),
        }
    clean = str(schema).strip()
    if clean not in SUPPORTED_ASSISTANT_EXPORT_SCHEMAS:
        return {
            "status": "rejected",
            "code": "UNKNOWN_SCHEMA_VERSION",
            "reason": (
                f"unknown or unsupported export schema version '{clean}'; "
                f"supported versions: {', '.join(sorted(SUPPORTED_ASSISTANT_EXPORT_SCHEMAS))}"
            ),
        }
    return None


def parse_chatgpt_conversations(conversations: Sequence[dict[str, Any]]) -> list[CandidateMemory]:
    """Extract candidate memories from ChatGPT conversations.json."""
    candidates: list[CandidateMemory] = []
    for conv in conversations:
        if not isinstance(conv, dict):
            continue
        conv_id = str(conv.get("id") or conv.get("conversation_id") or "unknown_conv")
        title = str(conv.get("title") or "").strip()

        mapping = conv.get("mapping")
        if isinstance(mapping, dict):
            # Sort node keys for deterministic ordering
            sorted_nodes = sorted(
                mapping.values(),
                key=lambda n: (
                    (n.get("message") or {}).get("create_time") or 0.0 if isinstance(n, dict) else 0.0,
                    str(n.get("id") if isinstance(n, dict) else ""),
                ),
            )
            for node in sorted_nodes:
                if not isinstance(node, dict):
                    continue
                msg = node.get("message")
                if not isinstance(msg, dict):
                    continue
                author = msg.get("author") or {}
                role = str(author.get("role") or "").strip().lower()
                content = msg.get("content") or {}
                parts = content.get("parts") or []
                text = "\n".join(str(p) for p in parts if p is not None).strip()
                if not text:
                    continue
                msg_id = str(msg.get("id") or node.get("id") or f"node_{len(candidates)}")
                candidates.append(
                    CandidateMemory(
                        text=text,
                        source_ref=f"chatgpt:{conv_id}#{msg_id}",
                        tags=["chatgpt", "assistant_export"],
                        metadata={
                            "client": "chatgpt",
                            "conversationID": conv_id,
                            "conversationTitle": title,
                            "role": role,
                        },
                        kind="fact",
                        scope="project",
                    )
                )

        messages = conv.get("messages")
        if isinstance(messages, list):
            for idx, msg in enumerate(messages):
                if not isinstance(msg, dict):
                    continue
                text = str(msg.get("text") or msg.get("content") or "").strip()
                if not text:
                    continue
                msg_id = str(msg.get("id") or f"msg_{idx}")
                role = str(msg.get("role") or msg.get("sender") or "").strip().lower()
                candidates.append(
                    CandidateMemory(
                        text=text,
                        source_ref=f"chatgpt:{conv_id}#{msg_id}",
                        tags=["chatgpt", "assistant_export"],
                        metadata={
                            "client": "chatgpt",
                            "conversationID": conv_id,
                            "conversationTitle": title,
                            "role": role,
                        },
                        kind="fact",
                        scope="project",
                    )
                )
    return candidates


def parse_claude_conversations(conversations: Sequence[dict[str, Any]]) -> list[CandidateMemory]:
    """Extract candidate memories from Claude.ai conversations.json."""
    candidates: list[CandidateMemory] = []
    for conv in conversations:
        if not isinstance(conv, dict):
            continue
        conv_id = str(conv.get("uuid") or conv.get("id") or "unknown_conv")
        title = str(conv.get("name") or conv.get("title") or "").strip()
        chat_messages = conv.get("chat_messages") or []
        if isinstance(chat_messages, list):
            for idx, msg in enumerate(chat_messages):
                if not isinstance(msg, dict):
                    continue
                text = str(msg.get("text") or msg.get("content") or "").strip()
                if not text:
                    continue
                msg_id = str(msg.get("uuid") or msg.get("id") or f"msg_{idx}")
                sender = str(msg.get("sender") or msg.get("role") or "").strip().lower()
                candidates.append(
                    CandidateMemory(
                        text=text,
                        source_ref=f"claude:{conv_id}#{msg_id}",
                        tags=["claude", "assistant_export"],
                        metadata={
                            "client": "claude",
                            "conversationID": conv_id,
                            "conversationTitle": title,
                            "sender": sender,
                        },
                        kind="fact",
                        scope="project",
                    )
                )
    return candidates


def parse_direct_memories(memories: Sequence[dict[str, Any]], client: str = "assistant") -> list[CandidateMemory]:
    """Extract candidate memories from an explicit memories list."""
    candidates: list[CandidateMemory] = []
    for idx, raw in enumerate(memories):
        if not isinstance(raw, dict):
            continue
        text = str(raw.get("content") or raw.get("text") or raw.get("body") or "").strip()
        if not text:
            continue
        mem_id = str(raw.get("id") or f"mem_{idx}")
        candidates.append(
            CandidateMemory(
                text=text,
                source_ref=f"{client}:memory#{mem_id}",
                tags=[client, "assistant_export"],
                metadata={"client": client, "source": "direct_memory"},
                kind="fact",
                scope="project",
            )
        )
    return candidates


def parse_assistant_export(payload: dict[str, Any], schema: str) -> list[CandidateMemory]:
    """Dispatch export parsing based on schema and payload shape."""
    schema_clean = schema.lower().strip()
    client = "chatgpt" if "chatgpt" in schema_clean else ("claude" if "claude" in schema_clean else "assistant")

    # If payload has direct memories list
    if isinstance(payload.get("memories"), list) and not payload.get("conversations"):
        return parse_direct_memories(payload["memories"], client=client)

    conversations = payload.get("conversations")
    if not isinstance(conversations, list):
        if "mapping" in payload:
            conversations = [payload]
        elif "chat_messages" in payload:
            conversations = [payload]
        else:
            conversations = []

    if client == "chatgpt":
        return parse_chatgpt_conversations(conversations)
    if client == "claude":
        return parse_claude_conversations(conversations)

    # General fallback for openburnbar.assistant_export.v1
    detected_client = str(payload.get("client") or "").strip().lower()
    if detected_client == "claude":
        return parse_claude_conversations(conversations)
    return parse_chatgpt_conversations(conversations)


def import_assistant_export(
    engine: Any,
    payload: dict[str, Any],
    *,
    schema: str,
    project_path: str | None = None,
    batch_cap: int | None = None,
) -> dict[str, Any]:
    """Guarded import of an assistant export payload into the memory engine."""
    # 1. Strict schema version gate
    rejection = validate_export_schema(schema)
    if rejection:
        return rejection

    project_id, root = resolve_project(engine.conn, project_path)

    # 2. Parse candidate memories
    all_candidates = parse_assistant_export(payload, schema)

    # 3. Bounded batches with cap
    cap = (
        batch_cap
        if batch_cap is not None
        else int(os.environ.get("OPENBURNBAR_MEMORY_IMPORT_BATCH_CAP", str(DEFAULT_IMPORT_BATCH_CAP)))
    )
    is_batch_capped = len(all_candidates) > cap
    bounded_candidates = all_candidates[:cap]

    decisions: list[dict[str, Any]] = []
    secrets_flagged = 0
    duplicates_collapsed = 0
    quarantined_count = 0
    seen_ckeys: set[str] = set()

    for candidate in bounded_candidates:
        # 4. Secret sweep on entry
        findings = scan_text(candidate.text)
        if findings.has_secret:
            secrets_flagged += 1
            decisions.append(
                {
                    "event": "REJECT",
                    "code": "SECRET_DETECTED",
                    "labels": findings.secret_labels,
                    "sourceRef": candidate.source_ref,
                    "reason": "secret detected during export entry sweep; flagged and not stored",
                }
            )
            continue

        # 5. Convergence key deduplication
        try:
            scope = normalize_scope(candidate.scope, candidate.kind)
        except ValueError:
            scope = "project"

        body_hash = canonical_body_hash(candidate.text)
        ckey = _convergence_key(project_id, scope, body_hash)

        if ckey in seen_ckeys:
            duplicates_collapsed += 1
            decisions.append(
                {
                    "event": "COLLAPSE",
                    "code": "DUPLICATE_CONVERGENCE_KEY",
                    "convergenceKey": ckey,
                    "bodyHash": body_hash,
                    "sourceRef": candidate.source_ref,
                    "reason": "duplicate body collapsed on convergence key",
                }
            )
            continue
        seen_ckeys.add(ckey)

        # Check existing destination project store
        existing = engine.conn.execute(
            "SELECT id, review_status FROM memories WHERE project_id = ? AND scope = ? AND body_hash = ? AND valid_to IS NULL",
            (project_id, scope, body_hash),
        ).fetchone()
        if existing is not None:
            duplicates_collapsed += 1
            decisions.append(
                {
                    "event": "NONE",
                    "code": "DUPLICATE_CONVERGENCE_KEY",
                    "convergenceKey": ckey,
                    "memoryID": str(existing["id"]),
                    "bodyHash": body_hash,
                    "sourceRef": candidate.source_ref,
                    "reason": "duplicate body collapsed against existing store convergence key",
                }
            )
            continue

        # 6. Parser -> Quarantine only
        fact = Fact(
            text=candidate.text,
            kind=candidate.kind,
            confidence=0.7,
            scope=scope,
            tags=candidate.tags,
            entities=candidate.entities,
            metadata=candidate.metadata,
            source_ref=candidate.source_ref,
            review_status="quarantined",  # STRICTLY QUARANTINED!
        )

        decision = engine._commit_fact(
            project_id=project_id,
            root=root,
            fact=fact,
            source_kind="import",
            source_hash=f"assistant_import:{ckey}",
            extractor="assistant_export",
        )
        decision["reviewStatus"] = "quarantined"
        decision["convergenceKey"] = ckey
        decisions.append(decision)
        if decision.get("event") in ("ADD", "UPDATE"):
            quarantined_count += 1

    # 7. Audit and commit
    audit_event(
        engine.conn,
        action="memory.assistant_import",
        project_id=project_id,
        subject_id=None,
        labels=[
            f"schema:{schema}",
            f"imported:{quarantined_count}",
            f"quarantined:{quarantined_count}",
            f"secrets_flagged:{secrets_flagged}",
            f"duplicates_collapsed:{duplicates_collapsed}",
            f"batch_capped:{str(is_batch_capped).lower()}",
        ],
        actor=engine.config.actor,
    )
    engine._commit()
    engine._invalidate_cache()

    # 8. Return comprehensive summary
    summary = {
        "imported": quarantined_count,
        "quarantined": quarantined_count,
        "approved": 0,
        "secretsFlagged": secrets_flagged,
        "duplicatesCollapsed": duplicates_collapsed,
        "totalCandidates": len(all_candidates),
        "batchCap": cap,
        "batchCapped": is_batch_capped,
        "ADD": quarantined_count,
        "UPDATE": 0,
        "NONE": duplicates_collapsed,
        "DELETE": 0,
        "REJECT": secrets_flagged,
    }

    return {
        "status": "ok",
        "summary": summary,
        "decisions": decisions,
        "schema": schema,
        "projectID": project_id,
        "projectPath": root,
    }
