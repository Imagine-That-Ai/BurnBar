#!/usr/bin/env node
import assert from "node:assert/strict";
import { readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const DOC_START = "<!-- BEGIN GENERATED MIGRATION CATALOG -->";
const DOC_END = "<!-- END GENERATED MIGRATION CATALOG -->";

// Wave 2.2 deleted the AgentLens migrator copy: OpenBurnBarData is the single
// migrator, so there is no app↔shared body parity left to enforce (the former
// INTENTIONAL_DIVERGENCES table died with the twin). This verifier now guards
// the single-surface contract: every registration lives inside a function the
// migrator calls, the rollback catalog lists the same migrations in the same
// order, and the generated DATABASE_OPERATIONS.md table matches the catalog.
// Migration BODY drift is caught by the schema-doc check
// (scripts/ci/verify-sqlite-schema-doc.mjs) and the DB byte-compat vector.

function walkSwiftFiles(root) {
  const files = [];
  for (const entry of readdirSync(root).sort()) {
    const candidate = path.join(root, entry);
    if (statSync(candidate).isDirectory()) files.push(...walkSwiftFiles(candidate));
    else if (candidate.endsWith(".swift")) files.push(candidate);
  }
  return files;
}

function matchingBrace(source, openingBrace) {
  let depth = 0;
  let mode = "code";
  let blockCommentDepth = 0;

  for (let index = openingBrace; index < source.length; index += 1) {
    const current = source[index];
    const next = source[index + 1];
    const nextTwo = source.slice(index, index + 3);

    if (mode === "line-comment") {
      if (current === "\n") mode = "code";
      continue;
    }
    if (mode === "block-comment") {
      if (current === "/" && next === "*") {
        blockCommentDepth += 1;
        index += 1;
      } else if (current === "*" && next === "/") {
        blockCommentDepth -= 1;
        index += 1;
        if (blockCommentDepth === 0) mode = "code";
      }
      continue;
    }
    if (mode === "string") {
      if (current === "\\") index += 1;
      else if (current === '"') mode = "code";
      continue;
    }
    if (mode === "multiline-string") {
      if (nextTwo === '\"\"\"') {
        mode = "code";
        index += 2;
      }
      continue;
    }

    if (current === "/" && next === "/") {
      mode = "line-comment";
      index += 1;
    } else if (current === "/" && next === "*") {
      mode = "block-comment";
      blockCommentDepth = 1;
      index += 1;
    } else if (nextTwo === '\"\"\"') {
      mode = "multiline-string";
      index += 2;
    } else if (current === '"') {
      mode = "string";
    } else if (current === "{") {
      depth += 1;
    } else if (current === "}") {
      depth -= 1;
      if (depth === 0) return index;
    }
  }
  throw new Error(`unclosed brace at offset ${openingBrace}`);
}

export function normalizeSwiftBody(source) {
  let result = "";
  let mode = "code";
  let blockCommentDepth = 0;

  for (let index = 0; index < source.length; index += 1) {
    const current = source[index];
    const next = source[index + 1];
    const nextTwo = source.slice(index, index + 3);

    if (mode === "line-comment") {
      if (current === "\n") mode = "code";
      continue;
    }
    if (mode === "block-comment") {
      if (current === "/" && next === "*") {
        blockCommentDepth += 1;
        index += 1;
      } else if (current === "*" && next === "/") {
        blockCommentDepth -= 1;
        index += 1;
        if (blockCommentDepth === 0) mode = "code";
      }
      continue;
    }
    if (mode === "string") {
      result += current;
      if (current === "\\") {
        result += next ?? "";
        index += 1;
      } else if (current === '"') {
        mode = "code";
      }
      continue;
    }
    if (mode === "multiline-string") {
      result += current;
      if (nextTwo === '\"\"\"') {
        result += '\"\"';
        index += 2;
        mode = "code";
      }
      continue;
    }

    if (current === "/" && next === "/") {
      mode = "line-comment";
      index += 1;
    } else if (current === "/" && next === "*") {
      mode = "block-comment";
      blockCommentDepth = 1;
      index += 1;
    } else if (nextTwo === '\"\"\"') {
      result += nextTwo;
      mode = "multiline-string";
      index += 2;
    } else if (current === '"') {
      result += current;
      mode = "string";
    } else if (!/\s/u.test(current)) {
      result += current;
    }
  }
  return result;
}

function extractFunctionBodies(source) {
  const bodies = new Map();
  const pattern = /\b(?:private\s+)?static\s+func\s+([A-Za-z0-9_]+)\s*\(/gu;
  for (const match of source.matchAll(pattern)) {
    const openingBrace = source.indexOf("{", match.index + match[0].length);
    assert.notEqual(openingBrace, -1, `function ${match[1]} has no body`);
    const closingBrace = matchingBrace(source, openingBrace);
    bodies.set(match[1], source.slice(openingBrace + 1, closingBrace));
  }
  return bodies;
}

export function extractMigrationRegistrations(source) {
  const migrations = [];
  const pattern = /migrator\.registerMigration\("([^"\n]+)"\)\s*\{/gu;
  for (const match of source.matchAll(pattern)) {
    const openingBrace = source.indexOf("{", match.index + match[0].length - 1);
    const closingBrace = matchingBrace(source, openingBrace);
    migrations.push({ name: match[1], body: source.slice(openingBrace + 1, closingBrace) });
  }
  return migrations;
}

export function extractMigrationNames(source) {
  return extractMigrationRegistrations(source).map(({ name }) => name);
}

export function extractCatalogEntries(source) {
  return Array.from(
    source.matchAll(
      /^\s*"([^"|]+)\|(atomic)\|(unapplied-only)\|(backup-restore)\|([^"\n]+)"\s*$/gmu
    ),
    (match) => ({
      name: match[1],
      transaction: match[2],
      retry: match[3],
      rollback: match[4],
      description: match[5],
    })
  );
}

export function extractCatalogNames(source) {
  return extractCatalogEntries(source).map(({ name }) => name);
}

function assertUnique(names, label) {
  const duplicates = names.filter((name, index) => names.indexOf(name) !== index);
  assert.deepEqual(duplicates, [], `${label} contains duplicate migrations: ${duplicates.join(", ")}`);
}

function loadMigrationSurface(root) {
  const files = walkSwiftFiles(root);
  const functions = new Map();
  const allRegistrations = [];
  for (const file of files) {
    const source = readFileSync(file, "utf8");
    allRegistrations.push(...extractMigrationRegistrations(source));
    for (const [name, body] of extractFunctionBodies(source)) {
      if (!body.includes("migrator.registerMigration")) continue;
      assert(!functions.has(name), `duplicate static function ${name} under ${root}`);
      functions.set(name, { body, source, file });
    }
  }

  const rootSource = readFileSync(path.join(root, "OpenBurnBarDatabase.swift"), "utf8");
  const callOrder = Array.from(
    rootSource.matchAll(/\b(register[A-Za-z0-9_]+)\(on:\s*&migrator\)/gu),
    (match) => match[1]
  );
  assert(callOrder.length > 0, `${root} has no ordered migrator registration calls`);

  const ordered = [];
  for (const functionName of callOrder) {
    const definition = functions.get(functionName);
    assert(definition, `${root} calls missing migration function ${functionName}`);
    for (const registration of extractMigrationRegistrations(definition.body)) {
      ordered.push(registration);
    }
  }

  assert.equal(
    ordered.length,
    allRegistrations.length,
    `${root} has migration registrations outside the functions called by migrator`
  );
  return ordered;
}

export function renderMigrationCatalog(entries) {
  const rows = entries.map(
    (entry, index) =>
      `| ${index + 1} | \`${entry.name}\` | ${entry.transaction} | ${entry.retry} | ${entry.rollback} | ${entry.description} |`
  );
  return [
    DOC_START,
    "| # | Name | Transaction | Retry | Rollback | Description |",
    "|---:|---|---|---|---|---|",
    ...rows,
    DOC_END,
  ].join("\n");
}

function updateOrVerifyDocumentation(repoRoot, entries, writeDocumentation) {
  const documentationPath = path.join(repoRoot, "docs", "DATABASE_OPERATIONS.md");
  const documentation = readFileSync(documentationPath, "utf8");
  const start = documentation.indexOf(DOC_START);
  const end = documentation.indexOf(DOC_END);
  assert(start >= 0 && end > start, "DATABASE_OPERATIONS.md is missing generated migration catalog markers");

  const expected = renderMigrationCatalog(entries);
  const actual = documentation.slice(start, end + DOC_END.length);
  if (writeDocumentation) {
    writeFileSync(
      documentationPath,
      `${documentation.slice(0, start)}${expected}${documentation.slice(end + DOC_END.length)}`
    );
  } else {
    assert.equal(actual, expected, "DATABASE_OPERATIONS.md migration catalog is stale; run verifier with --write-doc");
  }
}

export function verifyMigrationRollbackCatalog(repoRoot, { writeDocumentation = false } = {}) {
  const migrations = loadMigrationSurface(
    path.join(repoRoot, "OpenBurnBarCore", "Sources", "OpenBurnBarData")
  );
  const rollbackSource = readFileSync(path.join(repoRoot, "scripts", "rollback-migration.sh"), "utf8");
  const rollbackEntries = extractCatalogEntries(rollbackSource);
  const rollbackNames = rollbackEntries.map(({ name }) => name);

  assertUnique(migrations.map(({ name }) => name), "single migrator");
  assertUnique(rollbackNames, "rollback catalog");
  assert.deepEqual(rollbackNames, migrations.map(({ name }) => name), "rollback catalog order differs from migrator");
  updateOrVerifyDocumentation(repoRoot, rollbackEntries, writeDocumentation);

  return migrations.length;
}

const currentFile = fileURLToPath(import.meta.url);
if (process.argv[1] && path.resolve(process.argv[1]) === currentFile) {
  const repoRoot = path.resolve(path.dirname(currentFile), "..", "..");
  const writeDocumentation = process.argv.includes("--write-doc");
  const count = verifyMigrationRollbackCatalog(repoRoot, { writeDocumentation });
  console.log(
    `migration contract: ${count} ordered migrations, rollback catalog, and documentation verified`
  );
}
