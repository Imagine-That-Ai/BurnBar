import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

import { RELEASE_CONSUMERS } from "../lib/domain-core-release-evidence.mjs";
import { deriveDomainCoreFunctionsTargets } from "./verify-domain-core-functions-target-inventory.mjs";

const core = readFileSync(
  new URL("../../.github/workflows/domain-core.yml", import.meta.url),
  "utf8",
);
const androidNativeLoad = readFileSync(
  new URL("./run-domain-core-android-native-load.sh", import.meta.url),
  "utf8",
);
const pythonBuild = readFileSync(
  new URL("../../scripts/build-domain-core-python.sh", import.meta.url),
  "utf8",
);
const androidAarBuild = readFileSync(
  new URL("../../scripts/build-domain-core-android-aar.sh", import.meta.url),
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
const release = readFileSync(
  new URL("../../.github/workflows/release.yml", import.meta.url),
  "utf8",
);
const iosEvidence = readFileSync(
  new URL(
    "../../.github/workflows/domain-core-ios-release-evidence.yml",
    import.meta.url,
  ),
  "utf8",
);
const artifactVerifier = readFileSync(
  new URL(
    "../../scripts/ci/verify-domain-core-build-profile-artifact.mjs",
    import.meta.url,
  ),
  "utf8",
);
const functionsDeploy = readFileSync(
  new URL("../../.github/workflows/deploy-production.yml", import.meta.url),
  "utf8",
);
const hostingDeploy = readFileSync(
  new URL("../../.github/workflows/deploy-hosting.yml", import.meta.url),
  "utf8",
);
const functionsTargets = JSON.parse(
  readFileSync(
    new URL(
      "../../config/domain-core-functions-relevant-targets.json",
      import.meta.url,
    ),
  ),
);
const functionsIndex = readFileSync(
  new URL("../../functions/src/index.ts", import.meta.url),
  "utf8",
);

function workflowJob(source, name) {
  const start = source.indexOf(`  ${name}:\n`);
  assert.notEqual(start, -1, `missing workflow job ${name}`);
  const remainder = source.slice(start + 2);
  const next = remainder.search(/^  [A-Za-z0-9_-]+:\n/mu);
  return next === -1
    ? source.slice(start)
    : source.slice(start, start + 2 + next);
}

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
  const android = workflowJob(core, "android");
  const apple = workflowJob(core, "apple");
  assert.match(
    android,
    /^      - name: Check out repository\n(?: {8}.*\n| {10}.*\n)* {10}ref: \$\{\{ github\.event\.pull_request\.head\.sha \|\| github\.sha \}\}$/mu,
  );
  const androidCheckoutRef = android.indexOf(
    "ref: ${{ github.event.pull_request.head.sha || github.sha }}",
  );
  const canonicalCandidateResolution = android.indexOf(
    "Resolve canonical candidate commit",
  );
  assert.ok(androidCheckoutRef >= 0);
  assert.ok(androidCheckoutRef < canonicalCandidateResolution);
  assert.match(
    core,
    /^  swift-consumer-contracts:\n(?:.*\n){0,4}    timeout-minutes: 90$/mu,
  );
  assert.match(
    core,
    /^          script: bash scripts\/ci\/run-domain-core-android-native-load\.sh android\/openburnbar-domain-core\/build\/outputs\/apk\/androidTest\/debug\/openburnbar-domain-core-debug-androidTest\.apk "\$\{\{ steps\.candidate\.outputs\.candidate_commit \}\}" "\$RUNNER_TEMP\/android-observed-identity\.json"$/mu,
  );
  assert.match(
    androidNativeLoad,
    /^if ! "\$adb_bin" exec-out run-as "\$instrumentation_package" \\$/mu,
  );
  assert.match(
    androidNativeLoad,
    /^identity_path="\$data_path\/files\/domain-core-observed-identity\.json"$/mu,
  );
  assert.match(
    android,
    /Freeze the exact observed Android native library[\s\S]*instrumentation_apk="android\/openburnbar-domain-core\/build\/outputs\/apk\/androidTest\/debug\/openburnbar-domain-core-debug-androidTest\.apk"[\s\S]*unzip -p "\$instrumentation_apk"[\s\S]*lib\/x86_64\/libopenburnbar_domain_ffi\.so > "\$observed_library"[\s\S]*--artifact "\$observed_library"/u,
  );
  assert.doesNotMatch(
    android,
    /stage-domain-core-attestation-artifact\.mjs[\s\S]{0,200}--artifact Vendor\/openburnbar-domain-core\.aar/u,
  );
  const byteDriftCheck = android.indexOf(
    "./scripts/build-domain-core-android-aar.sh --check-artifact",
  );
  const candidateResolution = android.indexOf(
    "Resolve signed Android domain-core candidate",
  );
  const candidateBuild = android.indexOf(
    "Build candidate-bound four-ABI Android AAR",
  );
  assert.ok(byteDriftCheck >= 0);
  assert.ok(byteDriftCheck < candidateResolution);
  assert.ok(candidateResolution < candidateBuild);
  assert.match(
    apple,
    /Build Apple XCFramework and regenerate Swift bindings[\s\S]*OPENBURNBAR_DOMAIN_CORE_CANDIDATE_COMMIT: \$\{\{ github\.sha \}\}[\s\S]*build-domain-core-xcframework\.sh/u,
  );
  const swiftConsumer = workflowJob(core, "swift-consumer-contracts");
  const restoreSwiftArtifacts = swiftConsumer.indexOf(
    "Restore checked-in Swift artifacts after debug validation",
  );
  const emitSwiftProof = swiftConsumer.indexOf(
    "Emit Swift consumer proof fragment",
  );
  assert.ok(restoreSwiftArtifacts >= 0);
  assert.ok(restoreSwiftArtifacts < emitSwiftProof);
  assert.match(
    swiftConsumer,
    /git restore --source=HEAD -- \\\n            Vendor\/OpenBurnBarDomainCore\.xcframework \\\n            OpenBurnBarCore\/Sources\/OpenBurnBarDomainCore\/Generated \\\n            crates\/openburnbar-domain-core\/artifact-provenance\/swift\.sha256/u,
  );
});

