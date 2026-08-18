#!/usr/bin/env node
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const scriptDir = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(scriptDir, "../..");

const sourceSpecs = [
  {
    // v41+ migrations moved to a split extension file (wave-4 decomposition of
    // OpenBurnBarDatabase.swift); the v50 marker anchors the PCM-era schema scan.
    path: "AgentLens/Services/DataStore/OpenBurnBarDatabase+MigrationsV41toV51.swift",
    startMarker: 'migrator.registerMigration("v50_project_code_memory_schema")',
  },
  {
    path: "AgentLens/Services/DataStore/OpenBurnBarDatabase+MigrationV56.swift",
  },
  {
    path: "AgentLens/Services/DataStore/OpenBurnBarDatabase+MigrationV58.swift",
  },
  {
    path: "AgentLens/Services/DataStore/OpenBurnBarDatabase+MigrationV59.swift",
  },
  {
    path: "AgentLens/Services/DataStore/OpenBurnBarDatabase+MemoryMigrations.swift",
  },
  {
    path: "AgentLens/Services/DataStore/OpenBurnBarDatabase+UsageMemoryMigrations.swift",
  },
  {
    path: "AgentLens/Services/DataStore/OpenBurnBarDatabase+StandingOrderMigrations.swift",
  },
  {
    path: "AgentLens/Services/DataStore/OpenBurnBarDatabase+CommandBoardIndexMigration.swift",
  },
  {
    path: "OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/ProjectCodeMemory/BurnBarProjectCodeMemoryStore+Database.swift",
  },
  {
    path: "tools/openburnbar-mcp/project_code_memory.py",
  },
];

// Migration files that exist as byte-identical AgentLens/OpenBurnBarData
// pairs. A drifted pair means the app and the Data package migrate to
// different schemas — fail loudly here rather than at runtime.
const mirrorPairs = [
  [
    "AgentLens/Services/DataStore/OpenBurnBarDatabase+MemoryMigrations.swift",
    "OpenBurnBarCore/Sources/OpenBurnBarData/OpenBurnBarDatabase+MemoryMigrations.swift",
  ],
  [
    "AgentLens/Services/DataStore/OpenBurnBarDatabase+UsageMemoryMigrations.swift",
    "OpenBurnBarCore/Sources/OpenBurnBarData/OpenBurnBarDatabase+UsageMemoryMigrations.swift",
  ],
  [
    "AgentLens/Services/DataStore/OpenBurnBarDatabase+StandingOrderMigrations.swift",
    "OpenBurnBarCore/Sources/OpenBurnBarData/OpenBurnBarDatabase+StandingOrderMigrations.swift",
  ],
  [
    "AgentLens/Services/DataStore/OpenBurnBarDatabase+CommandBoardIndexMigration.swift",
    "OpenBurnBarCore/Sources/OpenBurnBarData/OpenBurnBarDatabase+CommandBoardIndexMigration.swift",
  ],
];

function readRepoFile(path) {
  return readFileSync(resolve(repoRoot, path), "utf8");
}

function verifyMirrorPairs() {
  for (const [left, right] of mirrorPairs) {
    if (readRepoFile(left) !== readRepoFile(right)) {
      console.error(
        `Migration mirror pair drifted (must stay byte-identical):\n  ${left}\n  ${right}`,
      );
      process.exit(1);
    }
  }
}

function addMatches(set, text, regex) {
  for (const match of text.matchAll(regex)) {
    set.add(match[1]);
  }
}

function sourceText(spec) {
  const text = readRepoFile(spec.path);
  if (!spec.startMarker) {
    return text;
  }
  const markerIndex = text.indexOf(spec.startMarker);
  if (markerIndex === -1) {
    console.error(`${spec.path} is missing schema verifier marker: ${spec.startMarker}`);
    process.exit(1);
  }
  return text.slice(markerIndex);
}

function documentedTables() {
  const tables = new Set();
  addMatches(
    tables,
    readRepoFile("docs/SCHEMA_SQLITE.sql"),
    /\bCREATE\s+(?:VIRTUAL\s+)?TABLE(?:\s+IF\s+NOT\s+EXISTS)?\s+([A-Za-z_][A-Za-z0-9_]*)/gi,
  );
  return tables;
}

function schemaDocText() {
  return readRepoFile("docs/SCHEMA_SQLITE.sql");
}

