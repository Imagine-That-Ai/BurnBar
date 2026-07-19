#!/usr/bin/env node
/**
 * Swift ↔ Windows ↔ Linux migrator parity ratchet.
 *
 * The GRDB migrator in OpenBurnBarCore/Sources/OpenBurnBarData is the schema
 * source of truth (docs/SCHEMA_SQLITE.sql is a known-stale doc — never trust
 * it). Two other surfaces hand-mirror that schema and have historically
 * drifted silently:
 *
 *   1. The AgentLens app migrator (AgentLens/Services/DataStore) — a split
 *      copy of the same migration set.
 *   2. The Windows port (windows/storage/OpenBurnBar.Storage) — a hand-written
 *      endpoint schema (SchemaStatements) plus a windows-migration-journal
 *      whose AppliedMigrationIdentifiers must replay the Swift migrator's
 *      ordered identifier list exactly.
 *   3. The Linux port — runs the Swift kernel directly, but pins the schema
 *      through OpenBurnBarDataLinuxTests + the linux-swift-test-manifest and
 *      the committed DB byte-compat vector.
 *
 * This script mechanically extracts, from source text alone (no DB, no build):
 *   - the ordered migration identifiers (registration order),
 *   - the resulting schema surface: tables + columns, indexes, triggers, and
 *     FTS5 virtual-table config (columns, tokenize, content, content_rowid —
 *     the external-content "ftsRowid" wiring),
 * and asserts the mirrors match — or that every divergence is explicitly
 * annotated in the committed baseline (budgets/migrator-parity-baseline.json).
 *
 * Hard failures (never baseline-able):
 *   - identifier list drift between any two surfaces (order-sensitive),
 *   - Windows CurrentMigrationCount / CurrentMigrationEndpoint inconsistency,
 *   - Linux test pin / manifest / byte-compat vector drift.
 *
 * Baseline-able divergences (annotated, exact-set matched both ways so the
 * baseline can never rot): schema-surface deltas between the Swift endpoint
 * and a mirror (missing/extra tables, column-set deltas, index/trigger/FTS
 * config deltas).
 *
 * Usage:
 *   node scripts/check-migrator-parity.mjs [--repo-root <path>] [--update-baseline]
 */

import { readFileSync, writeFileSync, existsSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join, resolve } from "node:path";

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

export const BASELINE_PATH = "budgets/migrator-parity-baseline.json";

export const SURFACES = {
  swiftCanon: {
    label: "OpenBurnBarData (canonical Swift migrator)",
    dir: "OpenBurnBarCore/Sources/OpenBurnBarData",
    assembly: "OpenBurnBarDatabase.swift",
  },
  agentLens: {
    label: "AgentLens app migrator (split copy)",
    dir: "AgentLens/Services/DataStore",
    assembly: "OpenBurnBarDatabase.swift",
  },
  windows: {
    label: "Windows port (OpenBurnBar.Storage)",
    provisioning: "windows/storage/OpenBurnBar.Storage/WindowsSqlCipherProvisioning.cs",
    metadata: "windows/storage/OpenBurnBar.Storage/WindowsSqlCipherProvisioning.Metadata.cs",
  },
  linux: {
    label: "Linux port pins",
    dataLinuxTests: "OpenBurnBarCore/Tests/OpenBurnBarDataTests/OpenBurnBarDataLinuxTests.swift",
    manifest: "scripts/linux-port/linux-swift-test-manifest.json",
    compatVector: "AgentLensTests/Fixtures/DBByteCompat/openburnbar-db-compat-vector.json",
  },
};

// SQLite-internal / migrator-bookkeeping objects that are not part of the
// application schema surface.
const BOOKKEEPING_TABLES = new Set(["grdb_migrations"]);

const CONSTRAINT_KEYWORDS = new Set([
  "PRIMARY",
  "FOREIGN",
  "UNIQUE",
  "CHECK",
  "CONSTRAINT",
]);

// ---------------------------------------------------------------------------
// Generic text helpers
// ---------------------------------------------------------------------------

/** Find the matching close delimiter, starting at the index of `open`. */
export function matchDelimiter(text, openIndex, open = "(", close = ")") {
  let depth = 0;
  let inString = null;
  let inLineComment = false;
  let inBlockComment = false;
  for (let i = openIndex; i < text.length; i += 1) {
    const ch = text[i];
    const next = text[i + 1];
    if (inLineComment) {
      if (ch === "\n") inLineComment = false;
      continue;
    }
    if (inBlockComment) {
      if (ch === "*" && next === "/") {
        inBlockComment = false;
        i += 1;
      }
      continue;
    }
    if (inString) {
      if (ch === "\\") {
        i += 1;
      } else if (ch === inString) {
        inString = null;
      }
      continue;
    }
    if ((ch === "/" && next === "/") || (ch === "-" && next === "-")) {
      inLineComment = true;
      i += 1;
      continue;
    }
    if (ch === "/" && next === "*") {
      inBlockComment = true;
      i += 1;
      continue;
    }
    if (ch === "'" || ch === '"') {
      inString = ch;
      continue;
    }
    if (ch === open) depth += 1;
    else if (ch === close) {
      depth -= 1;
      if (depth === 0) return i;
    }
  }
  return -1;
}

