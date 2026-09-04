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
-- Schema hash: d79ec74ff49f28842ecd60c81f8a73217df8fa5a1cf6c3e83e97ec83f672b6e4

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
  traceId         TEXT,                                   -- distributed trace ID (v41+)
  billingKind     TEXT    NOT NULL DEFAULT 'unknown',     -- "api" | "subscription" | "unknown" (v60+)
  originatorKind  TEXT,                                   -- STARTED BY kind: user_local | user_remote | flame | wand | mission | hermes_bot | hermes_cron | external | unknown (v62+)
  originatorRef   TEXT                                    -- STARTED BY primary ref: decisionID / missionGroupID / missionID / botName / bodyID (v62+)
);

CREATE INDEX token_usage_sync_pending_idx ON token_usage(syncStatus) WHERE syncStatus = 'pending';
CREATE INDEX token_usage_provider_time_idx ON token_usage(provider, timestamp DESC);
CREATE INDEX token_usage_provider_model_time_idx ON token_usage(provider, model, timestamp DESC);
CREATE INDEX token_usage_provider_id_time_idx ON token_usage(providerID, timestamp DESC);
CREATE INDEX token_usage_session_idx ON token_usage(sessionId);
CREATE INDEX token_usage_execution_source_time_idx ON token_usage(executionSourceID, startTime);
CREATE INDEX token_usage_timestamp_idx ON token_usage(timestamp DESC);
CREATE INDEX token_usage_billing_kind_time_idx ON token_usage(billingKind, startTime);
CREATE INDEX token_usage_originator_time_idx ON token_usage(originatorKind, startTime);
CREATE INDEX token_usage_start_time_idx ON token_usage(startTime);   -- War Room Command Board window scan (v64+)

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
  updated_at      TEXT NOT NULL,
  source_kind     TEXT NOT NULL DEFAULT 'chat' -- v61: 'chat' | 'safari_ask' | 'agent_session'
);

CREATE INDEX memory_extraction_jobs_status_idx ON memory_extraction_jobs(status, not_before);
CREATE INDEX memory_extraction_jobs_lease_idx ON memory_extraction_jobs(status, lease_expires_at);

-- v61 usage-memory substrate (OpenBurnBarDatabase+UsageMemoryMigrations.swift).
-- Stage-0 candidate spool: payload_json is sealed inside the SQLCipher DB
-- (same at-rest posture as memory_body_snapshots.snapshot_json); id is
-- content-derived sha256(source_ref|content_hash) so re-mining is idempotent.
CREATE TABLE memory_usage_candidates (
  id              TEXT NOT NULL PRIMARY KEY,
  source_kind     TEXT NOT NULL,             -- 'safari_ask' | 'agent_session'
  source_ref      TEXT NOT NULL,             -- 'safari-ask:<observationId>' | 'codex:<threadId>'
  thread_logical_id TEXT NOT NULL,
  payload_json    TEXT NOT NULL,
  content_hash    TEXT NOT NULL,
  simhash         INTEGER NOT NULL,          -- 64-bit SimHash for repetition/near-dup pre-check
  salience_hint   REAL NOT NULL,
  status          TEXT NOT NULL DEFAULT 'pending', -- pending|batched|extracted|dropped|expired
  batch_job_id    TEXT,
  created_at      TEXT NOT NULL,
  updated_at      TEXT NOT NULL
);

CREATE INDEX memory_usage_candidates_status_idx ON memory_usage_candidates(status, salience_hint, created_at);
CREATE INDEX memory_usage_candidates_simhash_idx ON memory_usage_candidates(source_kind, simhash);

-- Salience sidecar (consolidation owns corroboration/source trust; daemon
-- recall owns hit reinforcement). A sidecar, not
-- an ALTER on agent_memories, so the mirrored agent_memories DDL stays
-- byte-identical across app/daemon/python/doc copies.
CREATE TABLE memory_salience (
  memory_id          TEXT NOT NULL PRIMARY KEY,
  salience           REAL NOT NULL,
  hit_count          INTEGER NOT NULL DEFAULT 0,
  last_reinforced_at TEXT,
  corroboration      INTEGER NOT NULL DEFAULT 1,
  source_trust       REAL NOT NULL,
  computed_at        TEXT NOT NULL,
  updated_at         TEXT NOT NULL
);

-- Typed consolidation edges. tags_json on agent_memories keeps extraction
-- keywords/tags; links need indexed traversal for contradiction/promote passes.
CREATE TABLE memory_links (
  id             TEXT NOT NULL PRIMARY KEY,
  from_memory_id TEXT NOT NULL,
  to_memory_id   TEXT NOT NULL,
  link_kind      TEXT NOT NULL, -- near_duplicate|contradicts|supports|promoted_from
  score          REAL NOT NULL,
  created_by     TEXT NOT NULL, -- 'stage2'|'consolidation'
  created_at     TEXT NOT NULL
);