test("Python native evidence reports the candidate embedded by Rust", () => {
  assert.match(
    pythonBuild,
    /export OPENBURNBAR_DOMAIN_CORE_CANDIDATE_COMMIT="\$\{DOMAIN_CORE_CANDIDATE_COMMIT\}"[\s\S]*cargo build/u,
  );
  assert.match(
    pythonBuild,
    /candidate_commit = core\.domain_core_candidate_commit\(\)/u,
  );
  assert.match(
    pythonBuild,
    /candidate_commit == "0" \* 40 or candidate_commit != expected_candidate_commit/u,
  );
});

test("Android artifact generation rejects missing or duplicated embedded identity", () => {
  assert.match(
    androidAarBuild,
    /native library must contain exactly one canonical embedded identity; found \{count\}/u,
  );
  assert.match(
    androidAarBuild,
    /verified one canonical embedded identity in every Android ABI/u,
  );
});

test("Linux Tauri remains display-only while the Linux daemon stays under Swift ownership", () => {
  assert.doesNotMatch(
    linuxCargo,
    /openburnbar-domain-core|openburnbar_domain_core/u,
  );
  assert.match(
    inventory,
    /\| Tauri\/Linux UI\s*\| Displays daemon-produced values\s*\| No separate implementation/u,
  );
  assert.deepEqual(
    policy.requiredArtifacts
      .filter(({ id }) => id.includes("wasm"))
      .map(({ consumer }) => consumer)
      .sort(),
    ["browser-wasm", "node-wasm"],
  );
});

