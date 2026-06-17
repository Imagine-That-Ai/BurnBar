#!/usr/bin/env node
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const scriptDir = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(scriptDir, "../..");

const sourcePaths = [
  "OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/ProjectCodeMemory/BurnBarProjectCodeMemoryStore.swift",
  "tools/openburnbar-mcp/project_code_memory.py",
];

function readRepoFile(path) {
  return readFileSync(resolve(repoRoot, path), "utf8");
}

function addMatches(set, text, regex) {
  for (const match of text.matchAll(regex)) {
    set.add(match[1]);
  }
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
  for (const sourcePath of sourcePaths) {
    const text = readRepoFile(sourcePath);
    addMatches(tables, text, /\bcreate\(table:\s*"([^"]+)"/g);
    addMatches(
      tables,
      text,
      /\bCREATE\s+(?:VIRTUAL\s+)?TABLE(?:\s+IF\s+NOT\s+EXISTS)?\s+([A-Za-z_][A-Za-z0-9_]*)/gi,
    );
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
const pcmColumnChecks = {
  agent_memories: ["body_ref", "body_redacted", "valid_from", "superseded_by"],
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

console.log(`SQLite schema doc covers ${required.size} migration/source tables and Project Code Memory columns/indexes.`);
