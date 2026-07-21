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
-- Schema hash: d7e37392aa12f99869fdec1dd60279352c8661eceed035d7ab511bbd5b132d7d

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
  executionSourceID TEXT  NOT NULL DEFAULT 'unknown',     -- stable runtime/client identity
  executionSourceName TEXT NOT NULL DEFAULT 'Unknown',    -- user-facing runtime/client name
  executionSourceKind TEXT NOT NULL DEFAULT 'unknown',    -- ide | cli | desktop_app | service | automation | unknown
  executionSourceConfidence TEXT NOT NULL DEFAULT 'unknown', -- exact | derived_exact | high_confidence_estimate | low_confidence_estimate | unknown
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
CREATE INDEX token_usage_execution_source_time_idx ON token_usage(executionSourceID, startTime);
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

-- ── Parser Checkpoints (v29+, file manifest v56+) ────────────────────────────
-- The compact provider watermark advances only after successful indexing.
-- Exact per-path identities let bounded scans skip unchanged inputs without
-- storing transcript content in the checkpoint token.

CREATE TABLE parser_checkpoints (
  provider              TEXT     NOT NULL PRIMARY KEY,
  checkpointToken       TEXT     NOT NULL,
  lastProcessedFilePath TEXT,
  lastProcessedAt       DATETIME NOT NULL,
  version               INTEGER  NOT NULL DEFAULT 1
);

CREATE INDEX parser_checkpoints_provider_idx ON parser_checkpoints(provider);

CREATE TABLE parser_checkpoint_files (
  provider           TEXT NOT NULL,
  path               TEXT NOT NULL,
  fileSizeBytes      INTEGER,
  modificationDate  DATETIME,
  creationDate      DATETIME,
  fileSystemNumber  TEXT,
  fileNumber        TEXT,
  PRIMARY KEY (provider, path)
);

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

-- Current search chunk FTS layout (v21+). The indexed payload spans the chunk
-- text plus the document title/provider context so snippet/rank behavior stays
-- aligned with the GRDB migrator.
CREATE VIRTUAL TABLE search_chunks_fts USING fts5(
  chunkID UNINDEXED,
  documentID UNINDEXED,
  title,
  chunkText,
  projectName,
  provider,
  tokenize='porter unicode61'
);

-- ── Local MCP Project Code Memory overlay ───────────────────────────────────
-- Created by the daemon ProjectCodeMemory store, with Python direct helpers kept
-- as compatibility/dev harnesses. These tables are local-only and
-- project-partitioned; hosted code sync is disabled by default until the
-- code-asset threat model passes. Code chunks reuse search_documents/
-- search_chunks/search_chunks_fts. chunk_embeddings may contain deterministic
-- content fingerprints for fixture/dedupe stability, but those fingerprints are
-- not semantic embeddings and must not affect production code-search ranking.
-- code_index_checkpoints.storage_byte_count is an estimated Project Code Memory
-- footprint: source bytes + stored chunk text + an FTS mirror/metadata estimate
-- + persisted vector blobs. It is not just code_artifacts.byte_count. The
-- vacuumed_at column records the last threshold-triggered incremental vacuum
-- after freelist/page metrics crossed the local compaction policy.

CREATE TABLE search_documents (
  id              TEXT NOT NULL PRIMARY KEY,
  sourceKind      TEXT NOT NULL,
  sourceID        TEXT NOT NULL,
  sourceVersionID TEXT NOT NULL DEFAULT '',
  provider        TEXT,
  projectName     TEXT,
  title           TEXT NOT NULL,
  subtitle        TEXT,
  bodyPreview     TEXT,
  sourceUpdatedAt TEXT,
  indexedAt       TEXT NOT NULL,
  contentHash     TEXT,
  createdAt       TEXT NOT NULL,
  updatedAt       TEXT NOT NULL
);