CREATE INDEX memory_links_from_idx ON memory_links(from_memory_id, link_kind);
CREATE INDEX memory_links_to_idx ON memory_links(to_memory_id, link_kind);

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

-- Daemon review holding area inside the SQLCipher database. Quarantined and
-- rejected bodies stay out of project_memory_snapshots until explicitly
-- approved, so the default project-memory surface cannot expose them.
CREATE TABLE memory_quarantine_bodies (
  memory_id  TEXT NOT NULL PRIMARY KEY,
  project_id TEXT NOT NULL,
  body       TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE INDEX memory_quarantine_bodies_project_idx ON memory_quarantine_bodies(project_id);

-- Approved bodies for memories the Memory MCP engine mirrors. The engine store is
-- canonical; this is the shared-database copy blind sync seals and uploads, so it
-- carries the engine's own 128-bit id (the daemon's id is derived from
-- projectID:bodyHash and differs between a member's devices). A forget empties the
-- body but keeps the id, so the sealed cloud copy stays addressable for deletion.
CREATE TABLE agent_memory_bodies (
  memory_id        TEXT NOT NULL PRIMARY KEY,
  project_id       TEXT NOT NULL,
  engine_memory_id TEXT NOT NULL,
  body             TEXT NOT NULL,
  body_hash        TEXT NOT NULL,
  created_at       TEXT NOT NULL,
  updated_at       TEXT NOT NULL
);

CREATE UNIQUE INDEX agent_memory_bodies_engine_idx ON agent_memory_bodies(engine_memory_id);

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

-- ── AI Inbox (v58+) ──────────────────────────────────────────────────────────
-- AI Inbox tables (migration v58_ai_inbox). The canonical DDL lives in
-- AgentLens/Services/DataStore/OpenBurnBarDatabase+MigrationV58.swift and is
-- kept byte-identical to the daemon's BurnBarAIInboxSchema; the daemon also
-- creates these tables with IF NOT EXISTS on open, so either side can run
-- first (AIInboxSchemaParityTests enforces the parity).
-- Write ownership: the daemon writes ai_inbox_items, ai_inbox_runs, and
-- ai_inbox_state; the app writes ai_inbox_item_state only.
-- All timestamps are ISO-8601 strings with fractional seconds
-- (AIInboxTimestampCodec), so string comparisons in SQL order correctly.
-- Cloud mirror: AIInboxSyncService seals ai_inbox_items into Firestore and
-- syncs ai_inbox_item_state bidirectionally, with updated_at as the conflict
-- resolver.

CREATE TABLE IF NOT EXISTS ai_inbox_items (
    id TEXT PRIMARY KEY,
    fingerprint TEXT NOT NULL,
    kind TEXT NOT NULL,
    priority INTEGER NOT NULL,
    state TEXT NOT NULL DEFAULT 'new',
    title TEXT NOT NULL,
    summary_md TEXT NOT NULL,
    payload_json TEXT NOT NULL,
    project_id TEXT,
    project_name TEXT,
    occurrence_count INTEGER NOT NULL DEFAULT 1,
    first_seen_at TEXT NOT NULL,
    last_seen_at TEXT NOT NULL,
    resolved_at TEXT,
    resolution_note TEXT,
    tick_id TEXT NOT NULL,
    model_provenance TEXT NOT NULL DEFAULT 'local-rules'
);

CREATE UNIQUE INDEX IF NOT EXISTS ai_inbox_items_open_fingerprint_idx
    ON ai_inbox_items(fingerprint) WHERE state IN ('new', 'updated');
CREATE INDEX IF NOT EXISTS ai_inbox_items_state_seen_idx
    ON ai_inbox_items(state, last_seen_at DESC);
CREATE INDEX IF NOT EXISTS ai_inbox_items_project_idx
    ON ai_inbox_items(project_id);

CREATE TABLE IF NOT EXISTS ai_inbox_runs (
    tick_id TEXT PRIMARY KEY,
    started_at TEXT NOT NULL,
    finished_at TEXT,
    gate_result TEXT NOT NULL,
    gate_signature TEXT NOT NULL,
    egress_mode TEXT NOT NULL,
    llm_calls INTEGER NOT NULL DEFAULT 0,
    input_tokens INTEGER NOT NULL DEFAULT 0,
    output_tokens INTEGER NOT NULL DEFAULT 0,
    cost_usd REAL NOT NULL DEFAULT 0,
    items_new INTEGER NOT NULL DEFAULT 0,
    items_updated INTEGER NOT NULL DEFAULT 0,
    items_resolved INTEGER NOT NULL DEFAULT 0,
    error TEXT
);

CREATE INDEX IF NOT EXISTS ai_inbox_runs_started_idx
    ON ai_inbox_runs(started_at DESC);

CREATE TABLE IF NOT EXISTS ai_inbox_state (
    key TEXT PRIMARY KEY,
    value_json TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS ai_inbox_item_state (
    item_id TEXT PRIMARY KEY,
    read_at TEXT,
    archived_at TEXT,
    snoozed_until TEXT,
    feedback TEXT,
    updated_at TEXT NOT NULL
);

-- ── Founder Lens (v59+) ──────────────────────────────────────────────────────
-- Founder Lens tables (migration v59_founder_lens): fingerprint-keyed reply
-- threads, the Founder Plan Ledger, and the app→daemon approved-memory export.
-- The canonical DDL lives in
-- AgentLens/Services/DataStore/OpenBurnBarDatabase+MigrationV59.swift and is
-- kept byte-identical to the daemon's BurnBarAIInboxSchema.founderLensStatements
-- (AIInboxSchemaParityTests enforces the parity; the daemon also creates these
-- tables with IF NOT EXISTS on open).
-- Write ownership: the daemon writes every table below; all mutations arrive
-- through human-confirmed RPCs (daemon.inbox.reply, daemon.inbox.plans.*,
-- daemon.inbox.memory.export). The app never writes these tables directly.
-- Threads are keyed by item FINGERPRINT (condition identity), not item id, so
-- a conversation survives item resolve/reopen churn.

CREATE TABLE IF NOT EXISTS ai_inbox_threads (
    fingerprint TEXT PRIMARY KEY,
    item_id TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    turn_count INTEGER NOT NULL DEFAULT 0,
    total_cost_usd REAL NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS ai_inbox_thread_messages (
    id TEXT PRIMARY KEY,
    fingerprint TEXT NOT NULL,
    role TEXT NOT NULL,
    body_md TEXT NOT NULL,
    plan_candidates_json TEXT,
    model_provenance TEXT,
    cost_usd REAL NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS ai_inbox_thread_messages_thread_idx
    ON ai_inbox_thread_messages(fingerprint, created_at);

CREATE TABLE IF NOT EXISTS ai_inbox_plans (
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    horizon TEXT NOT NULL,
    pack TEXT NOT NULL,
    status TEXT NOT NULL,
    summary_md TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    origin_fingerprint TEXT,
    memory_id TEXT,
    pensieve_vector_id TEXT,
    grade_avg REAL,
    metrics_json TEXT
);

CREATE INDEX IF NOT EXISTS ai_inbox_plans_status_idx
    ON ai_inbox_plans(status, updated_at DESC);

CREATE TABLE IF NOT EXISTS ai_inbox_plan_steps (
    id TEXT PRIMARY KEY,
    plan_id TEXT NOT NULL,
    parent_step_id TEXT,
    ordinal INTEGER NOT NULL,
    title TEXT NOT NULL,
    body_md TEXT NOT NULL,
    status TEXT NOT NULL,
    next_move_md TEXT,
    evidence_ids_json TEXT,
    mission_id TEXT,
    followup_id TEXT,
    inbox_fingerprint TEXT,
    grade INTEGER,
    grade_note_md TEXT,
    graded_at TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    completed_at TEXT
);

CREATE INDEX IF NOT EXISTS ai_inbox_plan_steps_plan_idx
    ON ai_inbox_plan_steps(plan_id, ordinal);

CREATE TABLE IF NOT EXISTS ai_inbox_plan_events (
    id TEXT PRIMARY KEY,
    plan_id TEXT NOT NULL,
    step_id TEXT,
    event TEXT NOT NULL,
    detail_json TEXT,
    created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS ai_inbox_plan_events_plan_idx
    ON ai_inbox_plan_events(plan_id, created_at);

CREATE TABLE IF NOT EXISTS ai_inbox_memory_export (
    memory_id TEXT PRIMARY KEY,
    provenance TEXT NOT NULL,
    snippet_md TEXT NOT NULL,
    approved_at TEXT NOT NULL,
    exported_at TEXT NOT NULL
);

-- War Room W6 (the rhythm): recurring work the fleet performs without being
-- asked each time. The cadence is decomposed rather than stored as a blob so a
-- row stays readable in a SQL client and a partial cadence is detectable.
-- targetBodyId NULL means "let the Flame choose at fire time".
CREATE TABLE IF NOT EXISTS standing_orders (
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    instruction TEXT NOT NULL,
    cadenceKind TEXT NOT NULL,
    cadenceMinutes INTEGER,
    cadenceHour INTEGER,
    cadenceMinute INTEGER,
    cadenceWeekday INTEGER,
    targetBodyId TEXT,
    requiredCapabilities TEXT NOT NULL DEFAULT '',
    isEnabled BOOLEAN NOT NULL DEFAULT 1,
    lastFiredAt DATETIME,
    createdAt DATETIME NOT NULL,
    updatedAt DATETIME NOT NULL
);

CREATE INDEX IF NOT EXISTS standing_orders_enabled_fired_idx
    ON standing_orders(isEnabled, lastFiredAt);
