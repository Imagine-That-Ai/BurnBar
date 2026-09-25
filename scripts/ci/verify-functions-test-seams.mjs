#!/usr/bin/env node
/**
 * Every 3.5 `src/testing.ts` namespace re-export must have a live importer
 * knip cannot see: an out-of-package edge (admin tests importing sibling
 * `src/`) or a compiled-`lib/` edge (harnesses importing build output).
 * A seam with no such importer is dead test surface: drop it instead of
 * letting knip coverage rot. Production code must never import from a
 * testing seam (tests and harnesses may).
 *
 * Limitation: computed dynamic specs (`await import(variable)`) carry no
 * literal to resolve, so they cannot witness a seam. No seam relies on one
 * today; if that changes, extend the witness set deliberately.
 */
import { readdirSync, readFileSync, statSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(
  process.env.FUNCTIONS_CI_FIXTURE_ROOT ?? join(dirname(fileURLToPath(import.meta.url)), "..", ".."),
);
const CODEBASES = ["functions", "functions-identity", "functions-sync", "functions-media"];

const walk = (dir, acc = []) => {
  let entries;
  try {
    entries = readdirSync(dir);
  } catch {
    return acc;
  }
  for (const entry of entries) {
    const full = join(dir, entry);
    if (statSync(full).isDirectory()) {
      if (entry !== "node_modules" && entry !== "lib" && entry !== "vendor") walk(full, acc);
    } else if (entry.endsWith(".ts") || entry.endsWith(".mjs")) {
      acc.push(full);
    }
  }
  return acc;
};

const corpusFiles = [
  ...walk(join(repoRoot, "functions", "src")),
  ...walk(join(repoRoot, "functions", "scripts")),
  ...walk(join(repoRoot, "functions-identity", "src")),
  ...walk(join(repoRoot, "functions-sync", "src")),
  ...walk(join(repoRoot, "functions-media", "src")),
];

const SPEC_RE =
  /(?:from\s+["']([^"']+)["']|(?:import|require)\(\s*["']([^"']+)["']\)|mock\(\s*["']([^"']+)["'])/g;
const REEXPORT_RE = /export\s+(?:\*|[^;]*?)\s+from\s+["']([^"']+)["']/g;

// resolvedAbsolutePath (no extension) -> importer rel paths.
// Seam files are never witnesses: their whole job is re-exporting.
const isSeamFile = (rel) => rel.endsWith("/testing.ts");
const edges = new Map();
const reExportedBy = new Map();
for (const file of corpusFiles) {
  const rel = file.slice(repoRoot.length + 1);
  if (isSeamFile(rel)) continue;
  const text = readFileSync(file, "utf8");
  for (const match of text.matchAll(SPEC_RE)) {
    const spec = match[1] ?? match[2] ?? match[3];
    if (!spec.startsWith(".")) continue;
    const resolved = resolve(dirname(file), spec).replace(/\.[cm]?[jt]s$/, "");
    if (!edges.has(resolved)) edges.set(resolved, []);
    edges.get(resolved).push(rel);
  }
  for (const match of text.matchAll(REEXPORT_RE)) {
    const spec = match[1];
    if (!spec.startsWith(".")) continue;
    const resolved = resolve(dirname(file), spec).replace(/\.[cm]?[jt]s$/, "");
    if (!reExportedBy.has(resolved)) reExportedBy.set(resolved, []);
    reExportedBy.get(resolved).push(rel);
  }
}

const failures = [];

for (const codebase of CODEBASES) {
  try {
    statSync(join(repoRoot, codebase, "src"));
  } catch {
    continue;
  }
  const seamPath = join(repoRoot, codebase, "src", "testing.ts");
  let seam;
  try {
    seam = readFileSync(seamPath, "utf8");
  } catch {
    failures.push(`${codebase}/src has no src/testing.ts seam file`);
    continue;
  }
  const specs = [...seam.matchAll(/export \* as \w+ from "\.\/([^"]+)\.js";/g)].map((m) => m[1]);
  if (specs.length === 0) {
    failures.push(`${codebase}/src/testing.ts exports no seam namespaces`);
  }
  // Knip sees same-package src edges; only out-of-package or lib/ edges
  // justify a seam — directly, or transitively through a same-package
  // re-export chain (knip flags dead chains link by link).
  const isLive = (srcKey, libKey, seen = new Set()) => {
    const importers = [...(edges.get(srcKey) ?? []), ...(edges.get(libKey) ?? [])];
    if (
      importers.some(
        (rel) => !rel.startsWith(`${codebase}/`) || edges.get(libKey)?.includes(rel),
      )
    ) {
      return true;
    }
    for (const reExporter of reExportedBy.get(srcKey) ?? []) {
      if (!reExporter.startsWith(`${codebase}/`) || seen.has(reExporter)) continue;
      seen.add(reExporter);
      const nextSrc = join(repoRoot, reExporter).replace(/\.[cm]?[jt]s$/, "");
      const nextLib = nextSrc.replace(`${codebase}/src/`, `${codebase}/lib/`);
      if (isLive(nextSrc, nextLib, seen)) return true;
    }
    return false;
  };
  for (const spec of specs) {
    const srcKey = join(repoRoot, codebase, "src", spec);
    const libKey = join(repoRoot, codebase, "lib", spec);
    if (!isLive(srcKey, libKey)) {
      const importers = [...(edges.get(srcKey) ?? []), ...(edges.get(libKey) ?? [])];
      failures.push(
        `${codebase}/src/testing.ts seams ${spec} with no knip-invisible importer` +
          (importers.length > 0 ? ` (only visible: ${importers.join(", ")})` : ""),
      );
    }
  }
}

// Nothing outside tests/harnesses may import a seam (currently nothing
// imports them at all; this locks the direction for future harness moves).
for (const file of corpusFiles) {
  const rel = file.slice(repoRoot.length + 1);
  if (rel.endsWith("/testing.ts")) continue;
  if (rel.includes("/__tests__/") || rel.includes("/scripts/")) continue;
  if (/from\s+["'][^"']*\/testing\.js["']/.test(readFileSync(file, "utf8"))) {
    failures.push(`production module ${rel} imports a testing seam`);
  }
}

if (failures.length > 0) {
  console.error("Functions test-seam verification failed:");
  for (const failure of failures) console.error(`  - ${failure}`);
  process.exit(1);
}
console.log("PASS: every Functions test seam has a live knip-invisible importer.");
