#!/usr/bin/env node
/**
 * Verify every Firestore collection-group query in functions/src has a usable
 * COLLECTION_GROUP index declared in firestore.indexes.json (the deploy source
 * of truth per firebase.json#firestore.indexes). Prod throws FAILED_PRECONDITION
 * on every tick of any scheduled job whose collection-group query lacks a
 * CG-scoped index — this exact failure class hit production before (see
 * docs/runbooks/iroh-rollout-status.md, iroh_audit_events.observedAt).
 *
 * Coverage rules (static approximation of Firestore index selection):
 *   - a bare collectionGroup().get() needs no custom index (built-in __name__);
 *   - one queried field is covered by a fieldOverride carrying a
 *     COLLECTION_GROUP entry in each required direction, or by a CG composite
 *     index whose leading field it is;
 *   - multiple queried fields are covered by a CG composite whose leading
 *     fields are exactly the queried set (Firestore serves queries on a prefix
 *     of a composite index).
 *
 * NOTE for authors of new fieldOverrides: an override REPLACES the default
 * single-field indexes for that field, so always keep the COLLECTION-scope
 * ASCENDING/DESCENDING entries alongside the COLLECTION_GROUP ones (see the
 * iroh_audit_events.observedAt override for the canonical 4-entry shape).
 *
 * Optional: --project <id> additionally asserts declared-vs-deployed parity
 * via gcloud — every declared composite index and fieldOverride index entry
 * must exist in the live database (this is the drift direction that breaks
 * prod: declared-but-never-deployed).
 */

import { execFileSync } from "node:child_process";
import { readFileSync, readdirSync } from "node:fs";
import { join, dirname, relative } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const INDEXES_PATH = join(repoRoot, "firestore.indexes.json");
const SOURCE_ROOT = join(repoRoot, "functions", "src");
const SKIP_DIRS = new Set(["node_modules", "__tests__", "__mocks__", "lib"]);

// --- declared index model -------------------------------------------------

function loadDeclared() {
  const declared = JSON.parse(readFileSync(INDEXES_PATH, "utf8"));
  /** @type {Map<string, Set<string>>} key `${group}\0${field}` -> Set("SCOPE:ORDER") */
  const overrides = new Map();
  for (const override of declared.fieldOverrides ?? []) {
    const key = `${override.collectionGroup}\0${override.fieldPath}`;
    const entries = overrides.get(key) ?? new Set();
    for (const index of override.indexes ?? []) {
      entries.add(`${index.queryScope}:${index.order ?? index.arrayConfig}`);
    }
    overrides.set(key, entries);
  }
  /** @type {Map<string, Array<Array<{fieldPath: string, order?: string, arrayConfig?: string}>>>} */
  const composites = new Map();
  for (const index of declared.indexes ?? []) {
    if (index.queryScope !== "COLLECTION_GROUP") continue;
    const fields = (index.fields ?? []).filter((f) => f.fieldPath !== "__name__");
    const list = composites.get(index.collectionGroup) ?? [];
    list.push(fields);
    composites.set(index.collectionGroup, list);
  }
  return { declared, overrides, composites };
}

// --- call-site extraction ---------------------------------------------------

function* walkSourceFiles(dir) {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    if (entry.isDirectory()) {
      if (!SKIP_DIRS.has(entry.name)) yield* walkSourceFiles(join(dir, entry.name));
    } else if (entry.name.endsWith(".ts") && !entry.name.endsWith(".test.ts")) {
      yield join(dir, entry.name);
    }
  }
}

/** Index just past the closing paren matching source[openIdx] === "(", skipping string literals. */
function consumeBalanced(source, openIdx) {
  let depth = 0;
  for (let i = openIdx; i < source.length; i += 1) {
    const ch = source[i];
    if (ch === '"' || ch === "'" || ch === "`") {
      i += 1;
      while (i < source.length && source[i] !== ch) {
        if (source[i] === "\\") i += 1;
        i += 1;
      }
    } else if (ch === "(") {
      depth += 1;
    } else if (ch === ")") {
      depth -= 1;
      if (depth === 0) return i + 1;
    }
  }
  throw new Error(`Unbalanced parentheses starting at offset ${openIdx}`);
}

