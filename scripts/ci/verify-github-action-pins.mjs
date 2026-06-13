#!/usr/bin/env node
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

const workflowDir = join(process.cwd(), ".github", "workflows");
const shaRef = /^[a-f0-9]{40}$/iu;
const digestRef = /^sha256:[a-f0-9]{64}$/iu;
const failures = [];

for (const file of readdirSync(workflowDir).filter((name) => /\.ya?ml$/u.test(name)).sort()) {
  const path = join(workflowDir, file);
  const source = readFileSync(path, "utf8");
  const lines = source.split(/\r?\n/u);
  lines.forEach((line, index) => {
    const match = line.match(/^\s*uses:\s*["']?([^"'\s#]+)["']?/u);
    if (!match) return;
    const spec = match[1];
    if (spec.startsWith("./") || spec.startsWith("../")) return;
    const at = spec.lastIndexOf("@");
    if (at === -1) {
      failures.push(`${file}:${index + 1}: external action is missing an @ref (${spec})`);
      return;
    }
    const ref = spec.slice(at + 1);
    if (!shaRef.test(ref) && !digestRef.test(ref)) {
      failures.push(`${file}:${index + 1}: ${spec} is not pinned to a full commit SHA or sha256 digest`);
    }
  });
}

if (failures.length > 0) {
  console.error("Unpinned GitHub Actions references found:");
  for (const failure of failures) console.error(`  - ${failure}`);
  process.exit(1);
}

console.log("OK: all external GitHub Actions uses are pinned to immutable refs.");
