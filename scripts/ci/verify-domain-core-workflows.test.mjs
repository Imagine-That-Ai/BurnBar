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
const androidAppBuild = readFileSync(
  new URL("../../android/app/build.gradle.kts", import.meta.url),
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

test("authoritative push proofs cannot be cancelled by merge-queue validation or later main pushes", () => {
  // Push runs are keyed by commit SHA and exempt from cancel-in-progress:
  // a second main push landing before the first run's candidate bundle
  // completes must not cancel it, or that first commit loses the exact-main
  // source proof deploy-production.yml requires and becomes undeployable.
  assert.match(
    core,
    /concurrency:\n  group: domain-core-\$\{\{ github\.event_name \}\}-\$\{\{ github\.event_name == 'push' && github\.sha \|\| github\.ref \}\}\n  cancel-in-progress: \$\{\{ github\.event_name != 'push' \}\}/u,
  );
});

test("Wasm KAT reports bind distinct package execution contexts", () => {
  const wasm = workflowJob(core, "wasm");
  assert.match(
    wasm,
    /printf '%s\\n' 'suite=wasm-browser-kat'[\s\S]*tee "\$RUNNER_TEMP\/wasm-browser-kat\.log"/u,
  );
  assert.match(
    wasm,
    /printf '%s\\n' 'suite=wasm-node-kat'[\s\S]*tee "\$RUNNER_TEMP\/wasm-node-kat\.log"/u,
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
    /^  swift-consumer-contracts:\n(?:.*\n){0,12}    timeout-minutes: \$\{\{ \(github\.event_name == 'pull_request' \|\| github\.event_name == 'merge_group'\) && 25 \|\| 90 \}\}$/mu,
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
  const hostJvmBuild = android.indexOf(
    "Build host domain core for JVM consumer contracts",
  );
  const androidConsumerContracts = android.indexOf(
    "Run Android app domain-core consumer contracts",
  );
  assert.ok(candidateBuild < hostJvmBuild);
  assert.ok(hostJvmBuild < androidConsumerContracts);
  assert.match(
    android,
    /Build host domain core for JVM consumer contracts[\s\S]*working-directory: crates\/openburnbar-domain-core[\s\S]*OPENBURNBAR_DOMAIN_CORE_CANDIDATE_COMMIT: \$\{\{ steps\.candidate\.outputs\.candidate_commit \}\}[\s\S]*cargo build --locked -p openburnbar-domain-ffi/u,
  );
  assert.match(
    android,
    /-Dopenburnbar\.domainCore\.nativeLibraryPath="\$GITHUB_WORKSPACE\/crates\/openburnbar-domain-core\/target\/debug\/libopenburnbar_domain_ffi\.so"/u,
  );
  assert.match(
    androidAppBuild,
    /testImplementation\("net\.java\.dev\.jna:jna:5\.19\.0"\)/u,
  );
  assert.match(
    androidAppBuild,
    /providers\.systemProperty\("openburnbar\.domainCore\.nativeLibraryPath"\)[\s\S]*"uniffi\.component\.openburnbar_domain_ffi\.libraryOverride"/u,
  );
  assert.match(
    apple,
    /Build Apple XCFramework and regenerate Swift bindings[\s\S]*OPENBURNBAR_DOMAIN_CORE_CANDIDATE_COMMIT: \$\{\{ github\.sha \}\}[\s\S]*build-domain-core-xcframework\.sh/u,
  );
  const swiftConsumer = workflowJob(core, "swift-consumer-contracts");
  const restoreSwiftArtifacts = swiftConsumer.indexOf(
    "Restore tracked Swift artifacts after debug validation",
  );
  const androidAppBundle = android.indexOf(
    "Build and verify a signed Android app bundle",
  );
  const restoreAndroidAar = android.indexOf(
    "Restore checked-in Android AAR after candidate validation",
  );
  const emitAndroidProof = android.indexOf("Emit Android proof fragment");
  assert.ok(androidAppBundle >= 0);
  assert.ok(restoreAndroidAar >= 0);
  assert.ok(androidAppBundle < restoreAndroidAar);
  assert.ok(restoreAndroidAar < emitAndroidProof);
  assert.match(
    android,
    /git restore --source=HEAD -- Vendor\/openburnbar-domain-core\.aar[\s\S]*git status --porcelain=v1 --untracked-files=all[\s\S]*exit 1/u,
  );
  const emitSwiftProof = swiftConsumer.indexOf(
    "Emit Swift consumer proof fragment",
  );
  assert.ok(restoreSwiftArtifacts >= 0);
  assert.ok(restoreSwiftArtifacts < emitSwiftProof);
  // The XCFramework is gitignored (.gitignore:20), so git restore cannot
  // touch it — the build step generates it fresh. The cleanup must remove
  // the generated XCFramework, restore only the tracked paths (Generated
  // bindings + swift.sha256), then fail on any remaining dirty path —
  // mirroring the Android AAR restore pattern.
  assert.match(
    swiftConsumer,
    /rm -rf -- Vendor\/OpenBurnBarDomainCore\.xcframework/u,
    "swift-consumer-contracts must remove the generated (gitignored) XCFramework, not git restore it",
  );
  assert.doesNotMatch(
    swiftConsumer,
    /git restore --source=HEAD --[\s\S]*Vendor\/OpenBurnBarDomainCore\.xcframework/u,
    "swift-consumer-contracts must not git restore the untracked/gitignored XCFramework (it fails)",
  );
  assert.match(
    swiftConsumer,
    /git restore --source=HEAD -- [\s\S]*OpenBurnBarCore\/Sources\/OpenBurnBarDomainCore\/Generated [\s\S]*crates\/openburnbar-domain-core\/artifact-provenance\/swift\.sha256/u,
    "swift-consumer-contracts must git restore only the tracked Generated bindings and swift.sha256",
  );
  assert.match(
    swiftConsumer,
    /git status --porcelain=v1 --untracked-files=all[\s\S]*exit 1/u,
    "swift-consumer-contracts must fail on any remaining dirty path after restore",
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

test("every proof-bound artifact is uploaded for protected signer revalidation", () => {
  const windowsUploadName =
    "name: domain-core-attestation-${{ matrix.artifact }}-${{ github.run_id }}-${{ github.run_attempt }}";
  const windowsUploadPath =
    "path: ${{ runner.temp }}/attestation-${{ matrix.artifact }}";
  for (const { id, jobId } of policy.requiredArtifacts) {
    const producer = workflowJob(core, jobId);
    if (jobId === "windows-native") {
      assert.ok(
        producer.includes(`artifact: ${id}`),
        `${jobId} must enumerate ${id}`,
      );
      assert.ok(
        producer.includes(windowsUploadName),
        `${jobId} must upload its matrix artifact for the signer`,
      );
      assert.ok(
        producer.includes(windowsUploadPath),
        `${jobId} must upload the staged matrix artifact directory`,
      );
      continue;
    }
    assert.ok(
      producer.includes(
        `name: domain-core-attestation-${id}-` +
          "${{ github.run_id }}-${{ github.run_attempt }}",
      ),
      `${jobId} must upload ${id} for the protected signer`,
    );
    assert.ok(
      producer.includes("path: ${{ runner.temp }}/attestation-" + id),
      `${jobId} must upload the staged ${id} directory`,
    );
  }
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
    /GH_TOKEN: \$\{\{ secrets\.DOMAIN_CORE_GOVERNANCE_READ_TOKEN \}\}/u,
  );
  assert.match(
    signer,
    /DOMAIN_CORE_GOVERNANCE_READ_TOKEN is required with repository Administration: read/u,
  );
  assert.doesNotMatch(
    workflowJob(signer, "protected-domain-core-signer").slice(
      workflowJob(signer, "protected-domain-core-signer").indexOf(
        "Require live protected default-branch controls",
      ),
      workflowJob(signer, "protected-domain-core-signer").indexOf(
        "Validate candidate and locate exact successful push run",
      ),
    ),
    /GH_TOKEN: \$\{\{ github\.token \}\}/u,
  );
  assert.match(
    signer,
    /actions\/workflows\/domain-core\.yml\/runs\?event=push/u,
  );
  assert.match(signer, /git merge-base --is-ancestor/u);
  assert.match(signer, /environments\/domain-core-promotion/u);
  assert.match(signer, /required_reviewers/u);
  assert.match(signer, /deployment-branch-policies/u);
  assert.match(signer, /verify-domain-core-protected-attestation\.mjs/u);
  assert.match(signer, /gh-api-with-retry\.sh --paginate --slurp/u);
  assert.doesNotMatch(
    workflowJob(signer, "protected-domain-core-signer"),
    /^\s+gh api /mu,
    "protected signer GitHub API reads must use the bounded retry wrapper",
  );
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
  assert.match(
    signer,
    /name: domain-core-protected-verification-\$\{\{ inputs\.candidate_commit \}\}[\s\S]*path: \$\{\{ runner\.temp \}\}\/candidate-bundle\/protected-verification\.json/u,
  );
  assert.match(
    hostingDeploy,
    /artifact_name="domain-core-protected-verification-\$\{CANDIDATE_COMMIT\}"/u,
  );
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
    /already live .* immutable Console deployment receipt is missing/u,
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
    /node scripts\/ci\/prepare-functions-runtime-package\.mjs[\s\S]*--functions-dir "\$stage\/functions"/u,
  );
  const prepareRuntimePackage = prepare.indexOf(
    "node scripts/ci/prepare-functions-runtime-package.mjs",
  );
  const artifactChecksum = prepare.indexOf(
    'xargs -0 sha256sum > "$RUNNER_TEMP/prepared-functions-SHA256SUMS"',
  );
  assert.ok(prepareRuntimePackage > 0);
  assert.ok(artifactChecksum > prepareRuntimePackage);
  assert.match(
    prepare,
    /- name: Prepare pinned Sentry CLI\n        if: steps\.tag\.outputs\.dry_run != 'true'/u,
  );

  assert.match(
    deploy,
    /needs: \[prepare-functions-deploy, authorize-domain-core-rollback\]/u,
  );
  assert.match(
    deploy,
    /needs\.authorize-domain-core-rollback\.result == 'success'/u,
  );
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
test("promotion-contracts executes native release workflow contract tests", () => {
  const job = workflowJob(core, "promotion-contracts");

  const timeout = job.match(/^    timeout-minutes: (\d+)$/mu);
  assert.ok(timeout, "promotion-contracts must declare a timeout");
  assert.ok(
    Number.parseInt(timeout[1], 10) >= 60,
    "promotion-contracts timeout must tolerate a degraded full-history checkout",
  );
  assert.match(
    job,
    /node --test \\\n(?:            [^\n]+ \\\n)*            scripts\/ci\/verify-domain-core-native-release-workflows\.test\.mjs \\/u,
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

test("promotion-contracts gives its trusted evaluator a bounded shallow checkout", () => {
  const job = workflowJob(core, "promotion-contracts");
  assert.match(job, /timeout-minutes: 60/u);
  assert.match(
    job,
    /Check out repository[\s\S]*?ref: \$\{\{ github\.event\.pull_request\.head\.sha \|\| github\.sha \}\}/u,
  );
  assert.match(
    job,
    /Check out trusted default-branch evaluator[\s\S]*?fetch-depth: 1[\s\S]*?sparse-checkout: scripts\/ci\/verify-domain-core-legacy-deletion\.py[\s\S]*?sparse-checkout-cone-mode: false/u,
  );
  assert.match(
    job,
    /ref: \$\{\{ github\.event\.pull_request\.base\.sha \|\| github\.event\.merge_group\.base_sha \|\| github\.sha \}\}/u,
    "merge-group governance must execute the evaluator from the protected base commit",
  );
  assert.match(
    job,
    /DOMAIN_CORE_BASE_REF: \$\{\{ github\.event\.pull_request\.base\.sha \|\| github\.event\.merge_group\.base_sha \|\| github\.event\.before \|\| '' \}\}/u,
    "merge-group governance must compare the candidate to the exact protected base",
  );
  assert.match(
    job,
    /DOMAIN_CORE_CANDIDATE_SHA: \$\{\{ github\.event\.pull_request\.head\.sha \|\| github\.sha \}\}[\s\S]*?--expected-candidate-commit "\$DOMAIN_CORE_CANDIDATE_SHA"/u,
  );
  assert.doesNotMatch(
    job,
    /--expected-candidate-commit "\$GITHUB_SHA"/u,
  );
});

test("swift-consumer-contracts builds the host domain-core XCFramework in release mode", () => {
  // Regression: the swift-consumer-contracts job must build the domain-core
  // XCFramework with DOMAIN_CORE_BUILD_PROFILE=release. A debug build links
  // the domain-core staticlib in debug, which collides with the debug
  // libsignal FFI staticlib and produces duplicate-symbol link failures in
  // the consumer contract tests. Release mode keeps the two artifacts in
  // distinct link units, so the Swift consumer contract lane stays green.
  const job = workflowJob(core, "swift-consumer-contracts");
  const buildStep = job.indexOf("Build host domain-core XCFramework");
  assert.notEqual(buildStep, -1, "Build host domain-core XCFramework step must exist");
  const stepBlock = job.slice(buildStep);
  // The env block for the build step must set release, not debug.
  assert.match(
    stepBlock,
    /env:\n\s*DOMAIN_CORE_BUILD_PROFILE: release\n/,
    "swift-consumer-contracts must build the XCFramework with DOMAIN_CORE_BUILD_PROFILE: release",
  );
  assert.doesNotMatch(
    stepBlock,
    /DOMAIN_CORE_BUILD_PROFILE: debug/,
    "swift-consumer-contracts must not build the XCFramework in debug mode",
  );
});
test("swift-consumer-contracts gates libsignal out to prevent duplicate Rust runtime symbols", () => {
  // Regression: two Rust staticlibs (domain-core xcframework + locally-built
  // libsignal_ffi) both embed Rust runtime objects. When linked into the same
  // SwiftPM test binary, the linker fails with `duplicate symbol '_rust_eh_personality'`.
  // The fix gates the local LibSignalClient Swift package out of the package graph
  // for the focused domain-core consumer job so only the domain-core Rust staticlib
  // is present. Full-app CI gates still exercise real libsignal with both archives.
  const job = workflowJob(core, "swift-consumer-contracts");
  const consumerStep = job.indexOf("Run Swift domain-core consumer contracts");
  assert.notEqual(consumerStep, -1, "Run Swift domain-core consumer contracts step must exist");
  const stepBlock = job.slice(consumerStep);
  assert.match(
    stepBlock,
    /OPENBURNBAR_DISABLE_LIBSIGNAL_SWIFT_PACKAGE:\s*"1"/,
    "swift-consumer-contracts must set OPENBURNBAR_DISABLE_LIBSIGNAL_SWIFT_PACKAGE=1 to prevent duplicate _rust_eh_personality",
  );
  // The test script must also export the gate when OPENBURNBAR_REQUIRE_DOMAIN_CORE_NATIVE is set.
  const swiftTestScript = readFileSync(
    new URL("../../scripts/test-openburnbar-swift.sh", import.meta.url),
    "utf8",
  );
  assert.match(
    swiftTestScript,
    /OPENBURNBAR_REQUIRE_DOMAIN_CORE_NATIVE.*OPENBURNBAR_DISABLE_LIBSIGNAL_SWIFT_PACKAGE=1/s,
    "test-openburnbar-swift.sh must export OPENBURNBAR_DISABLE_LIBSIGNAL_SWIFT_PACKAGE=1 when OPENBURNBAR_REQUIRE_DOMAIN_CORE_NATIVE is set",
  );
  // Package.swift must honor the env var to prune the local LibSignalClient package.
  const packageSwift = readFileSync(
    new URL("../../OpenBurnBarCore/Package.swift", import.meta.url),
    "utf8",
  );
  assert.match(
    packageSwift,
    /disableLibSignalSwiftPackage/,
    "Package.swift must declare the disableLibSignalSwiftPackage env gate",
  );
  assert.match(
    packageSwift,
    /hasLibSignalSwiftPackage\s*=\s*!disableLibSignalSwiftPackage/,
    "Package.swift must gate hasLibSignalSwiftPackage on !disableLibSignalSwiftPackage",
  );
  // The default path (without the gate) must still declare libsignal_dir so
  // prepare_libsignal_ffi works under `set -u` when the gate is not set.
  assert.match(
    swiftTestScript,
    /prepare_libsignal_ffi\(\)\s*\{\n\s*local libsignal_dir=/,
    "test-openburnbar-swift.sh prepare_libsignal_ffi must declare local libsignal_dir as its first local (set -u safety for the default path)",
  );
  // The LinuxCoreFoundationTests.swift exclude must key off the explicit
  // disableLibSignalSwiftPackage env var, NOT hasLibSignalSwiftPackage (which
  // is always false on Linux). On Linux, the file compiles against the
  // unavailable fallback stub (which provides sealPayload/openPayload) and
  // MUST run as part of the Linux core-foundation test floor.
  assert.match(
    packageSwift,
    /linuxCoreFoundationSignalTestExcludes:\s*\[String\]\s*=\s*disableLibSignalSwiftPackage\s*\?/,
    "Package.swift must scope linuxCoreFoundationSignalTestExcludes to disableLibSignalSwiftPackage, not hasLibSignalSwiftPackage (Linux regression)",
  );
  assert.doesNotMatch(
    packageSwift,
    /linuxCoreFoundationSignalTestExcludes.*hasLibSignalSwiftPackage/,
    "Package.swift must NOT key linuxCoreFoundationSignalTestExcludes off hasLibSignalSwiftPackage (would exclude the file on Linux where hasLibSignalSwiftPackage is always false)",
  );
});

test("swift-consumer-contracts skips Apple app spool on pull_request and merge_group", () => {
  // Measured MQ baseline (2026-08-12 pr-2051): app spool alone was ~47.68m of a
  // 58.7m swift-consumer-contracts job while AgentLens already rebuilt the same
  // OpenBurnBar app graph. PR/MQ keep DomainCore Core contracts + proof emit;
  // the focused spool selector stays on push/dispatch and in the nightly Full
  // Harness unfiltered app-xctest corpus.
  const job = workflowJob(core, "swift-consumer-contracts");
  const coreStep = job.indexOf("Run Swift domain-core consumer contracts");
  const spoolStep = job.indexOf("Run Apple shadow evidence spool contracts");
  const emitStep = job.indexOf("Emit Swift consumer proof fragment");
  assert.notEqual(coreStep, -1, "DomainCore consumer contracts step must exist");
  assert.notEqual(spoolStep, -1, "spool step must remain for push/dispatch coverage");
  assert.notEqual(emitStep, -1, "proof emit step must exist");
  assert.ok(coreStep < spoolStep && spoolStep < emitStep);

  const coreBlock = job.slice(coreStep, spoolStep);
  assert.match(
    coreBlock,
    /OPENBURNBAR_CORE_SWIFT_FILTER:\s*DomainCore/,
    "PR/MQ DomainCore filter must stay fail-closed",
  );
  assert.match(
    coreBlock,
    /OPENBURNBAR_REQUIRE_DOMAIN_CORE_NATIVE:\s*"1"/,
    "PR/MQ DomainCore native requirement must stay fail-closed",
  );
  assert.match(
    coreBlock,
    /cp "\$RUNNER_TEMP\/swift-consumer-core\.log"[\s\S]*"\$RUNNER_TEMP\/swift-consumer-contracts\.log"/,
    "proof suite log must be seeded from the Core log alone so PR/MQ emit succeeds without the spool",
  );

  const spoolBlock = job.slice(spoolStep, emitStep);
  assert.match(
    spoolBlock,
    /if:\s*github\.event_name != 'pull_request' && github\.event_name != 'merge_group'/,
    "Apple app spool must skip pull_request and merge_group",
  );
  assert.match(
    spoolBlock,
    /test-openburnbar-app\.sh[\s\S]*-only-testing:OpenBurnBarTests\/DomainCoreShadowEvidenceSpoolTests/,
    "push/dispatch must keep the focused DomainCoreShadowEvidenceSpoolTests selector",
  );
  assert.match(
    spoolBlock,
    /cat "\$RUNNER_TEMP\/swift-consumer-spool\.log"[\s\S]*>> "\$RUNNER_TEMP\/swift-consumer-contracts\.log"/,
    "push/dispatch must append the spool log into the proof suite report",
  );
  assert.doesNotMatch(
    spoolBlock,
    /cat "\$RUNNER_TEMP\/swift-consumer-core\.log"[\s\S]*"\$RUNNER_TEMP\/swift-consumer-spool\.log"[\s\S]*> "\$RUNNER_TEMP\/swift-consumer-contracts\.log"/,
    "proof log must not require concatenating core+spool before emit (PR/MQ has no spool file)",
  );

  assert.match(
    job,
    /--suite "swift-consumer-contracts=\$RUNNER_TEMP\/swift-consumer-contracts\.log"/,
    "proof fragment suite id/path must remain swift-consumer-contracts",
  );

  // Nightly Full Harness still runs the unfiltered app corpus that includes
  // DomainCoreShadowEvidenceSpoolTests (second coverage home alongside push).
  const harness = readFileSync(
    new URL("../../.github/workflows/openburnbar-pr-harness.yml", import.meta.url),
    "utf8",
  );
  const harnessApp = workflowJob(harness, "app-xctest");
  assert.match(
    harnessApp,
    /OPENBURNBAR_ENABLE_COVERAGE=YES \.\/scripts\/test-openburnbar-app\.sh/,
    "nightly Full Harness app-xctest must keep an unfiltered OpenBurnBarTests run",
  );
  assert.doesNotMatch(
    harnessApp,
    /OPENBURNBAR_APP_TEST_FILTERS=/,
    "nightly Full Harness must not bound away DomainCoreShadowEvidenceSpoolTests",
  );
});

// Extract a top-level trigger block under `on:` (e.g. `pull_request:`) from the
// workflow source. Mirrors workflowJob: find the two-space-indented key, then cut
// at the next sibling trigger key or the next top-level key (`concurrency:` etc.).
function workflowTrigger(source, name) {
  const start = source.indexOf(`  ${name}:\n`);
  assert.notEqual(start, -1, `missing workflow trigger ${name}`);
  const remainder = source.slice(start + 2);
  const next = remainder.search(/^  [A-Za-z0-9_-]+:\n/mu);
  return next === -1
    ? source.slice(start)
    : source.slice(start, start + 2 + next);
}

test("pull_request trigger is unfiltered and the classifier owns the Hermes adapter", () => {
  const trigger = workflowTrigger(core, "pull_request");
  assert.doesNotMatch(trigger, /^    paths:/mu);
  const classifier = readFileSync(
    new URL("./classify-ci-impact.mjs", import.meta.url),
    "utf8",
  );
  assert.match(classifier, /hermes-platform-burnbar/u);
});

test("pull_request trigger cannot omit branch-control inputs", () => {
  assert.doesNotMatch(workflowTrigger(core, "pull_request"), /^    paths:/mu);
});

test("main push trigger is unfiltered so every exact-main commit gets a source proof", () => {
  assert.doesNotMatch(workflowTrigger(core, "push"), /^    paths:/mu);
});

test("domain-core-pr-gate needs both python contract jobs before the aggregate count", () => {
  // Regression: the pr-gate aggregate omitted python-mcp-cloudvault-contracts and
  // python-hermes-contracts, so their failures could not block the gate.
  const gate = workflowJob(core, "domain-core-pr-gate");
  assert.match(
    gate,
    /^      - python-mcp-cloudvault-contracts$/mu,
    "domain-core-pr-gate.needs must include python-mcp-cloudvault-contracts",
  );
  assert.match(
    gate,
    /^      - python-hermes-contracts$/mu,
    "domain-core-pr-gate.needs must include python-hermes-contracts",
  );
});

test("domain-core-pr-gate aggregate count is 15 after adding both python contract needs", () => {
  // Regression: the jq assertion counted 13 jobs, but the gate now aggregates 15
  // (added python-mcp-cloudvault-contracts and python-hermes-contracts). A stale
  // count would let the gate pass even when the two python jobs are missing.
  const gate = workflowJob(core, "domain-core-pr-gate");
  assert.match(
    gate,
    /to_entries \| length == 15 and all\(\.value\.result == "success"\)/u,
    'domain-core-pr-gate must assert to_entries | length == 15 (was 13 before the two python contract jobs were added)',
  );
});

test("domain-core-pr-gate trusts the merge-group base and budgets both full-history checkouts", () => {
  const gate = workflowJob(core, "domain-core-pr-gate");
  const timeout = gate.match(/^    timeout-minutes: (\d+)$/mu);
  assert.ok(timeout, "domain-core-pr-gate must declare a timeout");
  assert.ok(
    Number.parseInt(timeout[1], 10) >= 120,
    "domain-core-pr-gate must leave at least two hours for degraded full-history checkouts and absence verification",
  );
  assert.match(
    gate,
    /Check out trusted default-branch absence evaluator[\s\S]*?ref: \$\{\{ github\.event\.pull_request\.base\.sha \|\| github\.event\.merge_group\.base_sha \|\| github\.sha \}\}/u,
    "merge-group absence verification must run from the protected base evaluator",
  );
  assert.match(
    gate,
    /--base-ref "\$\{\{ github\.event\.pull_request\.base\.sha \|\| github\.event\.merge_group\.base_sha \|\| github\.event\.before \}\}"/u,
    "the bootstrap fallback must receive the exact merge-group base",
  );
});

// Regression (PR #1820 exact-head review): the rust-and-csharp job checked out
// the synthetic PR merge SHA on pull_request events (the default checkout with
// no `ref:`) and bound OPENBURNBAR_DOMAIN_CORE_CANDIDATE_COMMIT straight to
// `${{ github.sha }}`. On a pull_request, GITHUB_SHA is the ephemeral merge
// commit GitHub fabricates by merging the PR head into the base — not the PR
// head itself. An artifact built from that checkout carries the merge SHA as
// its identity, so the native-load identity chain binds to a commit no branch
// points at. The fix mirrors the Android/apple-native-smoke contract: pin the
// checkout to `github.event.pull_request.head.sha || github.sha` (PR head on
// pull_request, exact pushed commit on push/dispatch) and resolve the
// canonical candidate commit before any identity-binding step.
test("rust-and-csharp checks out the exact PR head on pull_request and the pushed SHA on push, matching Android", () => {
  const rust = workflowJob(core, "rust-and-csharp");
  // Exactly one Check out repository step, and it must pin the ref to the PR
  // head on pull_request, falling back to github.sha on push/dispatch.
  const checkoutMatches = [...rust.matchAll(/^      - name: Check out repository$/gmu)];
  assert.equal(
    checkoutMatches.length,
    1,
    "rust-and-csharp must have exactly one Check out repository step (the pre-fix had a malformed duplicate)",
  );
  assert.match(
    rust,
    /^      - name: Check out repository\n        uses: actions\/checkout@[0-9a-f]+\s*# v[0-9.]+\n        with:\n          persist-credentials: false\n          ref: \$\{\{ github\.event\.pull_request\.head\.sha \|\| github\.sha \}\}\n/mu,
    "rust-and-csharp checkout must ref github.event.pull_request.head.sha || github.sha so PR builds bind identity to the real PR head, not the synthetic merge SHA",
  );
});

test("rust-and-csharp resolves the canonical candidate commit before any identity-binding step, matching Android", () => {
  const rust = workflowJob(core, "rust-and-csharp");
  assert.match(
    rust,
    /^      - name: Resolve canonical candidate commit\n        id: candidate\n        run: node scripts\/ci\/canonical-candidate-commit\.mjs\n/mu,
    "rust-and-csharp must run canonical-candidate-commit.mjs (id: candidate) like the Android job, so the candidate commit is the PR head on pull_request and GITHUB_SHA on push",
  );
  // The resolver must precede the first identity-binding step. On pull_request,
  // canonical-candidate-commit.mjs throws rather than fall back to the merge
  // SHA, so any binding that runs before it would embed the merge SHA.
  const resolver = rust.indexOf("Resolve canonical candidate commit");
  const firstBinding = rust.indexOf("OPENBURNBAR_DOMAIN_CORE_CANDIDATE_COMMIT");
  assert.ok(resolver >= 0, "missing canonical candidate resolver step");
  assert.ok(firstBinding >= 0, "missing OPENBURNBAR_DOMAIN_CORE_CANDIDATE_COMMIT binding");
  assert.ok(
    resolver < firstBinding,
    "Resolve canonical candidate commit must run before the first OPENBURNBAR_DOMAIN_CORE_CANDIDATE_COMMIT binding",
  );
});

test("rust-and-csharp preserves the Rust toolchain step after the PR-head checkout fix", () => {
  const rust = workflowJob(core, "rust-and-csharp");
  assert.match(
    rust,
    /^      - name: Install Rust toolchain\n        uses: dtolnay\/rust-toolchain@[0-9a-f]+\s*# v1\n        with:\n          toolchain: "1\.96\.0"[^\n]*\n          components: rustfmt,clippy\n/mu,
    "rust-and-csharp must keep the Install Rust toolchain step (dtolnay/rust-toolchain) — the pre-fix edit accidentally dropped it",
  );
});

test("rust-and-csharp binds every candidate identity to the resolved canonical commit, never to the synthetic merge SHA", () => {
  const rust = workflowJob(core, "rust-and-csharp");
  // Pre-fix: every OPENBURNBAR_DOMAIN_CORE_CANDIDATE_COMMIT / DOMAIN_CORE_CANDIDATE_COMMIT
  // env and every --expected-candidate-commit flag bound to github.sha / $GITHUB_SHA.
  // On pull_request that is the ephemeral merge commit, so the attested identity
  // would point at no real commit. Post-fix they must all read the resolved
  // steps.candidate.outputs.candidate_commit (PR head on pull_request, GITHUB_SHA
  // on push), matching the apple-native-smoke contract on steps.candidate.outputs.commit.
  const shaBindings = [...rust.matchAll(/OPENBURNBAR_DOMAIN_CORE_CANDIDATE_COMMIT: \$\{\{ github\.sha \}\}|DOMAIN_CORE_CANDIDATE_COMMIT: \$\{\{ github\.sha \}\}/gu)];
  assert.equal(
    shaBindings.length,
    0,
    "rust-and-csharp must not bind OPENBURNBAR_DOMAIN_CORE_CANDIDATE_COMMIT or DOMAIN_CORE_CANDIDATE_COMMIT to github.sha (synthetic merge SHA on pull_request)",
  );
  const cliShaBindings = [...rust.matchAll(/--expected-candidate-commit "\$GITHUB_SHA"/gu)];
  assert.equal(
    cliShaBindings.length,
    0,
    'rust-and-csharp must not pass --expected-candidate-commit "$GITHUB_SHA" (synthetic merge SHA on pull_request) to resolve/verify/proof-fragment',
  );
  // At least one candidate binding exists and reads the resolved commit.
  assert.match(
    rust,
    /OPENBURNBAR_DOMAIN_CORE_CANDIDATE_COMMIT: \$\{\{ steps\.candidate\.outputs\.candidate_commit \}\}/u,
    "rust-and-csharp OPENBURNBAR_DOMAIN_CORE_CANDIDATE_COMMIT must read steps.candidate.outputs.candidate_commit (resolved PR head / push SHA)",
  );
});

test("rust-and-csharp has no duplicate or dangling Check out repository step from the PR-head fix", () => {
  const rust = workflowJob(core, "rust-and-csharp");
  // The malformed intermediate edit left a dangling "Install Rust toolchain"
  // name with no body, immediately followed by a second "Check out repository".
  // The canonical fix has exactly one checkout (asserted above) and no
  // name-only step stubs.
  assert.doesNotMatch(
    rust,
    /^      - name: Install Rust toolchain\n      - name: Check out repository/mu,
    "rust-and-csharp must not carry the dangling Install Rust toolchain stub that the malformed fix introduced",
  );
  assert.doesNotMatch(
    rust,
    /^      - name: Check out repository[\s\S]*      - name: Check out repository/mu,
    "rust-and-csharp must not contain two Check out repository steps",
  );
});