function sourceTables() {
  const tables = new Set();
  for (const spec of sourceSpecs) {
    const text = sourceText(spec);
    const tableOperationPattern =
      /\bcreate\(table:\s*"([^"]+)"|\bCREATE\s+(?:VIRTUAL\s+)?TABLE(?:\s+IF\s+NOT\s+EXISTS)?\s+([A-Za-z_][A-Za-z0-9_]*)|\bDROP\s+TABLE(?:\s+IF\s+EXISTS)?\s+([A-Za-z_][A-Za-z0-9_]*)/gi;
    for (const match of text.matchAll(tableOperationPattern)) {
      const createdTable = match[1] ?? match[2];
      const droppedTable = match[3];
      if (createdTable) {
        tables.add(createdTable);
      }
      if (droppedTable) {
        tables.delete(droppedTable);
      }
    }
  }
  return tables;
}

function assertIncludes(haystack, needle, message) {
  if (!haystack.includes(needle)) {
    console.error(message);
    process.exit(1);
  }
}

const docs = documentedTables();
const required = sourceTables();
const missing = [...required].filter((table) => !docs.has(table)).sort();

if (missing.length > 0) {
  console.error("docs/SCHEMA_SQLITE.sql is missing table definitions from migration sources:");
  for (const table of missing) {
    console.error(`- ${table}`);
  }
  console.error("\nUpdate docs/SCHEMA_SQLITE.sql alongside the migration/schema source.");
  process.exit(1);
}

const schema = schemaDocText();
for (const forbidden of ["agent_memories_fts"]) {
  if (schema.includes(forbidden)) {
    console.error(
      `docs/SCHEMA_SQLITE.sql must not document ${forbidden}; memory bodies stay behind sealed references only.`,
    );
    process.exit(1);
  }
}

const pcmColumnChecks = {
  agent_memories: [
    "body_ref",
    "body_redacted",
    "valid_from",
    "superseded_by",
    "source_kind",
    "review_status",
    "user_id",
    "agent_id",
    "run_id",
    "app_id",
  ],
  memory_provenance: ["memory_id", "thread_logical_id", "xdevice_hmac", "citation_state"],
  memory_extraction_jobs: ["idempotency_key", "scope_json", "not_before"],
  memory_embedding_refs: ["memory_id", "embedding_version_id", "dimension", "vector", "norm"],
  memory_body_snapshots: ["memory_id", "body_ref", "snapshot_json", "body_hash", "source_kind"],
  memory_source_tombstones: ["thread_logical_id", "message_id", "content_hash", "reason"],
  memory_audit: ["seq", "prev_hash", "hash"],
  pcm_projects: ["project_id", "identity_version", "identity_fingerprint", "primary_path"],
  pcm_project_aliases: ["project_id", "alias_path", "path_hash", "first_seen_at", "last_seen_at"],
  code_artifacts: ["project_id", "file_path", "blob_sha", "content_hash", "byte_count", "mtime"],
  pcm_file_manifest: ["project_id", "file_path", "artifact_id", "content_hash", "ignored_reason", "secret_labels_json"],
  code_symbols: ["range_json", "confidence_tier", "tier_evidence_json"],
  code_references: ["from_artifact_id", "to_symbol_id", "blob_sha", "confidence_tier"],
  code_call_edges: ["caller_symbol_id", "callee_symbol_id", "confidence_tier"],
  code_diagnostics_cache: ["payload_json", "blob_sha", "cached_at"],
  code_index_checkpoints: ["storage_byte_count", "storage_budget_bytes", "vacuumed_at"],
};
for (const [table, columns] of Object.entries(pcmColumnChecks)) {
  for (const column of columns) {
    assertIncludes(
      schema,
      column,
      `docs/SCHEMA_SQLITE.sql is missing Project Code Memory column ${table}.${column}`,
    );
  }
}

for (const indexName of [
  "agent_memories_project_idx",
  "agent_memories_chat_scope_idx",
  "memory_provenance_memory_idx",
  "memory_provenance_hmac_idx",
  "memory_provenance_msg_idx",
  "memory_extraction_jobs_status_idx",
  "memory_embedding_refs_version_idx",
  "memory_body_snapshots_source_idx",
  "memory_source_tombstones_thread_idx",
  "pcm_projects_fingerprint_idx",
  "pcm_project_aliases_path_hash_idx",
  "pcm_project_aliases_project_idx",
  "code_artifacts_project_path_idx",
  "pcm_file_manifest_project_path_idx",
  "code_symbols_project_name_idx",
  "code_references_symbol_idx",
  "code_call_edges_project_idx",
]) {
  assertIncludes(
    schema,
    indexName,
    `docs/SCHEMA_SQLITE.sql is missing Project Code Memory index ${indexName}`,
  );
}

verifyMirrorPairs();

console.log(`SQLite schema doc covers ${required.size} migration/source tables and Project Code Memory columns/indexes.`);
