#!/usr/bin/env node
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

const workflowDir = join(process.cwd(), ".github", "workflows");
const shaRef = /^[a-f0-9]{40}$/iu;
const digestRef = /^sha256:[a-f0-9]{64}$/iu;
const protectedBranchReusableWorkflows = new Map([
  [
    "deploy-staging.yml",
    "Imagine-That-Ai/BurnBar/.github/workflows/deploy-staging-trusted.yml@main",
  ],
]);
const failures = [];

for (const file of readdirSync(workflowDir).filter((name) => /\.ya?ml$/u.test(name)).sort()) {
  const path = join(workflowDir, file);
  const source = readFileSync(path, "utf8");
  const lines = source.split(/\r?\n/u);
  lines.forEach((line, index) => {
    // Both spellings: a bare `uses:` under a named step, and the compact
    // `- uses:` list item. Omitting the list form left the majority of step
    // references unchecked, so an unpinned tag could land in the common shape.
    const match = line.match(/^\s*(?:-\s*)?uses:\s*["']?([^"'\s#]+)["']?/u);
    if (!match) return;
    const spec = match[1];
    if (spec.startsWith("./") || spec.startsWith("../")) return;
    const at = spec.lastIndexOf("@");
    if (at === -1) {
      failures.push(`${file}:${index + 1}: external action is missing an @ref (${spec})`);
      return;
    }
    const ref = spec.slice(at + 1);
    // This single self-reusable workflow intentionally binds cloud OIDC trust
    // to job_workflow_ref ending in @refs/heads/main. A squash commit cannot be
    // known before landing, and substituting a candidate SHA would move the
    // credentialed job definition back under candidate control. The staging
    // boundary verifier independently requires this exact repository/file/ref.
    if (protectedBranchReusableWorkflows.get(file) === spec) return;
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

console.log(
  "OK: external actions are immutable; the reviewed staging reusable workflow is bound to protected main.",
);