CREATE TABLE search_chunks (
  id                 TEXT NOT NULL PRIMARY KEY,
  documentID         TEXT NOT NULL,
  sourceKind         TEXT NOT NULL,
  sourceID           TEXT NOT NULL,
  sourceVersionID    TEXT NOT NULL DEFAULT '',
  ordinal            INTEGER NOT NULL,
  startOffset        INTEGER NOT NULL,
  endOffset          INTEGER NOT NULL,
  messageStartOffset INTEGER,
  messageEndOffset   INTEGER,
  sectionPath        TEXT,
  text               TEXT NOT NULL,
  contentHash        TEXT,
  createdAt          TEXT NOT NULL,
  updatedAt          TEXT NOT NULL,
  -- Added by v55_search_chunks_fts_rowid (ALTER TABLE appends it last): maps
  -- each chunk to its FTS5 rowid so deletes target the rowid instead of
  -- full-scanning the UNINDEXED (chunkID, documentID) FTS columns.
  ftsRowid           INTEGER
);

-- The current local-search FTS shape is chunk/document oriented:
-- (chunkID, documentID, title, chunkText, projectName, provider). Older app
-- installs may still migrate through the source_artifacts-backed shape above.

CREATE TABLE embedding_models (
  id             TEXT NOT NULL PRIMARY KEY,
  provider       TEXT NOT NULL,
  modelName      TEXT NOT NULL,
  dimensions     INTEGER NOT NULL,
  distanceMetric TEXT NOT NULL,
  createdAt      TEXT NOT NULL,
  updatedAt      TEXT NOT NULL
);

CREATE TABLE embedding_versions (
  id                   TEXT NOT NULL PRIMARY KEY,
  modelID              TEXT NOT NULL,
  versionTag           TEXT NOT NULL,
  chunkerVersion       TEXT NOT NULL,
  normalizationVersion TEXT NOT NULL,
  promptVersion        TEXT NOT NULL,
  isActive             INTEGER NOT NULL,
  createdAt            TEXT NOT NULL,
  updatedAt            TEXT NOT NULL
);

CREATE TABLE chunk_embeddings (
  chunkID            TEXT NOT NULL,
  embeddingVersionID TEXT NOT NULL,
  vectorBlob         BLOB NOT NULL,
  createdAt          TEXT NOT NULL,
  updatedAt          TEXT NOT NULL,
  PRIMARY KEY (chunkID, embeddingVersionID)
);

CREATE TABLE project_memory_snapshots (
  projectSlug             TEXT NOT NULL PRIMARY KEY,
  projectDisplayName      TEXT NOT NULL,
  snapshotJSON            TEXT NOT NULL,
  contentHash             TEXT NOT NULL,
  sourceSessionCount      INTEGER NOT NULL DEFAULT 0,
  sourceConversationCount INTEGER NOT NULL DEFAULT 0,
  generatedAt             TEXT NOT NULL,
  schemaVersion           INTEGER NOT NULL,
  updatedAt               TEXT NOT NULL
);

CREATE INDEX project_memory_snapshots_updated_idx ON project_memory_snapshots(updatedAt);

CREATE TABLE agent_memories (
  id            TEXT NOT NULL PRIMARY KEY,
  project_id    TEXT NOT NULL,
  kind          TEXT NOT NULL,
  scope         TEXT NOT NULL,
  confidence    REAL NOT NULL,
  body_ref      TEXT NOT NULL,
  body_redacted TEXT NOT NULL, -- Sealed body ref; chat bodies live in memory_body_snapshots
  tags_json     TEXT NOT NULL,
  source_path   TEXT,
  valid_from    TEXT NOT NULL,
  valid_to      TEXT,
  superseded_by TEXT,
  created_at    TEXT NOT NULL,
  updated_at    TEXT NOT NULL,
  source_kind   TEXT NOT NULL DEFAULT 'code',
  review_status TEXT NOT NULL DEFAULT 'quarantined',
  user_id       TEXT,
  agent_id      TEXT,
  run_id        TEXT,
  app_id        TEXT
);

CREATE INDEX agent_memories_project_idx ON agent_memories(project_id, scope, updated_at);
CREATE INDEX agent_memories_chat_scope_idx ON agent_memories(source_kind, user_id, agent_id, run_id, app_id, updated_at);