/** Split a parenthesized body on top-level commas. */
export function splitTopLevel(body) {
  const parts = [];
  let depth = 0;
  let start = 0;
  let inString = null;
  for (let i = 0; i < body.length; i += 1) {
    const ch = body[i];
    if (inString) {
      if (ch === "\\") i += 1;
      else if (ch === inString) inString = null;
      continue;
    }
    if (ch === "'" || ch === '"') {
      inString = ch;
      continue;
    }
    if (ch === "(") depth += 1;
    else if (ch === ")") depth -= 1;
    else if (ch === "," && depth === 0) {
      parts.push(body.slice(start, i));
      start = i + 1;
    }
  }
  parts.push(body.slice(start));
  return parts.map((p) => p.trim()).filter((p) => p.length > 0);
}

// ---------------------------------------------------------------------------
// Schema-state model
// ---------------------------------------------------------------------------

export function emptySchemaState() {
  return {
    tables: new Map(), // name -> Set(columns)
    virtualTables: new Map(), // name -> { columns: [], options: {} }
    indexes: new Map(), // name -> { table, unique }
    triggers: new Map(), // name -> { table }
  };
}

function dropObject(state, kind, name) {
  if (kind === "TABLE") {
    state.tables.delete(name);
    state.virtualTables.delete(name);
    // SQLite drops dependent indexes/triggers with the table.
    for (const [idx, meta] of [...state.indexes]) {
      if (meta.table === name) state.indexes.delete(idx);
    }
    for (const [trg, meta] of [...state.triggers]) {
      if (meta.table === name) state.triggers.delete(trg);
    }
  } else if (kind === "INDEX") {
    state.indexes.delete(name);
  } else if (kind === "TRIGGER") {
    state.triggers.delete(name);
  }
}

function renameTable(state, from, to) {
  if (state.tables.has(from)) {
    state.tables.set(to, state.tables.get(from));
    state.tables.delete(from);
  }
  if (state.virtualTables.has(from)) {
    state.virtualTables.set(to, state.virtualTables.get(from));
    state.virtualTables.delete(from);
  }
  for (const meta of state.indexes.values()) {
    if (meta.table === from) meta.table = to;
  }
  for (const meta of state.triggers.values()) {
    if (meta.table === from) meta.table = to;
  }
}

// ---------------------------------------------------------------------------
// SQL DDL parsing (shared by the Swift raw-SQL and the Windows C# statements)
// ---------------------------------------------------------------------------

