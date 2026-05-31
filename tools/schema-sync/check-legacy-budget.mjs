#!/usr/bin/env node
/**
 * Gate hand-maintained TypeScript surface area (excluding generated bindings).
 * Baseline may only be lowered in the same PR that deletes legacy types.
 */
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const functionsSrc = path.join(repoRoot, "functions/src");
const baselinePath = path.join(repoRoot, "budgets/hand-maintained-ts-baseline.json");

const INTERFACE_RE = /^\s*export\s+interface\s+\w+/gm;
const TYPE_ALIAS_RE = /^\s*export\s+type\s+\w+/gm;
const generatedTypesDir = path.join(functionsSrc, "types", "generated");

function walkTsFiles(dir, out = []) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (full === generatedTypesDir || full.startsWith(`${generatedTypesDir}${path.sep}`)) continue;
      walkTsFiles(full, out);
      continue;
    }
    if (entry.isFile() && entry.name.endsWith(".ts") && !entry.name.endsWith(".d.ts")) {
      out.push(full);
    }
  }
  return out;
}

function countHandMaintainedLoc(files) {
  let loc = 0;
  let exportedInterfaces = 0;
  for (const file of files) {
    const text = fs.readFileSync(file, "utf8");
    loc += text.split("\n").length;
    exportedInterfaces += (text.match(INTERFACE_RE) ?? []).length;
    exportedInterfaces += (text.match(TYPE_ALIAS_RE) ?? []).length;
  }
  return { loc, exportedInterfaces, files: files.length };
}

const files = walkTsFiles(functionsSrc);
const live = countHandMaintainedLoc(files);

let baseline;
try {
  baseline = JSON.parse(fs.readFileSync(baselinePath, "utf8"));
} catch (error) {
  if (error?.code === "ENOENT") {
    console.error(`Missing checked-in baseline: ${baselinePath}`);
    process.exit(1);
  }
  throw error;
}
console.log(`Hand-maintained TS: live loc=${live.loc} baseline=${baseline.loc} files=${live.files}`);

if (live.loc > baseline.loc) {
  console.error(`Hand-maintained TS LOC increased by ${live.loc - baseline.loc}.`);
  console.error("Add new shared types via TypeSpec emit under tools/schema-sync/.");
  process.exit(1);
}

if (live.loc < baseline.loc) {
  console.log(`Hand-maintained TS improved by ${baseline.loc - live.loc}; update baseline intentionally.`);
}
