import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const core = readFileSync(new URL("../../.github/workflows/domain-core.yml", import.meta.url), "utf8");
const signer = readFileSync(
  new URL("../../.github/workflows/domain-core-promotion-proof.yml", import.meta.url),
  "utf8",
);
const policy = JSON.parse(
  readFileSync(new URL("../../config/domain-core-promotion-policy.json", import.meta.url)),
);

test("deterministic workflow implements every exact policy job and a fail-closed final bundle", () => {
  for (const id of policy.workflow.requiredJobIds) {
    assert.match(core, new RegExp(`^  ${id}:$`, "mu"), id);
  }
  assert.match(core, /^  candidate-bundle:\n    name: candidate-bundle\n    if: always\(\)/mu);
  assert.match(core, /toJSON\(needs\)/u);
  assert.match(core, /all\(\.value\.result == "success"\)/u);
  assert.match(core, /domain-core-proof-fragment\.mjs aggregate/u);
  assert.match(core, /create-domain-core-deterministic-candidate-bundle\.mjs/u);
  assert.match(core, /domain-core-candidate-bundle-\$\{\{ github\.sha \}\}-\$\{\{ github\.run_id \}\}-\$\{\{ github\.run_attempt \}\}/u);
});

test("protected signer has no user-supplied evidence surface and revalidates trusted API data", () => {
  assert.match(signer, /^    environment: domain-core-promotion$/mu);
  assert.match(signer, /^  actions: read$/mu);
  assert.match(signer, /^  attestations: write$/mu);
  assert.match(signer, /^  id-token: write$/mu);
  assert.match(signer, /actions\/workflows\/domain-core\.yml\/runs\?event=push/u);
  assert.match(signer, /git merge-base --is-ancestor/u);
  assert.match(signer, /environments\/domain-core-promotion/u);
  assert.match(signer, /required_reviewers/u);
  assert.match(signer, /deployment-branch-policies/u);
  assert.match(signer, /verify-domain-core-protected-attestation\.mjs/u);
  assert.match(signer, /actions\/attest-build-provenance@[0-9a-f]{40}/u);
  assert.doesNotMatch(signer, /jobs_json|bundle_json|run_json|eligible_for_attestation.*==/iu);
  assert.deepEqual(policy.workflow.allowedEvents, ["push"]);
  assert.equal(policy.promotionAuthority, false);
  assert.equal(policy.protectedAttestationRequired, true);
});

test("rollback proof publishes the dedicated signed legacy artifact and stable release retains it", () => {
  assert.match(core, /verify-domain-core-rollback\.mjs/u);
  assert.match(core, /--profile public-production-rollback/u);
  assert.match(core, /domain-core-public-production-rollback\.json/u);
  assert.match(core, /Exercise the actual Console signed rollback selector/u);
  assert.match(core, /retention-days: 90/u);
  assert.equal(policy.rollbackRequired, true);
  assert.equal(policy.oneStableReleaseBeforeDeletion, true);
  assert.equal(policy.stableReleaseRollbackArtifactRequired, true);
});
