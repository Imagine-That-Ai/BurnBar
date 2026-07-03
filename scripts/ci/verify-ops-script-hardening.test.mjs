#!/usr/bin/env node
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const read = (path) => readFileSync(path, "utf8");

const hostedMcp = read("scripts/deploy-hosted-mcp.sh");
assert.match(
  hostedMcp,
  /\*\)\n\s+if \[\[ "\$SECONDS" -ge "\$deadline" \]\]; then\n\s+echo "Cloud Build timed out waiting for \$\{build_id\}; last status: \$\{status\}"/,
  "hosted MCP Cloud Build polling must time out even for unexpected statuses",
);

const cloudRunWorkflow = read(".github/workflows/deploy-cloud-run.yml");
assert.match(
  cloudRunWorkflow,
  /\*\)\n\s+if \[\[ "\$SECONDS" -ge "\$deadline" \]\]; then\n\s+echo "::error::Cloud Build timed out waiting for \$\{build_id\}; last status: \$\{status\}"/,
  "Cloud Run workflow polling must time out even for unexpected statuses",
);

const deadFlags = read("scripts/detect-dead-feature-flags.sh");
for (const include of ['--include="*.mjs"', '--include="*.js"', '--include="*.sh"']) {
  assert.ok(deadFlags.includes(include), `grep fallback must include ${include}`);
}

const versionConsistency = read("scripts/verify-version-consistency.sh");
assert.ok(
  versionConsistency.includes("OPENBURNBAR_REQUIRE_CURRENT_HOMEBREW_CASK"),
  "version consistency must expose an explicit Homebrew enforcement mode",
);
assert.match(
  versionConsistency,
  /GITHUB_REF_TYPE:-\}" == "tag"/,
  "version consistency must enforce current Homebrew cask on tag builds",
);

const firebaseRules = read("scripts/ci/deploy-firebase-rules-releases.mjs");
assert.match(
  firebaseRules,
  /method: "PATCH",[\s\S]*body: JSON\.stringify\(\{\s*release: update,\s*updateMask: "rulesetName",\s*\}\)/,
  "Firebase Rules release PATCH must use the nested release payload with a field mask",
);
const firestoreWorkflow = read(".github/workflows/deploy-firestore.yml");
assert.match(
  firestoreWorkflow,
  /--only firestore:indexes,storage/,
  "Firestore deploy workflow must avoid firebase-tools' broken firestore:rules release path",
);
assert.match(
  firestoreWorkflow,
  /node scripts\/ci\/deploy-firebase-rules-releases\.mjs "\$FIREBASE_PROJECT"/,
  "Firestore deploy workflow must release rules through the hardened REST script",
);

console.log("PASS: ops script hardening regression checks");