CREATE TABLE memory_provenance (
  id                TEXT NOT NULL PRIMARY KEY,
  memory_id         TEXT NOT NULL,
  source_kind       TEXT NOT NULL,
  thread_logical_id TEXT NOT NULL,
  message_id        TEXT,
  role              TEXT NOT NULL,
  authored_at       TEXT NOT NULL,
  content_hash      TEXT NOT NULL,
  occurrence        INTEGER NOT NULL DEFAULT 0,
  xdevice_hmac      TEXT NOT NULL,
  citation_state    TEXT NOT NULL DEFAULT 'live',
  created_at        TEXT NOT NULL
);

CREATE INDEX memory_provenance_memory_idx ON memory_provenance(memory_id);
CREATE INDEX memory_provenance_hmac_idx ON memory_provenance(xdevice_hmac);
CREATE INDEX memory_provenance_msg_idx ON memory_provenance(message_id);

CREATE TABLE memory_extraction_jobs (
  id              TEXT NOT NULL PRIMARY KEY,
  idempotency_key TEXT NOT NULL UNIQUE,
  thread_id       TEXT NOT NULL,
  thread_logical_id TEXT NOT NULL,
  message_id      TEXT NOT NULL,
  prompt_version  TEXT NOT NULL,
  scope_json      TEXT NOT NULL,
  status          TEXT NOT NULL DEFAULT 'pending',
  attempts        INTEGER NOT NULL DEFAULT 0,
  last_error      TEXT,
  not_before      TEXT,
  lease_expires_at TEXT,
  created_at      TEXT NOT NULL,
  updated_at      TEXT NOT NULL
);

CREATE INDEX memory_extraction_jobs_status_idx ON memory_extraction_jobs(status, not_before);
CREATE INDEX memory_extraction_jobs_lease_idx ON memory_extraction_jobs(status, lease_expires_at);

CREATE TABLE memory_embedding_refs (
  memory_id            TEXT NOT NULL,
  embedding_version_id TEXT NOT NULL,
  dimension            INTEGER NOT NULL,
  vector               BLOB NOT NULL,
  norm                 REAL NOT NULL,
  created_at           TEXT NOT NULL,
  PRIMARY KEY (memory_id, embedding_version_id)
);

CREATE INDEX memory_embedding_refs_version_idx ON memory_embedding_refs(embedding_version_id, dimension);

CREATE TABLE memory_body_snapshots (
  id            TEXT NOT NULL PRIMARY KEY,
  memory_id     TEXT NOT NULL UNIQUE,
  body_ref      TEXT NOT NULL UNIQUE,
  snapshot_json TEXT NOT NULL,
  body_hash     TEXT NOT NULL,
  source_kind   TEXT NOT NULL,
  created_at    TEXT NOT NULL,
  updated_at    TEXT NOT NULL
);

CREATE INDEX memory_body_snapshots_source_idx ON memory_body_snapshots(source_kind, updated_at);

CREATE TABLE memory_source_tombstones (
  id                TEXT NOT NULL PRIMARY KEY,
  user_id           TEXT,
  thread_logical_id TEXT NOT NULL,
  message_id        TEXT,
  content_hash      TEXT,
  reason            TEXT NOT NULL,
  created_at        TEXT NOT NULL,
  replicated_at     TEXT
);

CREATE INDEX memory_source_tombstones_thread_idx ON memory_source_tombstones(thread_logical_id);
CREATE INDEX memory_source_tombstones_pending_idx ON memory_source_tombstones(user_id, replicated_at, created_at);

CREATE TABLE memory_fact_tombstones (
  id               TEXT NOT NULL PRIMARY KEY,
  user_id          TEXT NOT NULL,
  memory_id        TEXT NOT NULL,
  source_refs_json TEXT NOT NULL,
  reason           TEXT NOT NULL,
  created_at       TEXT NOT NULL,
  replicated_at    TEXT
);

CREATE INDEX memory_fact_tombstones_pending_idx ON memory_fact_tombstones(user_id, replicated_at, created_at);

CREATE TABLE memory_audit (
  seq         INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  ts          TEXT NOT NULL,
  actor       TEXT NOT NULL,
  action      TEXT NOT NULL,
  domain      TEXT NOT NULL,
  project_id  TEXT,
  subject_id  TEXT,
  labels_json TEXT NOT NULL,
  prev_hash   TEXT,
  hash        TEXT NOT NULL
);

