#!/usr/bin/env node
/**
 * Gate hand-maintained exported TypeScript schema/type surface area.
 *
 * Runtime Cloud Functions code should be allowed to grow when the product grows.
 * This check exists to ratchet down hand-maintained schema mirrors that should
 * move to TypeSpec emitters under tools/schema-sync/.
 */
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const functionsSrc = path.join(repoRoot, "functions/src");
const baselinePath = path.join(repoRoot, "budgets/hand-maintained-ts-baseline.json");

const EXPORTED_DECLARATION_RE = /^\s*export\s+(interface|type)\s+\w+\b/;
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

function braceDelta(line) {
  let delta = 0;
  for (const char of line) {
    if (char === "{") delta += 1;
    if (char === "}") delta -= 1;
  }
  return delta;
}

function declarationSpan(lines, startIndex, kind) {
  if (kind === "interface") {
    let depth = 0;
    let sawBrace = false;
    for (let index = startIndex; index < lines.length; index += 1) {
      const line = lines[index] ?? "";
      const delta = braceDelta(line);
      if (line.includes("{")) sawBrace = true;
      depth += delta;
      if (sawBrace && depth <= 0) return index;
    }
    return startIndex;
  }

  let depth = 0;
  for (let index = startIndex; index < lines.length; index += 1) {
    const line = lines[index] ?? "";
    depth += braceDelta(line);
    if (line.includes(";") && depth <= 0) return index;
  }
  return startIndex;
}

function countHandMaintainedSchemaSurface(files) {
  let loc = 0;
  let exportedInterfaces = 0;
  for (const file of files) {
    const text = fs.readFileSync(file, "utf8");
    const lines = text.split("\n");
    for (let index = 0; index < lines.length; index += 1) {
      const match = lines[index]?.match(EXPORTED_DECLARATION_RE);
      if (!match) continue;
      const endIndex = declarationSpan(lines, index, match[1]);
      loc += endIndex - index + 1;
      exportedInterfaces += 1;
      index = endIndex;
    }
  }
  return { loc, exportedInterfaces, files: files.length };
}

const files = walkTsFiles(functionsSrc);
const live = countHandMaintainedSchemaSurface(files);

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
console.log(
  `Hand-maintained TS schema surface: live loc=${live.loc} baseline=${baseline.loc} declarations=${live.exportedInterfaces} files=${live.files}`,
);

if (live.loc > baseline.loc) {
  console.error(`Hand-maintained exported schema/type LOC increased by ${live.loc - baseline.loc}.`);
  console.error("Add new shared types via TypeSpec emit under tools/schema-sync/.");
  process.exit(1);
}

if (live.loc < baseline.loc) {
  console.log(`Hand-maintained TS improved by ${baseline.loc - live.loc}; update baseline intentionally.`);
}
