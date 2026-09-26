#!/usr/bin/env node
// Wave 2.3 schema-doc drift check.
//
// docs/SCHEMA_SQLITE.sql is GENERATED from the live OpenBurnBarData migrator
// (`swift run --package-path OpenBurnBarCore OpenBurnBarSchemaExport`). This
// check — which runs on the ubuntu PR door with node only, no Swift toolchain
// — proves the committed doc still matches the migrator sources by parsing
// BOTH into endpoint schema surfaces and requiring them to be identical:
//
//   1. Canonical surface: every migration v1..head in registration order,
//      replayed from OpenBurnBarCore/Sources/OpenBurnBarData (scans from v1
//      by construction — the same extractor scripts/check-migrator-parity.mjs
//      trusts).
//   2. Doc surface: the DDL statements in docs/SCHEMA_SQLITE.sql.
//
// Any delta is a hard error with NO baseline: regenerate the doc. The check
// also enforces the sealed-body rule (agent_memories_fts must never be
// documented) and requires the doc's schema-hash header to agree with the DB
// byte-compat vector.
//
// Surface granularity is tables/columns/indexes/triggers/FTS-config (names,
// not column types). Byte truth is the generator output itself plus the
// vector hash it carries.

import { readFileSync, readdirSync } from "node:fs";
import { createHash } from "node:crypto";
import { join, dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  SURFACES,
  extractSwiftMigrations,
  replayMigrations,
  emptySchemaState,
  collectSQLEvents,
  diffSchemaSurfaces,
} from "../check-migrator-parity.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(here, "..", "..");

const DOC_PATH = "docs/SCHEMA_SQLITE.sql";
const VECTOR_PATH =
  "AgentLensTests/Fixtures/DBByteCompat/openburnbar-db-compat-vector.json";

// Sealed-body rule: the agent-memories FTS index must never appear in the
// published schema doc (it was dropped in v51a and must stay dropped).
const FORBIDDEN_OBJECTS = ["agent_memories_fts"];

// sqlite_master truth includes FTS5-managed objects the migration sources
// never spell out; strip them from the doc surface before comparing.
const BOOKKEEPING_TABLES = new Set(["grdb_migrations"]);
const FTS_SHADOW_SUFFIXES = ["_data", "_idx", "_content", "_docsize", "_config"];

function fail(message) {
  console.error(`SQLite schema doc drift check FAILED:\n  ${message}`);
  process.exit(1);
}

function parseDocSurface(docText) {
  const state = emptySchemaState();
  const events = collectSQLEvents(docText).sort((a, b) => a.index - b.index);
  for (const event of events) event.apply(state);
  // The doc is endpoint truth: it must not contain endpoint drops/renames.
  // (Any DROP/ALTER in the doc would mean the generator emitted non-endpoint
  // DDL, which is impossible — but assert rather than assume.)
  return state;
}

/**
 * Split the generated doc into its verbatim sqlite_master statements
 * (trimmed, without trailing `;`). Trigger bodies contain `;` at paren depth
 * zero, so triggers scan to their balancing END instead. `--` framing lines
 * are skipped only BETWEEN statements; anything comment-like inside a
 * statement is preserved byte-for-byte. The split is self-validating: the
 * caller rejoins with "\n" and requires the doc's own schema hash, so any
 * splitter bug fails loudly instead of silently comparing the wrong corpus.
 */
