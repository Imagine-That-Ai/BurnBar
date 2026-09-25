#!/usr/bin/env node
/**
 * 3.5 deploy codebases are independently deployable: runtime sources must
 * never import across codebase boundaries. The sanctioned cross-codebase
 * channels are `@openburnbar/functions-shared` deep imports (runtime),
 * sibling-`src/` relative imports from the admin vitest suite, and
 * sibling-`lib/` imports from .mjs harnesses. Anything else is a layering
 * violation that the per-package typecheck cannot see.
 */
import { readdirSync, readFileSync, statSync } from "node:fs";
import { dirname, join, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(
  process.env.FUNCTIONS_CI_FIXTURE_ROOT ?? join(dirname(fileURLToPath(import.meta.url)), "..", ".."),
);
const CODEBASES = ["functions", "functions-identity", "functions-sync", "functions-media"];
const SHARED = "packages/functions-shared";

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

const SPEC_RE =
  /(?:from\s+["']([^"']+)["']|(?:import|require)\(\s*["']([^"']+)["']\)|mock\(\s*["']([^"']+)["'])/g;

const failures = [];
const checkFile = (file, owner) => {
  const rel = file.slice(repoRoot.length + 1);
  // Admin tests own the sibling-src channel (typechecked, colocated suite).
  if (rel.includes("/__tests__/")) return;
  const text = readFileSync(file, "utf8");
  for (const match of text.matchAll(SPEC_RE)) {
    const spec = match[1] ?? match[2] ?? match[3];
    if (!spec.startsWith(".")) continue;
    const resolved = resolve(dirname(file), spec);
    if (resolved.startsWith(`${repoRoot}${sep}${owner}${sep}`)) continue;
    // Harnesses run from build output and repo scripts: sibling lib/,
    // packages lib/, and scripts/lib are sanctioned. Sibling sources are
    // not runnable from .mjs and bypass the vendor channel, so only a
    // resolved */src/* import fails (codegen-template strings that name
    // unrelated paths stay out of the way).
    if (owner === "functions" && rel.includes("/scripts/")) {
      if (!resolved.includes(`${sep}src${sep}`)) continue;
    }
    failures.push(`${rel} escapes ${owner}: ${spec}`);
  }
};

for (const codebase of CODEBASES) {
  for (const file of walk(join(repoRoot, codebase, "src"))) checkFile(file, codebase);
}
for (const file of walk(join(repoRoot, "functions", "scripts"))) checkFile(file, "functions");
for (const file of walk(join(repoRoot, SHARED, "src"))) checkFile(file, SHARED);

if (failures.length > 0) {
  console.error("Functions codebase-isolation verification failed:");
  for (const failure of failures.slice(0, 20)) console.error(`  - ${failure}`);
  if (failures.length > 20) console.error(`  … and ${failures.length - 20} more`);
  process.exit(1);
}
console.log("PASS: Functions runtime sources stay inside their codebase.");