CREATE TABLE pcm_projects (
  project_id           TEXT NOT NULL PRIMARY KEY,
  identity_version     INTEGER NOT NULL,
  identity_fingerprint TEXT NOT NULL,
  project_name         TEXT NOT NULL,
  primary_path         TEXT NOT NULL,
  created_at           TEXT NOT NULL,
  updated_at           TEXT NOT NULL
);

CREATE UNIQUE INDEX pcm_projects_fingerprint_idx ON pcm_projects(identity_fingerprint);

CREATE TABLE pcm_project_aliases (
  id            TEXT NOT NULL PRIMARY KEY,
  project_id    TEXT NOT NULL REFERENCES pcm_projects(project_id) ON DELETE CASCADE,
  alias_path    TEXT NOT NULL,
  path_hash     TEXT NOT NULL,
  first_seen_at TEXT NOT NULL,
  last_seen_at  TEXT NOT NULL
);

CREATE UNIQUE INDEX pcm_project_aliases_path_hash_idx ON pcm_project_aliases(path_hash);
CREATE INDEX pcm_project_aliases_project_idx ON pcm_project_aliases(project_id);

CREATE TABLE code_artifacts (
  id          TEXT NOT NULL PRIMARY KEY,
  project_id  TEXT NOT NULL,
  file_path   TEXT NOT NULL,
  blob_sha    TEXT NOT NULL,
  content_hash TEXT,
  commit_sha  TEXT,
  lang        TEXT,
  byte_count  INTEGER NOT NULL,
  mtime       REAL NOT NULL,
  indexed_at  TEXT NOT NULL
);

CREATE UNIQUE INDEX code_artifacts_project_path_idx ON code_artifacts(project_id, file_path);

CREATE TABLE pcm_file_manifest (
  id                 TEXT NOT NULL PRIMARY KEY,
  project_id         TEXT NOT NULL,
  file_path          TEXT NOT NULL,
  artifact_id        TEXT,
  blob_sha           TEXT,
  content_hash       TEXT,
  byte_count         INTEGER NOT NULL DEFAULT 0,
  mtime              REAL NOT NULL DEFAULT 0,
  lang               TEXT,
  ignored_reason     TEXT,
  secret_labels_json TEXT NOT NULL DEFAULT '[]',
  parser_tier        TEXT,
  indexed_at         TEXT NOT NULL,
  last_seen_at       TEXT NOT NULL
);

CREATE UNIQUE INDEX pcm_file_manifest_project_path_idx ON pcm_file_manifest(project_id, file_path);

CREATE TABLE code_symbols (
  id              TEXT NOT NULL PRIMARY KEY,
  project_id      TEXT NOT NULL,
  artifact_id     TEXT NOT NULL,
  blob_sha        TEXT NOT NULL,
  name            TEXT NOT NULL,
  kind            TEXT NOT NULL,
  range_json      TEXT NOT NULL,
  confidence_tier TEXT NOT NULL,
  tier_evidence_json TEXT,
  indexed_at      TEXT NOT NULL
);

CREATE INDEX code_symbols_project_name_idx ON code_symbols(project_id, name);

CREATE TABLE code_references (
  id               TEXT NOT NULL PRIMARY KEY,
  project_id       TEXT NOT NULL,
  from_artifact_id TEXT NOT NULL,
  to_symbol_id     TEXT NOT NULL,
  range_json       TEXT NOT NULL,
  blob_sha         TEXT NOT NULL,
  confidence_tier  TEXT NOT NULL,
  indexed_at       TEXT NOT NULL
);

CREATE INDEX code_references_symbol_idx ON code_references(project_id, to_symbol_id);

CREATE TABLE code_call_edges (
  id               TEXT NOT NULL PRIMARY KEY,
  project_id       TEXT NOT NULL,
  caller_symbol_id TEXT NOT NULL,
  callee_symbol_id TEXT NOT NULL,
  confidence_tier  TEXT NOT NULL,
  indexed_at       TEXT NOT NULL
);