/** Chained `.name(args)` calls following collectionGroup(...). */
function scanChain(source, openIdx) {
  let cursor = consumeBalanced(source, openIdx);
  const groupArg = source.slice(openIdx + 1, cursor - 1).trim();
  const calls = [];
  for (;;) {
    let i = cursor;
    while (i < source.length && /\s/.test(source[i])) i += 1;
    if (source[i] !== ".") break;
    i += 1;
    const name = /^[A-Za-z_$][\w$]*/.exec(source.slice(i, i + 64))?.[0];
    if (!name || source[i + name.length] !== "(") break;
    const end = consumeBalanced(source, i + name.length);
    calls.push({ name, args: source.slice(i + name.length + 1, end - 1) });
    cursor = end;
  }
  return { groupArg, calls };
}

function stringLiteral(text) {
  return /^\s*["'`]([^"'`]+)["'`]/.exec(text)?.[1];
}

function resolveGroupName(arg, source) {
  const literal = stringLiteral(arg);
  if (literal) return literal;
  if (/^[A-Za-z_$][\w$]*$/.test(arg)) {
    // Constant collection name (e.g. const AUDIT_META_COLLECTION = "audit_meta").
    return new RegExp(`\\b${arg}\\s*=\\s*["'\`]([^"'\`]+)["'\`]`).exec(source)?.[1];
  }
  return undefined;
}

