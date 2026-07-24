#!/usr/bin/env python3
"""Create a bounded Activity database and usage ledger for installed P-17 QA."""

from __future__ import annotations

import argparse
import json
import os
import sqlite3
from datetime import UTC, datetime
from pathlib import Path


def fail(message: str) -> None:
    raise RuntimeError(message)


def owner_only_empty_parent(file: Path) -> Path:
    parent = file.parent.resolve(strict=True)
    stat = parent.stat()
    if not parent.is_dir() or stat.st_uid != os.getuid() or stat.st_mode & 0o077:
        fail("P-17 seed parent must be an owner-only directory")
    if file.exists() or file.is_symlink():
        fail("P-17 seed database must not exist")
    return parent


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--database", required=True)
    parser.add_argument("--usage-ledger", required=True)
    parser.add_argument("--home", required=True)
    parser.add_argument("--session-id", required=True)
    parser.add_argument("--marker", required=True)
    args = parser.parse_args()

    database = Path(args.database)
    usage = Path(args.usage_ledger)
    home = Path(args.home).resolve(strict=True)
    session_id = args.session_id.strip()
    marker = args.marker.strip()
    if not session_id or len(session_id.encode()) > 128 or not marker or len(marker.encode()) > 128:
        fail("P-17 seed identity is invalid")
    owner_only_empty_parent(database)
    if (
        usage.exists()
        or usage.is_symlink()
        or usage.parent.resolve(strict=True) != database.parent.resolve(strict=True)
    ):
        fail("P-17 usage ledger must be a missing sibling of the database")
    if home.stat().st_uid != os.getuid() or home.stat().st_mode & 0o077:
        fail("P-17 isolated home must be owner-only")

    source_id = f"Codex:{session_id}"
    ambiguous_session_id = f"ambiguous-{session_id}"
    timestamp = datetime.now(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    title = f"P17 {marker} activity proof"
    body = f"User requested {marker}.\n\nAssistant completed the indexed Activity workflow for {marker}."
    summary = f"Indexed Activity proof {marker}"

    connection = sqlite3.connect(database)
    try:
        connection.executescript(
            """
            PRAGMA journal_mode=WAL;
            CREATE TABLE conversations (
              id TEXT PRIMARY KEY, provider TEXT NOT NULL, sessionId TEXT NOT NULL,
              projectName TEXT NOT NULL, startTime TEXT, endTime TEXT,
              messageCount INTEGER NOT NULL DEFAULT 0, userWordCount INTEGER NOT NULL DEFAULT 0,
              assistantWordCount INTEGER NOT NULL DEFAULT 0, keyFiles TEXT, keyCommands TEXT,
              keyTools TEXT, inferredTaskTitle TEXT NOT NULL DEFAULT '',
              lastAssistantMessage TEXT NOT NULL DEFAULT '', fullText TEXT NOT NULL DEFAULT '',
              indexedAt TEXT NOT NULL, fileModifiedAt TEXT, summary TEXT,
              conversationSyncedAt TEXT, sourceType TEXT NOT NULL DEFAULT 'provider_log',
              logSyncedAt TEXT, summaryTitle TEXT, summaryUpdatedAt TEXT,
              summaryProvider TEXT, summaryModel TEXT, summaryAttemptedAt TEXT,
              sourceDeviceId TEXT, sourceDeviceName TEXT, isRemote INTEGER NOT NULL DEFAULT 0,
              workingDirectory TEXT, deletedAt TEXT
            );
            CREATE TABLE search_documents (
              id TEXT PRIMARY KEY, sourceKind TEXT NOT NULL, sourceID TEXT NOT NULL,
              sourceVersionID TEXT NOT NULL DEFAULT '', provider TEXT, projectName TEXT,
              title TEXT NOT NULL, subtitle TEXT, bodyPreview TEXT, sourceUpdatedAt TEXT,
              indexedAt TEXT NOT NULL, contentHash TEXT, createdAt TEXT NOT NULL,
              updatedAt TEXT NOT NULL
            );
            CREATE TABLE search_chunks (
              id TEXT PRIMARY KEY, documentID TEXT NOT NULL, sourceKind TEXT NOT NULL,
              sourceID TEXT NOT NULL, sourceVersionID TEXT NOT NULL DEFAULT '',
              ordinal INTEGER NOT NULL, startOffset INTEGER NOT NULL, endOffset INTEGER NOT NULL,
              messageStartOffset INTEGER, messageEndOffset INTEGER, sectionPath TEXT,
              text TEXT NOT NULL, contentHash TEXT, createdAt TEXT NOT NULL,
              updatedAt TEXT NOT NULL, ftsRowid INTEGER
            );
            CREATE VIRTUAL TABLE search_chunks_fts USING fts5(
              chunkID UNINDEXED, documentID UNINDEXED, title, chunkText,
              projectName, provider, tokenize='porter unicode61'
            );
            """
        )
        document_id = f"p17-doc-{session_id}"
        chunk_id = f"p17-chunk-{session_id}"
        connection.execute(
            """INSERT INTO conversations (
              id, provider, sessionId, projectName, startTime, endTime, messageCount,
              keyFiles, keyCommands, keyTools, inferredTaskTitle, lastAssistantMessage,
              fullText, indexedAt, fileModifiedAt, summary, summaryTitle, summaryModel,
              workingDirectory
            ) VALUES (?, 'Codex', ?, 'OpenBurnBar', ?, ?, 2, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'gpt-5.5', ?)""",
            (
                source_id,
                session_id,
                timestamp,
                timestamp,
                json.dumps(["apps/linux-desktop/src/surfaces/activity/ActivitySurface.tsx"]),
                json.dumps(["openburnbar-cli activity history"]),
                json.dumps(["OpenBurnBar CLI", "AT-SPI"]),
                title,
                f"P-17 {marker} handoff complete.",
                body,
                timestamp,
                timestamp,
                summary,
                title,
                str(home),
            ),
        )
        for provider in ("Codex", "Claude Code"):
            ambiguous_source = f"{provider}:{ambiguous_session_id}"
            connection.execute(
                """INSERT INTO conversations (
                  id, provider, sessionId, projectName, startTime, endTime, messageCount,
                  keyFiles, keyCommands, keyTools, inferredTaskTitle, lastAssistantMessage,
                  fullText, indexedAt, fileModifiedAt, summary, summaryTitle, summaryModel,
                  workingDirectory
                ) VALUES (?, ?, ?, 'OpenBurnBar', ?, ?, 1, '[]', '[]', '[]',
                  'Ambiguous identity guard', 'Do not resume a bare ambiguous identity.',
                  'Ambiguous source guard.', ?, ?, 'Ambiguous guard',
                  'Ambiguous identity guard', 'fixture-model', ?)""",
                (
                    ambiguous_source,
                    provider,
                    ambiguous_session_id,
                    timestamp,
                    timestamp,
                    timestamp,
                    timestamp,
                    str(home),
                ),
            )
        connection.execute(
            """INSERT INTO search_documents (
              id, sourceKind, sourceID, sourceVersionID, provider, projectName, title,
              bodyPreview, sourceUpdatedAt, indexedAt, createdAt, updatedAt
            ) VALUES (?, 'conversation', ?, 'p17-v1', 'Codex', 'OpenBurnBar', ?, ?, ?, ?, ?, ?)""",
            (document_id, source_id, title, body, timestamp, timestamp, timestamp, timestamp),
        )
        connection.execute(
            """INSERT INTO search_chunks (
              id, documentID, sourceKind, sourceID, sourceVersionID, ordinal,
              startOffset, endOffset, sectionPath, text, createdAt, updatedAt, ftsRowid
            ) VALUES (?, ?, 'conversation', ?, 'p17-v1', 0, 0, ?, 'transcript', ?, ?, ?, 1)""",
            (chunk_id, document_id, source_id, len(body), body, timestamp, timestamp),
        )
        connection.execute(
            """INSERT INTO search_chunks_fts (
              rowid, chunkID, documentID, title, chunkText, projectName, provider
            ) VALUES (1, ?, ?, ?, ?, 'OpenBurnBar', 'Codex')""",
            (chunk_id, document_id, title, body),
        )
        connection.commit()
    finally:
        connection.close()
    database.chmod(0o600)

    foundation_seconds = datetime.now(UTC).timestamp() - 978_307_200
    record = {
        "idempotencyKey": f"p17-{session_id}",
        "event": {
            "providerID": "codex",
            "modelID": "gpt-5.5",
            "inputTokens": 321,
            "outputTokens": 123,
            "cacheCreationTokens": 0,
            "cacheReadTokens": 45,
            "reasoningTokens": 67,
            "cost": 0.0123,
            "recordedAt": foundation_seconds,
            "sessionID": session_id,
            "projectName": title,
            "confidence": "exact",
        },
    }
    usage.write_text(json.dumps(record, separators=(",", ":")) + "\n", encoding="utf-8")
    usage.chmod(0o600)

    session_dir = home / ".codex" / "sessions" / "2026" / "07" / "20"
    session_dir.mkdir(parents=True, mode=0o700)
    session_file = session_dir / f"rollout-2026-07-20T00-00-00-{session_id}.jsonl"
    session_file.write_text(
        json.dumps({"type": "session_meta", "payload": {"id": session_id}}) + "\n", encoding="utf-8"
    )
    session_file.chmod(0o600)
    print(
        json.dumps(
            {
                "schemaVersion": 1,
                "producer": "openburnbar-p17-database-seed-v1",
                "database": str(database),
                "usageLedger": str(usage),
                "sessionFile": str(session_file),
                "sourceID": source_id,
                "providerSessionID": session_id,
                "ambiguousSessionID": ambiguous_session_id,
                "marker": marker,
                "title": title,
                "body": body,
                "createdAt": timestamp,
            },
            separators=(",", ":"),
        )
    )


if __name__ == "__main__":
    main()