export function splitDocStatements(docText) {
  const statements = [];
  let index = 0;

  const skipGap = () => {
    for (;;) {
      while (index < docText.length && /\s/.test(docText[index])) index += 1;
      if (docText.startsWith("--", index)) {
        const end = docText.indexOf("\n", index);
        index = end === -1 ? docText.length : end + 1;
        continue;
      }
      return;
    }
  };

  // [quoteChar | bracket] stack for '...', "...", `...`, [...] literals.
  const scanQuoted = (start) => {
    const open = docText[start];
    const close = open === "[" ? "]" : open;
    let i = start + 1;
    while (i < docText.length) {
      if (docText[i] === close) {
        if ((close === "'" || close === '"') && docText[i + 1] === close) {
          i += 2; // '' / "" escape
          continue;
        }
        return i + 1;
      }
      i += 1;
    }
    return -1;
  };

  const matchWord = (at, word) => {
    const slice = docText.slice(at, at + word.length);
    if (slice.toUpperCase() !== word) return false;
    const before = at === 0 ? "" : docText[at - 1];
    const after = docText[at + word.length] ?? "";
    return !/[A-Za-z0-9_]/.test(before) && !/[A-Za-z0-9_]/.test(after);
  };

  while (true) {
    skipGap();
    if (index >= docText.length) break;
    const start = index;
    const isTrigger =
      matchWord(index, "CREATE") &&
      /\bTRIGGER\b/i.test(docText.slice(index, index + 40).split("(")[0]);
    let end = -1;

    if (isTrigger) {
      // Find BEGIN, then balance BEGIN/CASE..END outside string literals.
      const beginAt = docText.slice(index).search(/\bBEGIN\b/i);
      if (beginAt === -1) {
        throw new Error(`trigger statement has no BEGIN (offset ${index})`);
      }
      let i = index + beginAt + 5;
      let depth = 1;
      while (i < docText.length && depth > 0) {
        const ch = docText[i];
        if (ch === "'" || ch === '"' || ch === "`" || ch === "[") {
          const after = scanQuoted(i);
          if (after === -1) throw new Error(`unterminated literal in trigger (offset ${i})`);
          i = after;
          continue;
        }
        if (matchWord(i, "BEGIN") || matchWord(i, "CASE")) {
          depth += 1;
          i += matchWord(i, "BEGIN") ? 5 : 4;
          continue;
        }
        if (matchWord(i, "END")) {
          depth -= 1;
          i += 3;
          continue;
        }
        i += 1;
      }
      if (depth !== 0) throw new Error(`trigger statement has unbalanced BEGIN/END (offset ${index})`);
      while (i < docText.length && /\s/.test(docText[i])) i += 1;
      if (docText[i] !== ";") throw new Error(`trigger statement has no terminating ; (offset ${index})`);
      end = i + 1;
    } else {
      let depth = 0;
      let i = start;
      while (i < docText.length) {
        const ch = docText[i];
        if (ch === "'" || ch === '"' || ch === "`" || ch === "[") {
          const after = scanQuoted(i);
          if (after === -1) throw new Error(`unterminated literal (offset ${i})`);
          i = after;
          continue;
        }
        if (ch === "(") depth += 1;
        else if (ch === ")") depth -= 1;
        else if (ch === ";" && depth === 0) {
          end = i + 1;
          break;
        }
        i += 1;
      }
      if (end === -1) throw new Error(`statement has no terminating ; (offset ${index})`);
    }

    const statement = docText.slice(start, end - 1).trim();
    if (!statement) throw new Error(`empty statement (offset ${index})`);
    statements.push(statement);
    index = end;
  }
  return statements;
}

function sha256Hex(value) {
  return createHash("sha256").update(value, "utf8").digest("hex");
}

function stripDocOnlyObjects(state) {
  for (const table of BOOKKEEPING_TABLES) state.tables.delete(table);
  for (const virtual of [...state.virtualTables.keys()]) {
    for (const suffix of FTS_SHADOW_SUFFIXES) {
      state.tables.delete(`${virtual}${suffix}`);
    }
  }
}

function checkForbiddenObjects(state) {
  const present = [];
  for (const name of FORBIDDEN_OBJECTS) {
    if (state.tables.has(name) || state.virtualTables.has(name)) {
      present.push(`table ${name}`);
    }
    for (const [index, meta] of state.indexes) {
      if (index === name || meta.table === name) present.push(`index ${index}`);
    }
    for (const [trigger, meta] of state.triggers) {
      if (trigger === name || meta.table === name) present.push(`trigger ${trigger}`);
    }
  }
  if (present.length > 0) {
    fail(
      `forbidden sealed-body objects documented: ${present.join(", ")}. ` +
        `The agent-memories FTS index must never appear in ${DOC_PATH}.`,
    );
  }
}