CREATE INDEX code_call_edges_project_idx ON code_call_edges(project_id, caller_symbol_id);

CREATE TABLE code_diagnostics_cache (
  id           TEXT NOT NULL PRIMARY KEY,
  project_id   TEXT NOT NULL,
  file_path    TEXT NOT NULL,
  tool         TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  blob_sha     TEXT,
  cached_at    TEXT NOT NULL
);

-- Daemon-owned semantic vectors for code chunks (one row per chunk per embedding
-- generation). `embedding_version` is the §5.9 floor: search compares only the active
-- generation, and a version bump re-embeds on the next index. Vectors are base64 float32.
CREATE TABLE code_chunk_embeddings (
  chunk_id          TEXT NOT NULL,
  project_id        TEXT NOT NULL,
  embedding_version TEXT NOT NULL,
  dimension         INTEGER NOT NULL,
  vector            TEXT NOT NULL,
  PRIMARY KEY (chunk_id, embedding_version)
);
CREATE INDEX code_chunk_embeddings_project_idx ON code_chunk_embeddings(project_id, embedding_version);

CREATE TABLE code_index_checkpoints (
  project_id       TEXT NOT NULL PRIMARY KEY,
  project_root     TEXT NOT NULL,
  last_commit_sha  TEXT,
  indexed_at       TEXT NOT NULL,
  artifact_count   INTEGER NOT NULL,
  chunk_count      INTEGER NOT NULL,
  rejected_count   INTEGER NOT NULL,
  storage_byte_count INTEGER NOT NULL DEFAULT 0,
  storage_budget_bytes INTEGER NOT NULL DEFAULT 0,
  vacuumed_at      TEXT
);

-- ── Provider Accounts (v35+) ────────────────────────────────────────────────

CREATE TABLE provider_accounts (
  id                      TEXT     NOT NULL PRIMARY KEY,
  providerID              TEXT     NOT NULL,
  label                   TEXT     NOT NULL,
  identityHint            TEXT,
  status                  TEXT     NOT NULL,
  credentialKind          TEXT     NOT NULL,
  storageScope            TEXT     NOT NULL,
  redactedLabel           TEXT     NOT NULL,
  sourceDeviceID          TEXT,
  linkedSwitcherProfileID TEXT,
  isDefault               BOOLEAN  NOT NULL DEFAULT 0,
  sortKey                 DOUBLE   NOT NULL DEFAULT 0,
  lastValidatedAt         DATETIME,
  lastRefreshAt           DATETIME,
  lastErrorCode           TEXT,
  schemaVersion           INTEGER  NOT NULL DEFAULT 1,
  createdAt               DATETIME NOT NULL,
  updatedAt               DATETIME NOT NULL
);

CREATE INDEX provider_accounts_provider_sort_idx
  ON provider_accounts(providerID, sortKey, createdAt);
CREATE INDEX provider_accounts_provider_default_idx
  ON provider_accounts(providerID, isDefault);

-- ── Provider Quota Snapshots (v54+) ─────────────────────────────────────────

CREATE TABLE provider_quota_snapshots (
  id           TEXT     NOT NULL PRIMARY KEY,
  providerID   TEXT     NOT NULL,
  providerName TEXT     NOT NULL,
  source       TEXT     NOT NULL,
  sourceID     TEXT     NOT NULL,
  sourceLabel  TEXT     NOT NULL,
  period       TEXT     NOT NULL,
  quotaLimit   REAL,
  used         REAL,
  remaining    REAL,
  resetAt      DATETIME,
  planName     TEXT,
  rawJSON      TEXT     NOT NULL,
  fetchedAt    DATETIME NOT NULL,
  createdAt    DATETIME NOT NULL,
  updatedAt    DATETIME NOT NULL
);

CREATE UNIQUE INDEX provider_quota_snapshots_identity_idx
  ON provider_quota_snapshots(providerID, source, sourceID, period);
CREATE INDEX provider_quota_snapshots_provider_time_idx
  ON provider_quota_snapshots(providerID, fetchedAt);
CREATE INDEX provider_quota_snapshots_reset_idx
  ON provider_quota_snapshots(resetAt);

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
