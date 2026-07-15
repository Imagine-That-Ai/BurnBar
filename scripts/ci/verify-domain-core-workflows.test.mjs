import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const core = readFileSync(
  new URL("../../.github/workflows/domain-core.yml", import.meta.url),
  "utf8",
);
const signer = readFileSync(
  new URL(
    "../../.github/workflows/domain-core-promotion-proof.yml",
    import.meta.url,
  ),
  "utf8",
);
const policy = JSON.parse(
  readFileSync(
    new URL("../../config/domain-core-promotion-policy.json", import.meta.url),
  ),
);
const linuxCargo = readFileSync(
  new URL("../../apps/linux-desktop/src-tauri/Cargo.toml", import.meta.url),
  "utf8",
);
const inventory = readFileSync(
  new URL("../../docs/SHARED_RUST_DOMAIN_INVENTORY.md", import.meta.url),
  "utf8",
);

test("deterministic workflow implements every exact policy job and a fail-closed final bundle", () => {
  for (const id of policy.workflow.requiredJobIds) {
    assert.match(core, new RegExp(`^  ${id}:$`, "mu"), id);
  }
  assert.match(
    core,
    /^  candidate-bundle:\n    name: candidate-bundle\n    if: always\(\)/mu,
  );
  assert.match(core, /toJSON\(needs\)/u);
  assert.match(core, /all\(\.value\.result == "success"\)/u);
  assert.match(core, /domain-core-proof-fragment\.mjs aggregate/u);
  assert.match(core, /swift and xcframework provenance verified/u);
  assert.match(core, /create-domain-core-deterministic-candidate-bundle\.mjs/u);
  assert.match(
    core,
    /domain-core-candidate-bundle-\$\{\{ github\.sha \}\}-\$\{\{ github\.run_id \}\}-\$\{\{ github\.run_attempt \}\}/u,
  );
});

test("native consumer jobs keep their measured execution margin and emulator shell context", () => {
  assert.match(
    core,
    /^  swift-consumer-contracts:\n(?:.*\n){0,4}    timeout-minutes: 90$/mu,
  );
  assert.match(
    core,
    /^            cd android && \.\/gradlew :openburnbar-domain-core:connectedDebugAndroidTest .*candidateCommit="\$GITHUB_SHA"$/mu,
  );
  assert.match(
    core,
    /^            adb exec-out run-as com\.openburnbar\.domaincore\.test cat files\/domain-core-observed-identity\.json > "\$RUNNER_TEMP\/android-observed-identity\.json"$/mu,
  );
  const nativeBuild = core.indexOf("- name: Build host domain-core XCFramework");
  const nativeContracts = core.indexOf("- name: Run Swift domain-core consumer contracts");
  const nativeRestore = core.indexOf("- name: Restore checkout after native consumer tests");
  const nativeProof = core.indexOf("- name: Emit Swift consumer proof fragment");
  assert.ok(nativeBuild < nativeContracts, "native artifact must exist before consumer tests");
  assert.ok(nativeContracts < nativeRestore, "consumer tests must run before checkout restore");
  assert.ok(nativeRestore < nativeProof, "checkout must be clean before proof emission");
});

test("Linux Tauri remains display-only while the Linux daemon stays under Swift ownership", () => {
  assert.doesNotMatch(
    linuxCargo,
    /openburnbar-domain-core|openburnbar_domain_core/u,
  );
  assert.match(
    inventory,
    /\| Tauri\/Linux UI \| Displays daemon-produced values \| No separate implementation/u,
  );
  assert.deepEqual(
    policy.requiredArtifacts
      .filter(({ id }) => id.includes("wasm"))
      .map(({ consumer }) => consumer)
      .sort(),
    ["browser-wasm", "node-wasm"],
  );
});

test("protected signer has no user-supplied evidence surface and revalidates trusted API data", () => {
  assert.match(signer, /^    environment: domain-core-promotion$/mu);
  assert.match(signer, /^  actions: read$/mu);
  assert.match(signer, /^  attestations: write$/mu);
  assert.match(signer, /^  id-token: write$/mu);
  assert.match(
    signer,
    /actions\/workflows\/domain-core\.yml\/runs\?event=push/u,
  );
  assert.match(signer, /git merge-base --is-ancestor/u);
  assert.match(signer, /environments\/domain-core-promotion/u);
  assert.match(signer, /required_reviewers/u);
  assert.match(signer, /deployment-branch-policies/u);
  assert.match(signer, /verify-domain-core-protected-attestation\.mjs/u);
  assert.match(signer, /gh api --paginate --slurp/u);
  assert.match(signer, /\.total_count == \(\.branch_policies \| length\)/u);
  assert.match(signer, /\.total_count == \(\.workflow_runs \| length\)/u);
  assert.match(signer, /\.total_count == \(\.jobs \| length\)/u);
  assert.match(signer, /verify-domain-core-control-plane\.mjs/u);
  assert.match(signer, /ref: \$\{\{ github\.sha \}\}/u);
  assert.match(signer, /\[\[ "\$GITHUB_REF" == "refs\/heads\/main" \]\]/u);
  assert.match(signer, /git rev-parse HEAD/u);
  assert.match(signer, /--expected-evaluator-commit "\$GITHUB_SHA"/u);
  assert.doesNotMatch(signer, /^\s+ref: main$/mu);
  assert.match(signer, /actions\/attest-build-provenance@[0-9a-f]{40}/u);
  assert.doesNotMatch(
    signer,
    /jobs_json|bundle_json|run_json|eligible_for_attestation.*==/iu,
  );
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
