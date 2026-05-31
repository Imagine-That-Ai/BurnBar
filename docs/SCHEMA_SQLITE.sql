-- OpenBurnBar SQLite Schema (GRDB)
-- Generated from migration history in OpenBurnBarDatabaseMigrationTests.swift
-- and the OpenBurnBarDatabase migration definitions.
--
-- This file is the canonical reference for the local SQLite database schema.
-- It is maintained alongside the Swift migration code. When adding a new
-- migration, update both the Swift GRDB migration AND this file.
--
-- Primary database: ~/Library/Application Support/OpenBurnBar/openburnbar.sqlite
-- Opened via: DatabaseQueue / DatabasePool (GRDB 6.x)
--
-- For Firestore schema, see: functions/src/types.ts (canonical)
-- For Android models, see: android/app/src/main/java/com/openburnbar/data/models/

PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

-- ── GRDB migrations tracking ──────────────────────────────────────────────────

CREATE TABLE grdb_migrations (
  identifier TEXT NOT NULL PRIMARY KEY
);

-- ── Token Usage (v1+) ────────────────────────────────────────────────────────
-- Records every token usage event parsed from agent session logs.
-- Maps to: UsageEventDoc in functions/src/types.ts
-- Android: com.openburnbar.data.models.TokenUsage

CREATE TABLE token_usage (
  id              TEXT    NOT NULL PRIMARY KEY,           -- UUID
  sessionId       TEXT    NOT NULL,                       -- agent session identifier
  provider        TEXT    NOT NULL,                       -- "Claude Code", "Factory Droid", etc.
  providerID      TEXT    NOT NULL DEFAULT '',            -- provider account ID
  model           TEXT    NOT NULL,                       -- model slug, e.g. "claude-sonnet-4-5"
  inputTokens     INTEGER NOT NULL DEFAULT 0,
  outputTokens    INTEGER NOT NULL DEFAULT 0,
  cacheReadTokens INTEGER NOT NULL DEFAULT 0,             -- prompt cache read tokens (v20+)
  cacheWriteTokens INTEGER NOT NULL DEFAULT 0,            -- prompt cache write tokens (v20+)
  totalTokens     INTEGER NOT NULL DEFAULT 0,             -- inputTokens + outputTokens
  cost            REAL    NOT NULL DEFAULT 0.0,           -- USD cost
  confidence      TEXT    NOT NULL DEFAULT 'estimated',   -- "exact" | "estimated" | "zero"
  timestamp       REAL    NOT NULL,                       -- Unix timestamp (seconds since epoch)
  syncStatus      TEXT    NOT NULL DEFAULT 'pending',     -- "pending" | "synced" | "error"
  syncedAt        REAL,                                   -- Unix timestamp of last sync
  rawLogPath      TEXT,                                   -- original log file path
  sourceFileHash  TEXT,                                   -- SHA-256 of source log file
  projectPath     TEXT,                                   -- working directory at session time
  agentVersion    TEXT,                                   -- agent CLI version
  requestId       TEXT,                                   -- provider-assigned request ID (v38+)
  traceId         TEXT                                    -- distributed trace ID (v41+)
);

CREATE INDEX token_usage_sync_pending_idx ON token_usage(syncStatus) WHERE syncStatus = 'pending';
CREATE INDEX token_usage_provider_time_idx ON token_usage(provider, timestamp DESC);
CREATE INDEX token_usage_provider_model_time_idx ON token_usage(provider, model, timestamp DESC);
CREATE INDEX token_usage_provider_id_time_idx ON token_usage(providerID, timestamp DESC);
CREATE INDEX token_usage_session_idx ON token_usage(sessionId);
CREATE INDEX token_usage_timestamp_idx ON token_usage(timestamp DESC);

-- ── Chat Messages (v10+) ─────────────────────────────────────────────────────
-- Stores local chat history for the Hermes and Local Index chat surfaces.