test("iOS deletion scope matches real mobile calls and a signed archive producer", () => {
  assert.deepEqual(RELEASE_CONSUMERS.ios.domains, [
    "cloudVault",
    "cloudVaultRewrap",
    "cloudVaultSearch",
    "hermes",
  ]);
  assert.match(
    inventory,
    /\| Swift \(iOS\)\s*\| No local provider quota parsing/u,
  );
  assert.match(release, /aarch64-apple-ios/u);
  assert.match(release, /xcodebuild archive[\s\S]*-scheme OpenBurnBarMobile/u);
  assert.match(release, /xcodebuild -exportArchive/u);
  assert.match(release, /OpenBurnBar-\$\{VERSION\}-iOS\.xcarchive\.zip/u);
  assert.match(release, /^  domain-core-ios-release-evidence:$/mu);
  assert.match(release, /^      - domain-core-ios-release-evidence$/mu);
  assert.match(
    release,
    /publish-domain-core-release-evidence\.mjs --manifest/u,
  );
  assert.match(release, /! -name 'domain-core-ios-\*'/u);
  assert.match(iosEvidence, /codesign --verify --deep --strict/u);
  assert.match(iosEvidence, /verify-domain-core-build-profile-artifact\.mjs/u);
  assert.match(artifactVerifier, /join\(candidate, "Info\.plist"\)/u);
  assert.match(iosEvidence, /\.domain == "cloudVault"/u);
  assert.doesNotMatch(
    RELEASE_CONSUMERS.ios.domains.join(" "),
    /quota|pricing/u,
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

test("stable tag replay is byte-and-provider-identical before any production mutation", () => {
  const functionsReplay = functionsDeploy.indexOf(
    "Refuse non-identical stable-tag redeploy",
  );
  assert.ok(functionsReplay > 0);
  assert.ok(
    functionsReplay < functionsDeploy.indexOf("Sentry release (Functions)"),
  );
  assert.ok(
    functionsReplay < functionsDeploy.indexOf("Deploy Cloud Functions"),
  );
  assert.match(functionsDeploy, /gcloud functions describe "\$target"/u);
  assert.match(
    functionsDeploy,
    /--provider-coordinates "\$RUNNER_TEMP\/existing-functions-provider-coordinates\.json"/u,
  );
  assert.match(
    functionsDeploy,
    /--inventory config\/domain-core-functions-relevant-targets\.json/u,
  );
  assert.match(
    functionsDeploy,
    /already live but its immutable Functions deployment receipt is missing/u,
  );
  assert.match(functionsDeploy, /gh attestation verify/u);
  assert.match(functionsDeploy, /domain-core-functions-release-evidence\.yml/u);

  const hostingReplay = hostingDeploy.indexOf(
    "Refuse non-identical stable-tag redeploy",
  );
  assert.ok(
    hostingReplay > hostingDeploy.indexOf("Authenticate to Google Cloud"),
  );
  assert.ok(
    hostingReplay <
      hostingDeploy.indexOf("Deploy Hosting (marketing + console)"),
  );
  assert.match(
    hostingDeploy,
    /firebasehosting\.googleapis\.com\/v1beta1\/sites\/\$\{site\}\/channels\/live\/releases\?pageSize=1/u,
  );
  assert.match(
    hostingDeploy,
    /--provider-coordinates "\$RUNNER_TEMP\/existing-hosting-provider-coordinates\.json"/u,
  );
  assert.match(
    hostingDeploy,
    /already live but its immutable Console deployment receipt is missing/u,
  );
  assert.match(hostingDeploy, /gh attestation verify/u);
  assert.match(hostingDeploy, /domain-core-console-release-evidence\.yml/u);
  const stagedManifestCreator = hostingDeploy.indexOf(
    'cp scripts/ci/create-domain-core-runtime-artifact-manifest.mjs "$ARTIFACT_ROOT/scripts/ci/"',
  );
  const usedManifestCreator = hostingDeploy.indexOf(
    'node "$ARTIFACT_ROOT/scripts/ci/create-domain-core-runtime-artifact-manifest.mjs"',
  );
  const stagedBearerHelper = hostingDeploy.indexOf(
    'cp scripts/lib/curl-bearer.sh "$ARTIFACT_ROOT/scripts/lib/"',
  );
  const sourcedBearerHelper = hostingDeploy.indexOf(
    'source "$ARTIFACT_ROOT/scripts/lib/curl-bearer.sh"',
  );
  assert.ok(stagedManifestCreator > 0);
  assert.ok(usedManifestCreator > stagedManifestCreator);
  assert.ok(stagedBearerHelper > 0);
  assert.ok(sourcedBearerHelper > stagedBearerHelper);
  assert.match(
    hostingDeploy,
    /obb_curl_with_bearer "\$FIREBASE_HOSTING_REST_ACCESS_TOKEN"/u,
  );
  assert.doesNotMatch(
    hostingDeploy,
    /-H "Authorization: Bearer \$\{FIREBASE_HOSTING_REST_ACCESS_TOKEN\}"/u,
  );
});

test("Functions preparation is uncredentialed and deploy consumes only a verified artifact", () => {
  const prepare = workflowJob(functionsDeploy, "prepare-functions-deploy");
  const deploy = workflowJob(functionsDeploy, "deploy-functions");

  assert.doesNotMatch(
    prepare,
    /environment: production|id-token: write|secrets\.|google-github-actions\/auth@/u,
  );
  assert.match(prepare, /Upload immutable prepared deploy artifact/u);
  assert.match(prepare, /find "\$stage" -type l/u);
  assert.match(prepare, /find "\$stage" -type f -links \+1/u);
  assert.match(prepare, /SHA256SUMS/u);
  assert.match(prepare, /--portable-functions-source/u);
  assert.match(
    prepare,
    /- name: Prepare pinned Sentry CLI\n        if: steps\.tag\.outputs\.dry_run != 'true'/u,
  );

  assert.match(deploy, /needs: prepare-functions-deploy/u);
  assert.match(deploy, /environment: production/u);
  assert.match(deploy, /id-token: write/u);
  assert.doesNotMatch(deploy, /actions\/checkout@|uses: \\.\//u);
  const verify = deploy.indexOf("Verify immutable prepared deploy artifact");
  const install = deploy.indexOf("Select verified deploy tools");
  const authenticate = deploy.indexOf("Authenticate to Google Cloud");
  assert.ok(verify > 0);
  assert.ok(install > verify);
  assert.ok(authenticate > install);
  assert.match(deploy, /sha256sum --check --strict SHA256SUMS/u);
  const restoreSentryMode = deploy.indexOf(
    "chmod 0700 sentry-cli/node_modules/@sentry/cli/bin/sentry-cli",
  );
  assert.ok(restoreSentryMode > verify);
  assert.ok(authenticate > restoreSentryMode);
  assert.doesNotMatch(deploy, /\bnpm\s+(?:ci|install|run|exec)\b/u);
  assert.match(
    deploy,
    /functions\/node_modules\/firebase-tools\/lib\/bin\/firebase\.js/u,
  );
  assert.match(
    deploy,
    /releases set-commits[^\n]+--commit "\$GITHUB_REPOSITORY@\$RELEASE_COMMIT"/u,
  );
  assert.doesNotMatch(deploy, /releases set-commits[^\n]+--auto/u);
});

test("protected Functions inventory covers every pricing execution entry and both runtime observers", () => {
  assert.equal(functionsTargets.schemaVersion, 1);
  assert.deepEqual(
    functionsTargets.targets,
    deriveDomainCoreFunctionsTargets(
      new URL("../..", import.meta.url).pathname,
    ),
  );
  for (const target of functionsTargets.targets) {
    assert.match(functionsIndex, new RegExp(`\\b${target}\\b`, "u"), target);
  }
  assert.match(
    functionsDeploy,
    /verify-domain-core-functions-target-inventory\.mjs/u,
  );
});
test("promotion-contracts cleanup removes trusted evaluator after final use and before proof emission", () => {
  const job = workflowJob(core, "promotion-contracts");

  // Verify the evaluator is used during legacy deletion verification
  const evaluatorUse = job.indexOf('evaluator=".domain-core-trusted-evaluator/scripts/ci/verify-domain-core-legacy-deletion.py"');
  assert.notEqual(evaluatorUse, -1, "trusted evaluator must be used for legacy deletion verification");

  // Verify the cleanup step exists and targets the correct path
  const cleanupStep = job.indexOf("Remove trusted evaluator checkout");
  assert.notEqual(cleanupStep, -1, "cleanup step must exist");
  const cleanupSection = job.slice(cleanupStep, job.indexOf("\n\n", cleanupStep));
  assert.match(cleanupSection, /run: rm -rf -- \.domain-core-trusted-evaluator/, "cleanup must remove .domain-core-trusted-evaluator directory");

  // Verify cleanup happens after evaluator use
  assert.ok(cleanupStep > evaluatorUse, "cleanup must happen after final evaluator use");

  // Verify cleanup happens before proof emission
  const proofEmission = job.indexOf("Emit promotion-contracts proof fragment");
  assert.notEqual(proofEmission, -1, "proof emission step must exist");
  assert.ok(cleanupStep < proofEmission, "cleanup must happen before proof emission");

  // Verify cleanup does not target wrong paths
  assert.doesNotMatch(job, /rm -rf -- \.domain-core-trusted-evaluator[^_\n]/, "cleanup must not target similar but wrong paths");
  assert.doesNotMatch(job, /rm -rf -- \.domain-core-trusted-evaluator[^\/\s]/, "cleanup must not target partial paths");
});
