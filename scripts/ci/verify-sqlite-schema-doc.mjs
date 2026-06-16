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

console.log(`SQLite schema doc covers ${required.size} migration/source tables.`);