CREATE TABLE chat_messages (
  id           TEXT NOT NULL PRIMARY KEY,   -- UUID
  threadId     TEXT NOT NULL,               -- chat thread identifier
  role         TEXT NOT NULL,               -- "user" | "assistant" | "system" | "tool"
  content      TEXT NOT NULL,               -- message body (markdown)
  toolName     TEXT,                        -- tool name for tool messages
  toolCallId   TEXT,                        -- tool call correlation ID
  timestamp    REAL NOT NULL,               -- Unix timestamp
  modelUsed    TEXT,                        -- model slug if role = "assistant"
  backend      TEXT,                        -- "hermes" | "local_index" | "cli"
  isStreaming  INTEGER NOT NULL DEFAULT 0,  -- 1 while message is being streamed
  metadata     TEXT                         -- JSON blob for extensible metadata
);

CREATE INDEX chat_messages_thread_time_idx ON chat_messages(threadId, timestamp);
CREATE INDEX chat_messages_timestamp_idx ON chat_messages(timestamp DESC);

-- ── Chat Threads (v11+) ───────────────────────────────────────────────────────

CREATE TABLE chat_threads (
  id          TEXT NOT NULL PRIMARY KEY,
  title       TEXT,
  backend     TEXT NOT NULL DEFAULT 'local_index',
  createdAt   REAL NOT NULL,
  updatedAt   REAL NOT NULL,
  projectPath TEXT,
  sessionId   TEXT                                   -- associated token_usage sessionId
);

CREATE INDEX chat_threads_updated_idx ON chat_threads(updatedAt DESC);

-- ── Source Artifacts (v15+) ──────────────────────────────────────────────────
-- Indexed conversation chunks and skill/agent docs for local search.

CREATE TABLE source_artifacts (
  id           TEXT NOT NULL PRIMARY KEY,  -- UUID
  sourceType   TEXT NOT NULL,              -- "conversation" | "skill_doc" | "agent_doc" | "shared_artifact"
  sourceId     TEXT NOT NULL,              -- session ID, skill name, or artifact path
  chunkIndex   INTEGER NOT NULL DEFAULT 0,
  content      TEXT NOT NULL,
  embedding    BLOB,                       -- float32[] quantized embedding vector (v18+)
  tokenCount   INTEGER,
  timestamp    REAL NOT NULL,
  projectPath  TEXT,
  tags         TEXT                        -- JSON array of string tags
);

CREATE INDEX source_artifacts_source_idx ON source_artifacts(sourceType, sourceId);
CREATE INDEX source_artifacts_timestamp_idx ON source_artifacts(timestamp DESC);

-- Full-text search virtual table over source_artifacts.content
CREATE VIRTUAL TABLE IF NOT EXISTS search_chunks_fts USING fts5(
  content,
  content='source_artifacts',
  content_rowid='rowid'
);

-- ── Provider Accounts Cache (v22+) ───────────────────────────────────────────
-- Local cache of the Firestore provider_accounts collection.

CREATE TABLE provider_accounts_cache (
  accountId     TEXT NOT NULL PRIMARY KEY,
  providerName  TEXT NOT NULL,
  displayName   TEXT,
  quotaType     TEXT NOT NULL DEFAULT 'hosted',   -- "hosted" | "self_hosted"
  monthlyBudget REAL,                             -- USD monthly cap
  cachedAt      REAL NOT NULL
);

-- ── Sync Cursors (v25+) ──────────────────────────────────────────────────────
-- Tracks Firestore sync watermarks to enable incremental reads.

CREATE TABLE sync_cursors (
  collection  TEXT NOT NULL PRIMARY KEY,  -- Firestore collection path
  cursor      TEXT NOT NULL,              -- Firestore snapshot cursor (document path or timestamp)
  syncedAt    REAL NOT NULL
);

-- ── App State (v30+) ─────────────────────────────────────────────────────────
-- Key-value store for persistent app state that doesn't need a full table.

CREATE TABLE app_state (
  key      TEXT NOT NULL PRIMARY KEY,
  value    TEXT NOT NULL,               -- JSON-encoded value
  updatedAt REAL NOT NULL
);