function checkHeader(docText, identifiers) {
  const endpoint = identifiers[identifiers.length - 1];
  const headerEndpoint = docText.match(/^-- migrationEndpoint: (\S+)/m)?.[1];
  const headerCount = docText.match(/^-- migrationCount: (\d+)/m)?.[1];
  const headerHash = docText.match(/^-- schemaHashSHA256: ([0-9a-f]{64})/m)?.[1];
  if (headerEndpoint !== endpoint) {
    fail(
      `doc header migrationEndpoint is ${headerEndpoint ?? "(missing)"}, migrator head is ${endpoint}. Regenerate the doc.`,
    );
  }
  if (Number(headerCount) !== identifiers.length) {
    fail(
      `doc header migrationCount is ${headerCount ?? "(missing)"}, migrator registered ${identifiers.length}. Regenerate the doc.`,
    );
  }
  if (!headerHash) {
    fail(`doc header schemaHashSHA256 is missing. Regenerate the doc.`);
  }
  return headerHash;
}

function checkVectorCorpus(docText, headerHash) {
  let vector;
  try {
    vector = JSON.parse(readFileSync(join(repoRoot, VECTOR_PATH), "utf8"));
  } catch (error) {
    fail(`cannot read ${VECTOR_PATH}: ${error.message}`);
  }
  if (vector.schemaHashSHA256 !== headerHash) {
    fail(
      `doc schema hash ${headerHash} disagrees with the DB byte-compat vector ` +
        `(${vector.schemaHashSHA256 ?? "(missing)"}). Regenerate the vector ` +
        `(DatabaseByteCompatVectorTests) and the doc together.`,
    );
  }
  // Statement-for-statement lock: the doc's own DDL must reproduce the live
  // migrator's DDL corpus byte-for-byte. This catches hand edits the
  // name-level surface check cannot see (column types, defaults, constraints,
  // trigger bodies, index expressions).
  let statements;
  try {
    statements = splitDocStatements(docText);
  } catch (error) {
    fail(`cannot split ${DOC_PATH} into statements: ${error.message}`);
  }
  const rejoined = sha256Hex(statements.join("\n"));
  if (rejoined !== headerHash) {
    fail(
      `doc statements hash to ${rejoined}, not the header hash ${headerHash}: ` +
        `the doc was hand-edited or the splitter cannot represent it. Regenerate the doc.`,
    );
  }
  const expected = vector.endpointStatements;
  if (!Array.isArray(expected)) {
    fail(
      `${VECTOR_PATH} has no endpointStatements array. Regenerate the vector ` +
        `(DatabaseByteCompatVectorTests) and the doc together.`,
    );
  }
  if (statements.length !== expected.length) {
    fail(
      `doc holds ${statements.length} DDL statements, the live vector holds ` +
        `${expected.length}. Regenerate the vector and the doc together.`,
    );
  }
  for (let i = 0; i < statements.length; i += 1) {
    if (statements[i] !== expected[i]) {
      const show = (s) => JSON.stringify(s.length > 160 ? `${s.slice(0, 160)}…` : s);
      fail(
        `doc statement ${i} differs from the live vector:\n    doc:    ${show(statements[i])}\n    vector: ${show(expected[i])}\nRegenerate the vector and the doc together.`,
      );
    }
  }
}

function main() {
  const docText = readFileSync(join(repoRoot, DOC_PATH), "utf8");
  if (!docText.startsWith("-- GENERATED BY")) {
    fail(`${DOC_PATH} lost its GENERATED header — it must only ever be written by OpenBurnBarSchemaExport.`);
  }

  const canon = extractSwiftMigrations(
    repoRoot,
    SURFACES.swiftCanon,
    (dir) => readdirSync(dir),
  );
  const canonState = replayMigrations(canon.migrations);

  const docState = parseDocSurface(docText);
  checkForbiddenObjects(docState);
  stripDocOnlyObjects(docState);

  const divergences = diffSchemaSurfaces("schemadoc", canonState, docState);
  if (divergences.length > 0) {
    const lines = divergences.map((d) => `  - ${d.key}: ${d.detail}`);
    fail(
      `doc surface differs from the migrator endpoint (${divergences.length} divergences, no baseline allowed):\n${lines.join("\n")}\nRegenerate the doc.`,
    );
  }

  const headerHash = checkHeader(docText, canon.identifiers);
  checkVectorCorpus(docText, headerHash);

  console.log(
    `SQLite schema doc covers the migrator endpoint (${canon.identifiers.length} migrations, ` +
      `${docState.tables.size} tables, ${docState.indexes.size} indexes, ` +
      `${docState.triggers.size} triggers, hash ${headerHash}).`,
  );
}

const isDirectRun =
  process.argv[1] &&
  resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isDirectRun) {
  main();
}
