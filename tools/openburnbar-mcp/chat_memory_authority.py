"""Chat-memory authority read helpers for the main OpenBurnBar SQLite DB (B6)."""

from __future__ import annotations

import json
import sqlite3
from datetime import datetime, timezone
from typing import Any


def _table_columns(conn: sqlite3.Connection, table: str) -> set[str]:
    rows = conn.execute(f"PRAGMA table_info({table})").fetchall()
    return {str(row[1]) for row in rows}


def _has_chat_authority_schema(conn: sqlite3.Connection) -> bool:
    tables = {
        str(row[0])
        for row in conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table'"
        ).fetchall()
    }
    if "agent_memories" not in tables:
        return False
    cols = _table_columns(conn, "agent_memories")
    return "source_kind" in cols and "review_status" in cols


def get_chat_memory(conn: sqlite3.Connection, memory_id: str) -> dict[str, Any]:
    if not _has_chat_authority_schema(conn):
        return {
            "status": "unavailable",
            "code": "CHAT_MEMORY_SCHEMA_MISSING",
            "reason": "agent_memories chat authority columns are not present",
        }
    row = conn.execute(
        """
        SELECT id, kind, user_id, agent_id, run_id, app_id, project_id,
               confidence, body_redacted, review_status, valid_from, valid_to,
               created_at, updated_at
        FROM agent_memories
        WHERE id = ? AND source_kind = 'chat'
        """,
        (memory_id,),
    ).fetchone()
    if row is None:
        return {"status": "not_found", "memoryID": memory_id}
    return {"status": "ok", "memory": _row_to_memory(row)}


def list_chat_memories(
    conn: sqlite3.Connection,
    *,
    user_id: str | None = None,
    app_id: str | None = None,
    review_status: str | None = None,
    page: int = 1,
    page_size: int = 50,
) -> dict[str, Any]:
    if not _has_chat_authority_schema(conn):
        return {
            "status": "unavailable",
            "code": "CHAT_MEMORY_SCHEMA_MISSING",
            "reason": "agent_memories chat authority columns are not present",
        }
    where = ["source_kind = 'chat'"]
    args: list[Any] = []
    if user_id:
        where.append("user_id = ?")
        args.append(user_id)
    if app_id:
        where.append("app_id = ?")
        args.append(app_id)
    if review_status:
        where.append("review_status = ?")
        args.append(review_status)
    where_sql = " AND ".join(where)
    total = int(
        conn.execute(
            f"SELECT COUNT(*) FROM agent_memories WHERE {where_sql}",
            args,
        ).fetchone()[0]
    )
    lim = max(1, min(int(page_size), 200))
    off = max(0, (max(1, int(page)) - 1) * lim)
    rows = conn.execute(
        f"""
        SELECT id, kind, user_id, agent_id, run_id, app_id, project_id,
               confidence, body_redacted, review_status, valid_from, valid_to,
               created_at, updated_at
        FROM agent_memories
        WHERE {where_sql}
        ORDER BY updated_at DESC
        LIMIT ? OFFSET ?
        """,
        [*args, lim, off],
    ).fetchall()
    return {
        "status": "ok",
        "page": max(1, int(page)),
        "pageSize": lim,
        "total": total,
        "items": [_row_to_memory(row) for row in rows],
    }


def list_chat_memory_entities(conn: sqlite3.Connection) -> dict[str, Any]:
    if not _has_chat_authority_schema(conn):
        return {
            "status": "unavailable",
            "code": "CHAT_MEMORY_SCHEMA_MISSING",
            "reason": "agent_memories chat authority columns are not present",
        }
    rows = conn.execute(
        """
        SELECT
            CASE WHEN user_id IS NOT NULL AND user_id != '' THEN 'user_id' ELSE 'app_id' END AS key_name,
            COALESCE(NULLIF(user_id, ''), NULLIF(app_id, ''), 'unscoped') AS value,
            COUNT(*) AS count
        FROM agent_memories
        WHERE source_kind = 'chat' AND review_status = 'approved' AND valid_to IS NULL
        GROUP BY key_name, value
        ORDER BY count DESC, value ASC
        """
    ).fetchall()
    entities = [
        {"keyName": row[0], "value": row[1], "count": int(row[2])}
        for row in rows
    ]
    return {"status": "ok", "entities": entities}


def _row_to_memory(row: sqlite3.Row | tuple[Any, ...]) -> dict[str, Any]:
    if hasattr(row, "keys"):
        data = {key: row[key] for key in row.keys()}
    else:
        keys = [
            "id",
            "kind",
            "user_id",
            "agent_id",
            "run_id",
            "app_id",
            "project_id",
            "confidence",
            "body_redacted",
            "review_status",
            "valid_from",
            "valid_to",
            "created_at",
            "updated_at",
        ]
        data = dict(zip(keys, row, strict=False))
    return {
        "id": data.get("id"),
        "kind": data.get("kind"),
        "scope": {
            "userID": data.get("user_id"),
            "agentID": data.get("agent_id"),
            "runID": data.get("run_id"),
            "appID": data.get("app_id"),
            "projectID": data.get("project_id"),
        },
        "confidence": data.get("confidence"),
        "bodyRedacted": data.get("body_redacted"),
        "reviewStatus": data.get("review_status"),
        "validFrom": data.get("valid_from"),
        "validTo": data.get("valid_to"),
        "createdAt": data.get("created_at"),
        "updatedAt": data.get("updated_at"),
        "sourceKind": "chat",
    }


def iso_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