function extractCallSites() {
  const sites = [];
  const problems = [];
  for (const filePath of walkSourceFiles(SOURCE_ROOT)) {
    const source = readFileSync(filePath, "utf8");
    const relPath = relative(repoRoot, filePath);
    const pattern = /\.collectionGroup(\s*)\(/g;
    let match;
    while ((match = pattern.exec(source)) !== null) {
      const openIdx = match.index + match[0].length - 1;
      const line = source.slice(0, match.index).split("\n").length;
      const where = `${relPath}:${line}`;
      const { groupArg, calls } = scanChain(source, openIdx);
      const group = resolveGroupName(groupArg, source);
      if (!group) {
        problems.push(`${where} — cannot statically resolve collection group name from \`${groupArg}\``);
        continue;
      }
      /** @type {Map<string, Set<string>>} field -> required CG directions */
      const fields = new Map();
      for (const call of calls) {
        if (call.name !== "where" && call.name !== "orderBy") continue;
        const field = stringLiteral(call.args);
        if (!field) {
          problems.push(`${where} — cannot statically resolve ${call.name}() field from \`${call.args.trim()}\``);
          continue;
        }
        if (field === "__name__") continue;
        const directions = fields.get(field) ?? new Set();
        directions.add(call.name === "orderBy" && /["'`]desc/.test(call.args) ? "DESCENDING" : "ASCENDING");
        fields.set(field, directions);
      }
      sites.push({ where, group, fields });
    }
  }
  return { sites, problems };
}

// --- coverage check ---------------------------------------------------------

function isCovered(site, { overrides, composites }) {
  const names = [...site.fields.keys()];
  if (names.length === 0) return true; // bare scan: built-in __name__ index
  const groupComposites = composites.get(site.group) ?? [];
  if (names.length === 1) {
    const field = names[0];
    const required = site.fields.get(field);
    const entries = overrides.get(`${site.group}\0${field}`);
    if (entries && [...required].every((dir) => entries.has(`COLLECTION_GROUP:${dir}`))) return true;
    return groupComposites.some(
      (comp) =>
        comp[0]?.fieldPath === field && [...required].every((dir) => (comp[0].order ?? "ASCENDING") === dir),
    );
  }
  const queried = new Set(names);
  return groupComposites.some((comp) => {
    const lead = comp.slice(0, names.length);
    if (lead.length !== names.length || !lead.every((f) => queried.has(f.fieldPath))) return false;
    return lead.every((f) =>
      [...site.fields.get(f.fieldPath)].every((dir) => (f.order ?? "ASCENDING") === dir),
    );
  });
}

// --- optional declared-vs-deployed parity (gcloud) ---------------------------

function gcloudJson(args) {
  return JSON.parse(execFileSync("gcloud", [...args, "--format=json"], { encoding: "utf8" }));
}

function groupFromResourceName(name) {
  return /collectionGroups\/([^/]+)\//.exec(name)?.[1];
}

function compositeSignature(group, fields) {
  const sig = fields
    .filter((f) => f.fieldPath !== "__name__")
    .map((f) => `${f.fieldPath}:${f.order ?? f.arrayConfig}`)
    .join(",");
  return `${group}(${sig})`;
}

function checkDeployedParity(project, declared) {
  const failures = [];
  const deployedComposites = new Set(
    gcloudJson(["firestore", "indexes", "composite", "list", "--project", project]).map((index) =>
      compositeSignature(groupFromResourceName(index.name), index.fields ?? []),
    ),
  );
  for (const index of declared.indexes ?? []) {
    if (index.queryScope !== "COLLECTION_GROUP" && index.queryScope !== "COLLECTION") continue;
    const sig = compositeSignature(index.collectionGroup, index.fields ?? []);
    if (!deployedComposites.has(sig)) {
      failures.push(`declared composite missing in prod: ${index.queryScope} ${sig}`);
    }
  }
  /** @type {Map<string, Set<string>>} */
  const deployedOverrides = new Map();
  for (const field of gcloudJson(["firestore", "indexes", "fields", "list", "--project", project])) {
    const parsed = /collectionGroups\/([^/]+)\/fields\/(.+)$/.exec(field.name);
    if (!parsed) continue;
    const entries = new Set();
    for (const index of field.indexConfig?.indexes ?? []) {
      const entry = (index.fields ?? []).find((f) => f.fieldPath !== "__name__") ?? index.fields?.[0];
      entries.add(`${index.queryScope}:${entry?.order ?? entry?.arrayConfig}`);
    }
    deployedOverrides.set(`${parsed[1]}\0${parsed[2]}`, entries);
  }
  for (const override of declared.fieldOverrides ?? []) {
    const key = `${override.collectionGroup}\0${override.fieldPath}`;
    const deployed = deployedOverrides.get(key) ?? new Set();
    for (const index of override.indexes ?? []) {
      const entry = `${index.queryScope}:${index.order ?? index.arrayConfig}`;
      if (!deployed.has(entry)) {
        failures.push(
          `declared fieldOverride missing in prod: ${override.collectionGroup}.${override.fieldPath} ${entry}`,
        );
      }
    }
  }
  return failures;
}

// --- main --------------------------------------------------------------------

const projectFlag = process.argv.indexOf("--project");
const project = projectFlag !== -1 ? process.argv[projectFlag + 1] : undefined;
if (projectFlag !== -1 && !project) {
  console.error("--project requires a project id");
  process.exit(2);
}

const declaredModel = loadDeclared();
const { sites, problems } = extractCallSites();
const uncovered = sites.filter((site) => !isCovered(site, declaredModel));

for (const problem of problems) {
  console.error(`::error::collection-group guard: ${problem}`);
}
for (const site of uncovered) {
  const fields = [...site.fields.keys()].join(", ");
  console.error(
    `::error::collection-group query has no COLLECTION_GROUP index declared in firestore.indexes.json: ` +
      `${site.where} — collectionGroup("${site.group}") on [${fields}]. ` +
      `Add a fieldOverride (keep COLLECTION ASC/DESC entries — overrides replace defaults) or a CG composite.`,
  );
}
if (problems.length > 0 || uncovered.length > 0) {
  process.exit(1);
}
console.log(
  `All ${sites.length} collection-group query call sites have declared COLLECTION_GROUP index coverage.`,
);

if (project) {
  const failures = checkDeployedParity(project, declaredModel.declared);
  if (failures.length > 0) {
    for (const failure of failures) console.error(`::error::index drift [${project}]: ${failure}`);
    console.error(`Fix with: firebase deploy --only firestore:indexes --project ${project}`);
    process.exit(1);
  }
  console.log(`Declared indexes and fieldOverrides all present in project ${project}.`);
}