function parseCreateTableColumns(parenBody) {
  const columns = [];
  for (const entry of splitTopLevel(parenBody)) {
    const m = entry.match(/^["'[]?([A-Za-z_][A-Za-z0-9_]*)/);
    if (!m) continue;
    if (CONSTRAINT_KEYWORDS.has(m[1].toUpperCase())) continue;
    columns.push(m[1]);
  }
  return columns;
}

export function parseFTS5Config(parenBody) {
  const columns = [];
  const options = {};
  for (const entry of splitTopLevel(parenBody)) {
    const optionMatch = entry.match(/^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/s);
    if (optionMatch) {
      options[optionMatch[1]] = optionMatch[2]
        .trim()
        .replace(/^['"]|['"]$/g, "");
      continue;
    }
    const colMatch = entry.match(/^["']?([A-Za-z_][A-Za-z0-9_]*)["']?(\s+UNINDEXED)?$/i);
    if (colMatch) {
      columns.push(colMatch[2] ? `${colMatch[1]} UNINDEXED` : colMatch[1]);
    }
  }
  return { columns, options };
}

/**
 * Apply every DDL statement found inside `text` (which may be Swift source
 * with embedded SQL literals, or raw SQL) to the schema state, in positional
 * order together with any GRDB DSL events supplied by the caller.
 */
export function collectSQLEvents(text) {
  const events = [];
  const push = (index, apply) => events.push({ index, apply });

  const createTableRe =
    /\bCREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?["'[]?([A-Za-z_][A-Za-z0-9_]*)["'\]]?\s*\(/gi;
  for (const m of text.matchAll(createTableRe)) {
    const open = m.index + m[0].length - 1;
    const closeIdx = matchDelimiter(text, open);
    if (closeIdx === -1) continue;
    const body = text.slice(open + 1, closeIdx);
    const name = m[1];
    push(m.index, (state) => {
      if (!state.tables.has(name)) {
        state.tables.set(name, new Set(parseCreateTableColumns(body)));
      }
    });
  }

  const createVirtualRe =
    /\bCREATE\s+VIRTUAL\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?["'[]?([A-Za-z_][A-Za-z0-9_]*)["'\]]?\s+USING\s+([A-Za-z0-9_]+)\s*\(/gi;
  for (const m of text.matchAll(createVirtualRe)) {
    const open = m.index + m[0].length - 1;
    const closeIdx = matchDelimiter(text, open);
    if (closeIdx === -1) continue;
    const body = text.slice(open + 1, closeIdx);
    const name = m[1];
    const module = m[2].toLowerCase();
    push(m.index, (state) => {
      if (!state.virtualTables.has(name)) {
        state.virtualTables.set(name, { module, ...parseFTS5Config(body) });
      }
    });
  }

  const createIndexRe =
    /\bCREATE\s+(UNIQUE\s+)?INDEX\s+(?:IF\s+NOT\s+EXISTS\s+)?["'[]?([A-Za-z_][A-Za-z0-9_]*)["'\]]?\s+ON\s+["'[]?([A-Za-z_][A-Za-z0-9_]*)/gi;
  for (const m of text.matchAll(createIndexRe)) {
    const [, uniqueKw, name, table] = m;
    push(m.index, (state) => {
      state.indexes.set(name, { table, unique: Boolean(uniqueKw) });
    });
  }

  const createTriggerRe =
    /\bCREATE\s+TRIGGER\s+(?:IF\s+NOT\s+EXISTS\s+)?["'[]?([A-Za-z_][A-Za-z0-9_]*)["'\]]?\s+(?:BEFORE|AFTER|INSTEAD\s+OF)?\s*(?:INSERT|UPDATE|DELETE)[\s\S]{0,120}?\bON\s+["'[]?([A-Za-z_][A-Za-z0-9_]*)/gi;
  for (const m of text.matchAll(createTriggerRe)) {
    const [, name, table] = m;
    push(m.index, (state) => {
      state.triggers.set(name, { table });
    });
  }

  const dropRe =
    /\bDROP\s+(TABLE|INDEX|TRIGGER)\s+(?:IF\s+EXISTS\s+)?["'[]?([A-Za-z_][A-Za-z0-9_]*)/gi;
  for (const m of text.matchAll(dropRe)) {
    const [, kind, name] = m;
    push(m.index, (state) => dropObject(state, kind.toUpperCase(), name));
  }

  const renameRe =
    /\bALTER\s+TABLE\s+["'[]?([A-Za-z_][A-Za-z0-9_]*)["'\]]?\s+RENAME\s+TO\s+["'[]?([A-Za-z_][A-Za-z0-9_]*)/gi;
  for (const m of text.matchAll(renameRe)) {
    const [, from, to] = m;
    push(m.index, (state) => renameTable(state, from, to));
  }

  const addColumnRe =
    /\bALTER\s+TABLE\s+["'[]?([A-Za-z_][A-Za-z0-9_]*)["'\]]?\s+ADD\s+COLUMN\s+["'[]?([A-Za-z_][A-Za-z0-9_]*)/gi;
  for (const m of text.matchAll(addColumnRe)) {
    const [, table, column] = m;
    push(m.index, (state) => {
      state.tables.get(table)?.add(column);
    });
  }

  return events;
}

// ---------------------------------------------------------------------------
// GRDB Swift DSL parsing
// ---------------------------------------------------------------------------

/**
 * True when the method chain starting at `startIndex` (a `t.column(…)` /
 * `t.add(column:…)` call) includes `.indexed()` before the next `t.` statement
 * or the end of the block.
 */
function chainHasIndexed(block, startIndex) {
  const rest = block.slice(startIndex + 2); // skip past "t." so the search below finds the NEXT statement
  const next = rest.search(/\bt\.[A-Za-z]/);
  const chain = next === -1 ? rest : rest.slice(0, next);
  return /\.indexed\(\)/.test(chain);
}

function collectSwiftDSLEvents(text) {
  const events = [];
  const push = (index, apply) => events.push({ index, apply });

  // db.create(table: "name") { t in ... }
  const createTableRe = /\bcreate\(\s*table:\s*"([^"]+)"[^)]*\)\s*\{/g;
  for (const m of text.matchAll(createTableRe)) {
    const braceOpen = m.index + m[0].length - 1;
    const braceClose = matchDelimiter(text, braceOpen, "{", "}");
    if (braceClose === -1) continue;
    const block = text.slice(braceOpen, braceClose);
    const name = m[1];
    const columns = [];
    const autoIndexes = [];
    for (const cm of block.matchAll(
      /\bt\.(?:column|autoIncrementedPrimaryKey)\(\s*"([^"]+)"/g,
    )) {
      columns.push(cm[1]);
      if (chainHasIndexed(block, cm.index)) {
        autoIndexes.push(cm[1]);
      }
    }
    // GRDB `t.primaryKey("id", .type)` single-column form defines a column.
    for (const pk of block.matchAll(/\bt\.primaryKey\(\s*"([^"]+)"/g)) {
      columns.push(pk[1]);
    }
    push(m.index, (state) => {
      if (!state.tables.has(name)) {
        state.tables.set(name, new Set(columns));
        // GRDB `.indexed()` auto-creates `<table>_on_<column>` indexes
        // (Vendor/GRDB-SQLCipher ColumnDefinition.swift).
        for (const col of autoIndexes) {
          state.indexes.set(`${name}_on_${col}`, { table: name, unique: false });
        }
      }
    });
  }

  // db.alter(table: "name") { t in t.add(column: "x", ...) / t.rename / t.drop }
  const alterTableRe = /\balter\(\s*table:\s*"([^"]+)"\s*\)\s*\{/g;
  for (const m of text.matchAll(alterTableRe)) {
    const braceOpen = m.index + m[0].length - 1;
    const braceClose = matchDelimiter(text, braceOpen, "{", "}");
    if (braceClose === -1) continue;
    const block = text.slice(braceOpen, braceClose);
    const name = m[1];
    const addMatches = [...block.matchAll(/\bt\.add\(\s*column:\s*"([^"]+)"/g)];
    const adds = addMatches.map((x) => x[1]);
    const addAutoIndexes = addMatches
      .filter((x) => chainHasIndexed(block, x.index))
      .map((x) => x[1]);
    const drops = [...block.matchAll(/\bt\.drop\(\s*column:\s*"([^"]+)"/g)].map(
      (x) => x[1],
    );
    const renames = [
      ...block.matchAll(/\bt\.rename\(\s*column:\s*"([^"]+)",\s*to:\s*"([^"]+)"/g),
    ].map((x) => [x[1], x[2]]);
    push(m.index, (state) => {
      const cols = state.tables.get(name);
      if (!cols) return;
      for (const c of adds) cols.add(c);
      for (const c of addAutoIndexes) {
        state.indexes.set(`${name}_on_${c}`, { table: name, unique: false });
      }
      for (const c of drops) cols.delete(c);
      for (const [from, to] of renames) {
        if (cols.delete(from)) cols.add(to);
      }
    });
  }

  // db.create(index: "name", on: "table", columns: [...], unique: true)
  const createIndexRe =
    /\bcreate\(\s*index:\s*"([^"]+)"\s*,\s*on:\s*"([^"]+)"([\s\S]{0,240}?)\)/g;
  for (const m of text.matchAll(createIndexRe)) {
    const [, name, table, rest] = m;
    const unique = /\bunique:\s*true\b/.test(rest);
    push(m.index, (state) => {
      state.indexes.set(name, { table, unique });
    });
  }

  // db.drop(table: "name") / db.drop(index: "name")
  const dropRe = /\bdrop\(\s*(table|index):\s*"([^"]+)"\s*\)/g;
  for (const m of text.matchAll(dropRe)) {
    const [, kind, name] = m;
    push(m.index, (state) => dropObject(state, kind.toUpperCase(), name));
  }

  // db.rename(table: "a", to: "b")
  const renameRe = /\brename\(\s*table:\s*"([^"]+)",\s*to:\s*"([^"]+)"\s*\)/g;
  for (const m of text.matchAll(renameRe)) {
    const [, from, to] = m;
    push(m.index, (state) => renameTable(state, from, to));
  }

  return events;
}

// ---------------------------------------------------------------------------
// Swift migrator extraction
// ---------------------------------------------------------------------------

/** Parse the assembly file's `static var migrator` for register-call order. */
export function parseRegisterOrder(assemblyText, assemblyPath) {
  const varMatch = assemblyText.match(
    /static\s+var\s+migrator\s*:\s*DatabaseMigrator\s*\{/,
  );
  if (!varMatch) {
    throw new Error(`No 'static var migrator' found in ${assemblyPath}`);
  }
  const open = varMatch.index + varMatch[0].length - 1;
  const close = matchDelimiter(assemblyText, open, "{", "}");
  const body = assemblyText.slice(open, close === -1 ? undefined : close);
  const calls = [
    ...body.matchAll(/\b(register[A-Za-z0-9_]*)\(\s*on:\s*&migrator\s*\)/g),
  ].map((m) => m[1]);
  if (calls.length === 0) {
    throw new Error(`No register*(on: &migrator) calls found in ${assemblyPath}`);
  }
  return calls;
}

/**
 * Extract ordered migrations from a Swift migrator directory.
 * Returns { identifiers: string[], migrations: [{id, body}] }.
 */
export function extractSwiftMigrations(repoRoot, surface, readdir) {
  const dir = join(repoRoot, surface.dir);
  const assemblyPath = join(dir, surface.assembly);
  const assemblyText = readFileSync(assemblyPath, "utf8");
  const registerOrder = parseRegisterOrder(assemblyText, assemblyPath);

  const files = readdir(dir).filter((f) => f.endsWith(".swift"));
  const fileTexts = new Map(
    files.map((f) => [f, readFileSync(join(dir, f), "utf8")]),
  );

  const migrations = [];
  for (const fn of registerOrder) {
    const defRe = new RegExp(`\\bfunc\\s+${fn}\\s*\\(`);
    const hostEntry = [...fileTexts].find(([, text]) => defRe.test(text));
    if (!hostEntry) {
      throw new Error(
        `Register function ${fn} (called from ${assemblyPath}) not found in ${surface.dir}`,
      );
    }
    const [, text] = hostEntry;
    const regs = [...text.matchAll(/registerMigration\(\s*"([^"]+)"/g)];
    for (let i = 0; i < regs.length; i += 1) {
      const start = regs[i].index;
      const end = i + 1 < regs.length ? regs[i + 1].index : text.length;
      migrations.push({ id: regs[i][1], body: text.slice(start, end) });
    }
  }

  const identifiers = migrations.map((m) => m.id);
  const dupes = identifiers.filter((id, i) => identifiers.indexOf(id) !== i);
  if (dupes.length > 0) {
    throw new Error(
      `Duplicate migration identifiers in ${surface.dir}: ${dupes.join(", ")}`,
    );
  }
  return { identifiers, migrations };
}

/** Replay extracted migrations into an endpoint schema state. */
export function replayMigrations(migrations) {
  const state = emptySchemaState();
  for (const migration of migrations) {
    const events = [
      ...collectSQLEvents(migration.body),
      ...collectSwiftDSLEvents(migration.body),
    ].sort((a, b) => a.index - b.index);
    for (const event of events) event.apply(state);
  }
  return state;
}

// ---------------------------------------------------------------------------
// Windows extraction
// ---------------------------------------------------------------------------

/** Parse a C# string-array literal body into its string entries. */
export function parseCSharpStringArray(text, arrayName) {
  const declRe = new RegExp(
    `${arrayName}\\s*=\\s*(?:new\\s*\\[\\]\\s*)?\\{`,
    "s",
  );
  const decl = text.match(declRe);
  if (!decl) throw new Error(`C# array ${arrayName} not found`);
  const open = decl.index + decl[0].length - 1;
  // Manual scan: raw strings ("""..."""), regular strings, identifiers.
  const entries = [];
  let i = open + 1;
  let depth = 1;
  while (i < text.length && depth > 0) {
    const ch = text[i];
    if (text.startsWith("//", i)) {
      const nl = text.indexOf("\n", i);
      i = nl === -1 ? text.length : nl + 1;
      continue;
    }
    if (text.startsWith("/*", i)) {
      const end = text.indexOf("*/", i + 2);
      i = end === -1 ? text.length : end + 2;
      continue;
    }
    if (text.startsWith('"""', i)) {
      const end = text.indexOf('"""', i + 3);
      if (end === -1) throw new Error(`Unterminated raw string in ${arrayName}`);
      entries.push({ kind: "string", value: text.slice(i + 3, end) });
      i = end + 3;
      continue;
    }
    if (ch === '"') {
      let j = i + 1;
      let out = "";
      while (j < text.length && text[j] !== '"') {
        if (text[j] === "\\") {
          out += text[j + 1];
          j += 2;
        } else {
          out += text[j];
          j += 1;
        }
      }
      entries.push({ kind: "string", value: out });
      i = j + 1;
      continue;
    }
    if (ch === "{") depth += 1;
    else if (ch === "}") depth -= 1;
    else if (/[A-Za-z_]/.test(ch)) {
      let j = i;
      while (j < text.length && /[A-Za-z0-9_.]/.test(text[j])) j += 1;
      const word = text.slice(i, j);
      // Bare identifiers inside the array literal are symbol references.
      if (word !== "new") entries.push({ kind: "symbol", value: word });
      i = j;
      continue;
    }
    i += 1;
  }
  return entries;
}

export function extractWindows(repoRoot, surface) {
  const provisioningText = readFileSync(
    join(repoRoot, surface.provisioning),
    "utf8",
  );
  const metadataText = readFileSync(join(repoRoot, surface.metadata), "utf8");

  const endpointMatch = provisioningText.match(
    /CurrentMigrationEndpoint\s*=\s*"([^"]+)"/,
  );
  const countMatch = provisioningText.match(
    /CurrentMigrationCount\s*=\s*(\d+)/,
  );
  if (!endpointMatch || !countMatch) {
    throw new Error(
      `CurrentMigrationEndpoint/CurrentMigrationCount not found in ${surface.provisioning}`,
    );
  }
  const endpoint = endpointMatch[1];
  const count = Number(countMatch[1]);

  const identifierEntries = parseCSharpStringArray(
    metadataText,
    "AppliedMigrationIdentifiers",
  );
  const identifiers = identifierEntries.map((e) =>
    e.kind === "symbol" && e.value === "CurrentMigrationEndpoint"
      ? endpoint
      : e.value,
  );

  const schemaEntries = parseCSharpStringArray(
    provisioningText,
    "SchemaStatements",
  );
  const state = emptySchemaState();
  for (const entry of schemaEntries) {
    if (entry.kind !== "string") continue;
    const events = collectSQLEvents(entry.value).sort(
      (a, b) => a.index - b.index,
    );
    for (const event of events) event.apply(state);
  }
  for (const bookkeeping of BOOKKEEPING_TABLES) state.tables.delete(bookkeeping);

  return { identifiers, endpoint, count, state };
}

// ---------------------------------------------------------------------------
// Linux extraction
// ---------------------------------------------------------------------------

export function extractLinux(repoRoot, surface) {
  const testText = readFileSync(join(repoRoot, surface.dataLinuxTests), "utf8");
  const pins = [
    ...testText.matchAll(
      /migrations(?:\.last|Rows\(\)\.last)?[^\n]*?"(v\d+[a-z]?_[A-Za-z0-9_]+)"/g,
    ),
  ].map((m) => m[1]);
  const lastPins = [
    ...testText.matchAll(/\.last,\s*"(v\d+[a-z]?_[A-Za-z0-9_]+)"/g),
  ].map((m) => m[1]);

  const manifest = JSON.parse(
    readFileSync(join(repoRoot, surface.manifest), "utf8"),
  );
  const linuxDataSuite = (manifest.suites ?? []).find(
    (s) =>
      s.target === "OpenBurnBarDataTests" &&
      String(s.filter ?? "").includes("OpenBurnBarDataLinuxTests"),
  );

  const vector = JSON.parse(
    readFileSync(join(repoRoot, surface.compatVector), "utf8"),
  );

  return {
    pinnedIdentifiers: pins,
    pinnedLastIdentifiers: lastPins,
    linuxDataSuite,
    vectorMigrationCount: vector.migrationCount,
    vectorSchemaEndpoint: vector.schemaEndpoint,
  };
}

// ---------------------------------------------------------------------------
// Comparison
// ---------------------------------------------------------------------------

function fmtList(list, max = 8) {
  return list.length > max
    ? `${list.slice(0, max).join(", ")}, … (+${list.length - max})`
    : list.join(", ");
}

/** Compare two schema states; returns divergence records {key, detail}. */
export function diffSchemaSurfaces(prefix, canonical, mirror) {
  const divergences = [];
  const add = (key, detail) => divergences.push({ key, detail });

  const canonTables = new Set([
    ...canonical.tables.keys(),
    ...canonical.virtualTables.keys(),
  ]);
  const mirrorTables = new Set([
    ...mirror.tables.keys(),
    ...mirror.virtualTables.keys(),
  ]);

  for (const t of [...canonTables].sort()) {
    if (!mirrorTables.has(t)) add(`${prefix}:missing-table:${t}`, `mirror lacks table ${t}`);
  }
  for (const t of [...mirrorTables].sort()) {
    if (!canonTables.has(t)) add(`${prefix}:extra-table:${t}`, `mirror declares table ${t} absent from the Swift endpoint schema`);
  }

  for (const [name, canonCols] of [...canonical.tables].sort()) {
    const mirrorCols = mirror.tables.get(name);
    if (!mirrorCols) continue;
    const missing = [...canonCols].filter((c) => !mirrorCols.has(c)).sort();
    const extra = [...mirrorCols].filter((c) => !canonCols.has(c)).sort();
    if (missing.length > 0) {
      add(
        `${prefix}:table:${name}:missing-columns:${missing.join(",")}`,
        `mirror table ${name} lacks columns: ${fmtList(missing)}`,
      );
    }
    if (extra.length > 0) {
      add(
        `${prefix}:table:${name}:extra-columns:${extra.join(",")}`,
        `mirror table ${name} has extra columns: ${fmtList(extra)}`,
      );
    }
  }

  for (const [name, canonCfg] of [...canonical.virtualTables].sort()) {
    const mirrorCfg = mirror.virtualTables.get(name);
    if (!mirrorCfg) continue;
    const canonSig = JSON.stringify({
      module: canonCfg.module,
      columns: canonCfg.columns,
      options: canonCfg.options,
    });
    const mirrorSig = JSON.stringify({
      module: mirrorCfg.module,
      columns: mirrorCfg.columns,
      options: mirrorCfg.options,
    });
    if (canonSig !== mirrorSig) {
      add(
        `${prefix}:fts-config:${name}`,
        `FTS config differs for ${name}: canonical ${canonSig} vs mirror ${mirrorSig}`,
      );
    }
  }

  const canonIdx = canonical.indexes;
  const mirrorIdx = mirror.indexes;
  for (const [name, meta] of [...canonIdx].sort()) {
    if (!mirrorTables.has(meta.table)) continue; // index on an unported table
    const mirrorMeta = mirrorIdx.get(name);
    if (!mirrorMeta) {
      add(`${prefix}:missing-index:${name}`, `mirror lacks index ${name} on ${meta.table}`);
    } else if (mirrorMeta.table !== meta.table || mirrorMeta.unique !== meta.unique) {
      add(
        `${prefix}:index-config:${name}`,
        `index ${name} differs (table/unique): canonical ${JSON.stringify(meta)} vs mirror ${JSON.stringify(mirrorMeta)}`,
      );
    }
  }
  for (const [name, meta] of [...mirrorIdx].sort()) {
    if (!canonIdx.has(name)) {
      add(`${prefix}:extra-index:${name}`, `mirror declares index ${name} on ${meta.table} absent from the Swift endpoint schema`);
    }
  }

  for (const [name, meta] of [...canonical.triggers].sort()) {
    if (!mirrorTables.has(meta.table)) continue;
    if (!mirror.triggers.has(name)) {
      add(`${prefix}:missing-trigger:${name}`, `mirror lacks trigger ${name} on ${meta.table}`);
    }
  }
  for (const [name, meta] of [...mirror.triggers].sort()) {
    if (!canonical.triggers.has(name)) {
      add(`${prefix}:extra-trigger:${name}`, `mirror declares trigger ${name} on ${meta.table} absent from the Swift endpoint schema`);
    }
  }

  return divergences;
}

// ---------------------------------------------------------------------------
// Baseline
// ---------------------------------------------------------------------------

export function loadBaseline(repoRoot) {
  const path = join(repoRoot, BASELINE_PATH);
  if (!existsSync(path)) return { divergences: [] };
  return JSON.parse(readFileSync(path, "utf8"));
}

export function reconcileBaseline(computed, baseline) {
  const errors = [];
  const baselineByKey = new Map(
    (baseline.divergences ?? []).map((d) => [d.key, d]),
  );
  for (const d of computed) {
    const entry = baselineByKey.get(d.key);
    if (!entry) {
      errors.push(
        `NEW divergence not in baseline: ${d.key}\n    ${d.detail}\n    → either fix the mirror or annotate it in ${BASELINE_PATH} (run with --update-baseline, then write a real reason).`,
      );
    } else if (!entry.reason || /^TODO/i.test(entry.reason.trim())) {
      errors.push(
        `Baseline divergence ${d.key} has no real annotation (reason: ${JSON.stringify(entry.reason ?? "")}).`,
      );
    }
  }
  const computedKeys = new Set(computed.map((d) => d.key));
  for (const key of baselineByKey.keys()) {
    if (!computedKeys.has(key)) {
      errors.push(
        `STALE baseline entry (divergence no longer exists — delete it): ${key}`,
      );
    }
  }
  return errors;
}

// ---------------------------------------------------------------------------
// Main check
// ---------------------------------------------------------------------------

export function runParityCheck(
  repoRoot,
  { readdir, minMigrations = 55, minTables = 30 } = {},
) {
  const listDir = readdir ?? ((d) => defaultReaddir(d));
  const hardErrors = [];
  const computedDivergences = [];

  const canon = extractSwiftMigrations(repoRoot, SURFACES.swiftCanon, listDir);
  const canonState = replayMigrations(canon.migrations);
  const canonLast = canon.identifiers[canon.identifiers.length - 1];

  // Sanity floor: the extractor must keep seeing the real migrator. If these
  // move or shrink dramatically the script must scream, not silently pass.
  if (canon.identifiers.length < minMigrations) {
    hardErrors.push(
      `Canonical migrator extraction found only ${canon.identifiers.length} migrations (expected >= ${minMigrations}) — extractor or migrator layout drifted.`,
    );
  }
  if (canonState.tables.size + canonState.virtualTables.size < minTables) {
    hardErrors.push(
      `Canonical schema surface extraction found only ${canonState.tables.size + canonState.virtualTables.size} tables — extractor drifted.`,
    );
  }
  // The ftsRowid contract: since v6_fts_standalone_triggers the canonical
  // conversations_fts is a STANDALONE FTS5 table (no content= option) whose
  // rowid mirrors conversations.rowid via the conversations_ai/ad/au triggers.
  // External-content config here would reintroduce the FTS5 plain-DELETE
  // corruption pitfall; losing the triggers would silently stop indexing.
  const conversationsFTS = canonState.virtualTables.get("conversations_fts");
  if (!conversationsFTS) {
    hardErrors.push(
      "Canonical schema surface lost conversations_fts — FTS5 extraction drifted.",
    );
  } else {
    if (conversationsFTS.options.content !== undefined) {
      hardErrors.push(
        `conversations_fts is no longer standalone (content=${conversationsFTS.options.content}) — the ftsRowid contract expects a standalone FTS mirrored by triggers keyed on conversations.rowid.`,
      );
    }
    for (const trigger of ["conversations_ai", "conversations_ad", "conversations_au"]) {
      if (canonState.triggers.get(trigger)?.table !== "conversations") {
        hardErrors.push(
          `Canonical schema lost the ${trigger} trigger on conversations — the rowid-mirror (ftsRowid) wiring for conversations_fts is broken.`,
        );
      }
    }
  }

  // 1. AgentLens split-copy migrator.
  const agentLens = extractSwiftMigrations(
    repoRoot,
    SURFACES.agentLens,
    listDir,
  );
  if (JSON.stringify(agentLens.identifiers) !== JSON.stringify(canon.identifiers)) {
    hardErrors.push(
      `AgentLens migrator identifier list diverged from OpenBurnBarData.\n    canonical: ${fmtList(canon.identifiers, 60)}\n    agentLens: ${fmtList(agentLens.identifiers, 60)}`,
    );
  }
  const agentLensState = replayMigrations(agentLens.migrations);
  computedDivergences.push(
    ...diffSchemaSurfaces("agentlens", canonState, agentLensState),
  );

  // 2. Windows port.
  const windows = extractWindows(repoRoot, SURFACES.windows);
  if (JSON.stringify(windows.identifiers) !== JSON.stringify(canon.identifiers)) {
    const missing = canon.identifiers.filter((i) => !windows.identifiers.includes(i));
    const extra = windows.identifiers.filter((i) => !canon.identifiers.includes(i));
    hardErrors.push(
      `Windows AppliedMigrationIdentifiers diverged from the Swift migrator (order-sensitive).\n    missing on Windows: [${fmtList(missing, 60)}]\n    extra on Windows: [${fmtList(extra, 60)}]\n    (if both empty, the ORDER differs)`,
    );
  }
  if (windows.count !== canon.identifiers.length) {
    hardErrors.push(
      `Windows CurrentMigrationCount (${windows.count}) != Swift migration count (${canon.identifiers.length}).`,
    );
  }
  if (windows.endpoint !== canonLast) {
    hardErrors.push(
      `Windows CurrentMigrationEndpoint (${windows.endpoint}) != Swift last migration (${canonLast}).`,
    );
  }
  computedDivergences.push(
    ...diffSchemaSurfaces("windows", canonState, windows.state),
  );

  // 3. Linux port pins.
  const linux = extractLinux(repoRoot, SURFACES.linux);
  if (!linux.pinnedLastIdentifiers.includes(canonLast)) {
    hardErrors.push(
      `Linux OpenBurnBarDataLinuxTests does not pin the current migrator endpoint ${canonLast} as the LAST migration (pinned: ${fmtList(linux.pinnedLastIdentifiers)}). Update the test pin together with the migration.`,
    );
  }
  if (!linux.linuxDataSuite) {
    hardErrors.push(
      "linux-swift-test-manifest.json no longer runs OpenBurnBarDataTests.OpenBurnBarDataLinuxTests — the Linux schema pin would silently stop executing.",
    );
  }
  if (linux.vectorMigrationCount !== canon.identifiers.length) {
    hardErrors.push(
      `DB byte-compat vector migrationCount (${linux.vectorMigrationCount}) != Swift migration count (${canon.identifiers.length}) — regenerate the vector (see AgentLensTests/Fixtures/DBByteCompat).`,
    );
  }
  if (linux.vectorSchemaEndpoint !== canonLast) {
    hardErrors.push(
      `DB byte-compat vector schemaEndpoint (${linux.vectorSchemaEndpoint}) != Swift last migration (${canonLast}) — regenerate the vector.`,
    );
  }

  return {
    canon,
    canonState,
    hardErrors,
    computedDivergences,
  };
}

function defaultReaddir(dir) {
  return readdirSync(dir);
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

export function main(argv, { cwd } = {}) {
  const args = argv.slice(2);
  let repoRoot = cwd ?? process.cwd();
  const rootFlag = args.indexOf("--repo-root");
  if (rootFlag !== -1) repoRoot = resolve(args[rootFlag + 1]);
  const update = args.includes("--update-baseline");

  const { canon, hardErrors, computedDivergences } = runParityCheck(repoRoot);
  const baseline = loadBaseline(repoRoot);

  if (update) {
    const previous = new Map(
      (baseline.divergences ?? []).map((d) => [d.key, d]),
    );
    const next = {
      description:
        "Annotated, exact-set schema divergence baseline for scripts/check-migrator-parity.mjs. Every entry is an intentional, explained divergence between the canonical Swift migrator endpoint schema (OpenBurnBarCore/Sources/OpenBurnBarData) and a mirror surface. New divergences and stale entries both fail CI; keep reasons real.",
      updateCommand: "node scripts/check-migrator-parity.mjs --update-baseline",
      migrationEndpoint: canon.identifiers[canon.identifiers.length - 1],
      migrationCount: canon.identifiers.length,
      divergences: computedDivergences.map((d) => ({
        key: d.key,
        reason: previous.get(d.key)?.reason ?? `TODO: annotate divergence (${d.detail})`,
      })),
    };
    writeFileSync(
      join(repoRoot, BASELINE_PATH),
      `${JSON.stringify(next, null, 2)}\n`,
    );
    console.log(
      `Baseline written: ${BASELINE_PATH} (${computedDivergences.length} divergences). Fill in any TODO reasons before committing.`,
    );
  }

  const baselineErrors = update
    ? []
    : reconcileBaseline(computedDivergences, baseline);

  const errors = [...hardErrors, ...baselineErrors];
  if (errors.length > 0) {
    console.error("✗ Migrator parity check FAILED:\n");
    for (const e of errors) console.error(`  - ${e}\n`);
    return 1;
  }

  console.log(
    `✓ Migrator parity holds: ${canon.identifiers.length} migrations (endpoint ${canon.identifiers[canon.identifiers.length - 1]}), ` +
      `${computedDivergences.length} annotated divergences, Windows journal + endpoint schema, AgentLens copy, and Linux pins all consistent.`,
  );
  return 0;
}

const isDirectRun =
  process.argv[1] &&
  resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isDirectRun) {
  process.exit(main(process.argv));
}
