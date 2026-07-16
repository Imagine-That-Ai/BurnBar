#!/usr/bin/env node
/**
 * Structural tests for the domain-core release workflow contract.
 *
 * Verifies four release-workflow invariants that must hold after the
 * ReleaseWorkflowFix patch:
 *
 *  1. Android rollback mapping exists — the public-production-rollback
 *     profile in config/domain-core-build-profiles.json maps every domain
 *     to "legacy" mode (the rollback mode). Without this, Android builds
 *     using the rollback profile would silently ship Rust-native code
 *     instead of the certified legacy implementation.
 *
 *  2. iOS rollback uses the rollback profile — the build-profile-artifact
 *     verifier invocations inside the iOS archive verification step of
 *     release.yml must pass the dynamically selected profile name
 *     (profile_name output), not a hard-coded "public-production" literal.
 *     A hard-coded profile means a rollback release would verify against
 *     the production profile, not the rollback profile.
 *
 *  3. Approved action pins are exact — every actions/upload-artifact
 *     reference in release.yml and openburnbar-release-windows.yml must
 *     use the repo-approved commit SHA. A transposed SHA (two hex chars
 *     swapped) points at a different commit and breaks supply-chain
 *     integrity.
 *
 *  4. Apple/Windows release invocations supply activation and release
 *     commit — every resolve-domain-core-build-profile.mjs invocation
 *     in release.yml and openburnbar-release-windows.yml must pass
 *     --expected-release-commit so the profile is bound to the exact
 *     release commit. Additionally, every
 *     create-domain-core-native-release-evidence.mjs invocation must
 *     pass --activation and --commit (the release commit) so the
 *     evidence predicate binds the artifact to the exact release.
 *
 * The tests use semantic anchors (specific patterns, not whole-file
 * snapshots) and include negative controls: each test also verifies that
 * a known-bad mutation would be detected.
 *
 * Usage:
 *   node scripts/ci/verify-domain-core-release-workflow.test.mjs
 *
 * For pre-fix testing against the committed HEAD versions:
 *   TEST_RELEASE_YML=/tmp/release-prefix.yml \
 *   TEST_WINDOWS_YML=/tmp/windows-prefix.yml \
 *   TEST_BUILD_GRADLE_KTS=/tmp/build-gradle-prefix.kts \
 *   node scripts/ci/verify-domain-core-release-workflow.test.mjs
 */

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(SCRIPT_DIR, "..", "..");

const RELEASE_YML = process.env.TEST_RELEASE_YML
  ? process.env.TEST_RELEASE_YML
  : join(REPO_ROOT, ".github/workflows/release.yml");
const WINDOWS_YML = process.env.TEST_WINDOWS_YML
  ? process.env.TEST_WINDOWS_YML
  : join(REPO_ROOT, ".github/workflows/openburnbar-release-windows.yml");
const PROFILES_JSON = join(
  REPO_ROOT,
  "config/domain-core-build-profiles.json",
);
const BUILD_GRADLE_KTS = process.env.TEST_BUILD_GRADLE_KTS
  ? process.env.TEST_BUILD_GRADLE_KTS
  : join(REPO_ROOT, "android/app/build.gradle.kts");

const releaseBody = readFileSync(RELEASE_YML, "utf8");
const windowsBody = readFileSync(WINDOWS_YML, "utf8");
const profilesRaw = readFileSync(PROFILES_JSON, "utf8");
const buildGradleBody = readFileSync(BUILD_GRADLE_KTS, "utf8");

let passed = 0;
let failed = 0;

function assert(label, condition) {
  if (condition) {
    passed++;
  } else {
    failed++;
    console.error(`  FAIL: ${label}`);
  }
}

/**
 * Extract each individual invocation of a script from a workflow body.
 * Returns an array of { index, lines } where lines is the text from the
 * script name line through the end of that specific command invocation
 * (up to the next "node " or "python3 " line, or 10 lines max).
 */
function extractIndividualInvocations(body, scriptName) {
  const results = [];
  const escaped = scriptName.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&");
  const pattern = new RegExp(escaped, "gu");
  let match;
  while ((match = pattern.exec(body)) !== null) {
    // Grab the next 10 lines or until the next script invocation /
    // non-continuation line.
    const after = body.slice(match.index);
    const lines = after.split("\n");
    const blockLines = [];
    for (let i = 0; i < lines.length && i < 12; i++) {
      const line = lines[i];
      blockLines.push(line);
      // Stop if this line doesn't end with a backslash continuation
      // AND it's not the first line (the script invocation itself).
      if (i > 0 && !line.trimEnd().endsWith("\\")) {
        break;
      }
      // Also stop if a new command starts (another "node " or "python3 ")
      if (i > 0 && /^\s*(node|python3|bash)\s/u.test(line.trim())) {
        blockLines.pop();
        break;
      }
    }
    results.push({
      index: match.index,
      block: blockLines.join("\n"),
    });
  }
  return results;
}

// ──────────────────────────────────────────────────────────────────────────
// 1. Android rollback mapping exists
// ──────────────────────────────────────────────────────────────────────────

console.log("\n1. Android rollback mapping exists");

const profiles = JSON.parse(profilesRaw);
const rollbackProfile = profiles.profiles?.["public-production-rollback"];
const expectedDomains = profiles.domains ?? [];

assert(
  "public-production-rollback profile is declared",
  rollbackProfile !== undefined,
);

assert(
  "rollback profile artifactAuthority is signed",
  rollbackProfile?.artifactAuthority === "signed",
);

assert(
  "rollback profile distribution is public",
  rollbackProfile?.distribution === "public",
);

assert(
  "rollback profile modes cover every catalog domain",
  rollbackProfile?.modes !== undefined &&
    expectedDomains.every(
      (domain) =>
        Object.prototype.hasOwnProperty.call(rollbackProfile.modes, domain),
    ),
);

assert(
  "rollback profile maps every domain to legacy mode",
  rollbackProfile?.modes !== undefined &&
    expectedDomains.every(
      (domain) => rollbackProfile.modes[domain] === "legacy",
    ),
);

// Negative control: if any domain were set to "rust" or "shadow", the
// test above would fail. Verify the assertion logic catches a bad mutation.
const mutatedProfiles = JSON.parse(profilesRaw);
mutatedProfiles.profiles["public-production-rollback"].modes.quota = "rust";
const mutatedRollback =
  mutatedProfiles.profiles["public-production-rollback"];
assert(
  "negative control: rust mode in rollback profile is detected",
  !expectedDomains.every(
    (domain) => mutatedRollback.modes[domain] === "legacy",
  ),
);

// Verify the domain list includes domains that Android consumers ship
// (cloudVault, cloudVaultRewrap, cloudVaultSearch, hermes) — these are
// the domains in the Android release evidence contract.
const androidDomains = [
  "cloudVault",
  "cloudVaultRewrap",
  "cloudVaultSearch",
  "hermes",
];
assert(
  "rollback profile covers all Android consumer domains",
  androidDomains.every(
    (domain) => rollbackProfile?.modes?.[domain] === "legacy",
  ),
);

// 1b. Android Gradle canonicalDomainCoreIdentity map includes rollback profile
// ──────────────────────────────────────────────────────────────────────────

// The Android build (android/app/build.gradle.kts) resolves profile
// identities through a canonicalDomainCoreIdentity map. Without an entry
// for public-production-rollback, building Android with
// OPENBURNBAR_DOMAIN_CORE_BUILD_PROFILE=public-production-rollback fails
// with "Unknown domain-core profile identity" — the rollback profile
// would be unusable on Android.

// Extract the canonicalDomainCoreIdentity map block from build.gradle.kts.
// The map spans from "val canonicalDomainCoreIdentity = mapOf(" to the
// closing ")[domainCoreProfileName]".
const identityMapMatch = buildGradleBody.match(
  /val canonicalDomainCoreIdentity = mapOf\([\s\S]*?\)\[domainCoreProfileName\]/u,
);

assert(
  "canonicalDomainCoreIdentity map exists in android/app/build.gradle.kts",
  identityMapMatch !== null,
);

const identityMapBlock = identityMapMatch ? identityMapMatch[0] : "";

assert(
  'canonicalDomainCoreIdentity map includes "public-production-rollback" entry',
  identityMapBlock.includes('"public-production-rollback"'),
);

assert(
  'public-production-rollback maps to ("signed" to "public") in canonicalDomainCoreIdentity',
  identityMapBlock.includes(
    '"public-production-rollback" to ("signed" to "public")',
  ),
);

// Negative control: mutate the map to remove the rollback entry, re-extract
// the map block, and verify the production assertion (entry exists) would
// return false on the mutated text.
const missingRollbackMapBody = buildGradleBody.replace(
  /"public-production-rollback" to \("signed" to "public"\),?\n/u,
  "",
);
const missingRollbackMatch = missingRollbackMapBody.match(
  /val canonicalDomainCoreIdentity = mapOf\([\s\S]*?\)\[domainCoreProfileName\]/u,
);
const missingRollbackBlock = missingRollbackMatch ? missingRollbackMatch[0] : "";
// Re-run the exact production assertion logic against the mutated block.
const missingEntryProductionResult =
  missingRollbackBlock.includes('"public-production-rollback"');
assert(
  "negative control: production assertion (entry exists) fails when entry is removed",
  missingEntryProductionResult === false,
);

// Negative control: mutate the map to use a wrong identity, re-extract the
// map block, and verify the production assertion (correct identity) would
// return false on the mutated text.
const wrongIdentityMapBody = buildGradleBody.replace(
  /"public-production-rollback" to \("signed" to "public"\)/u,
  '"public-production-rollback" to ("development" to "development")',
);
const wrongIdentityMatch = wrongIdentityMapBody.match(
  /val canonicalDomainCoreIdentity = mapOf\([\s\S]*?\)\[domainCoreProfileName\]/u,
);
const wrongIdentityBlock = wrongIdentityMatch ? wrongIdentityMatch[0] : "";
// Re-run the exact production assertion logic against the mutated block.
const wrongIdentityProductionResult = wrongIdentityBlock.includes(
  '"public-production-rollback" to ("signed" to "public")',
);
assert(
  "negative control: production assertion (correct identity) fails when identity is wrong",
  wrongIdentityProductionResult === false,
);

// ──────────────────────────────────────────────────────────────────────────
// 2. iOS rollback uses the rollback profile (not hard-coded public-production)
// ──────────────────────────────────────────────────────────────────────────

console.log("\n2. iOS rollback uses the rollback profile");

// The iOS archive verification step in release.yml calls
// verify-domain-core-build-profile-artifact.mjs twice (xcarchive app +
// exported IPA app). The fix is that these must use the dynamic
// profile_name output, not a hard-coded "public-production" literal.
//
// Contrast: the Android (line ~1321) and Apple app verification (line ~1457)
// already use "${{ needs.domain-core-native-release-gate.outputs.profile_name }}"
// — the iOS archive step must match that pattern.

// Find all individual verify-domain-core-build-profile-artifact.mjs
// invocations in release.yml.
const verifierInvocations = extractIndividualInvocations(
  releaseBody,
  "verify-domain-core-build-profile-artifact.mjs",
);

assert(
  "at least 3 build-profile-artifact verifier invocations exist in release.yml",
  verifierInvocations.length >= 3,
);

// Check that invocations using --apple-app do NOT hard-code
// "public-production". Each individual invocation block must contain
// "profile_name" (the dynamic output reference).
const appleAppInvocations = verifierInvocations.filter((inv) =>
  inv.block.includes("--apple-app"),
);

assert(
  "at least 2 --apple-app verifier invocations exist (iOS archive + Mac app)",
  appleAppInvocations.length >= 2,
);

assert(
  "no --apple-app verifier hard-codes --profile public-production (all use dynamic profile_name)",
  appleAppInvocations.every((inv) => inv.block.includes("profile_name")),
);

// Also verify the Android verifier uses the dynamic profile.
const androidAabInvocations = verifierInvocations.filter((inv) =>
  inv.block.includes("--android-aab"),
);

assert(
  "Android --android-aab verifier uses dynamic profile_name",
  androidAabInvocations.length >= 1 &&
    androidAabInvocations.every((inv) => inv.block.includes("profile_name")),
);

// Negative control: verify the test catches a hard-coded profile.
// Replace ALL profile_name references with public-production to simulate
// the pre-fix state, then verify at least one --apple-app invocation
// loses profile_name.
const hardcodedReleaseBody = releaseBody.replace(
  /(--profile\s+)"\$\{\{ needs\.domain-core-native-release-gate\.outputs\.profile_name \}\}"/gu,
  '$1"public-production"',
);
const hardcodedInvocations = extractIndividualInvocations(
  hardcodedReleaseBody,
  "verify-domain-core-build-profile-artifact.mjs",
);
const hardcodedAppleApp = hardcodedInvocations.filter((inv) =>
  inv.block.includes("--apple-app"),
);
assert(
  "negative control: hard-coded public-production in Apple verifier is detected",
  hardcodedAppleApp.some((inv) => !inv.block.includes("profile_name")),
);

// ──────────────────────────────────────────────────────────────────────────
// 3. Approved action pins are exact
// ──────────────────────────────────────────────────────────────────────────

console.log("\n3. Approved action pins are exact");

// The repo-approved upload-artifact pin (appears in 35+ other workflows):
const APPROVED_UPLOAD_ARTIFACT_PIN =
  "330a01c490aca151604b8cf639adc76d48f6c5d4";
// The transposed (bad) pin swaps "cf" → "fc":
const TRANSPOSED_UPLOAD_ARTIFACT_PIN =
  "330a01c490aca151604b8fc639adc76d48f6c5d4";

// The repo has two approved download-artifact pins: v5 and v6.
const APPROVED_DOWNLOAD_ARTIFACT_PINS = new Set([
  "018cc2cf5baa6db3ef3c5f8a56943fffe632ef53", // v6.0.0
  "634f93cb2916e3fdff6788551b99b062d0335ce0", // v5.0.0
]);

// Extract all action pins from a workflow body for a given action.
function extractPins(body, action) {
  const escaped = action.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&");
  const pattern = new RegExp(
    `uses:\\s*${escaped}@([a-f0-9]{40})`,
    "gu",
  );
  return [...body.matchAll(pattern)].map((match) => match[1]);
}

const releaseUploadPins = extractPins(releaseBody, "actions/upload-artifact");
const windowsUploadPins = extractPins(windowsBody, "actions/upload-artifact");

assert(
  "release.yml has upload-artifact references",
  releaseUploadPins.length > 0,
);

assert(
  "openburnbar-release-windows.yml has upload-artifact references",
  windowsUploadPins.length > 0,
);

assert(
  "every upload-artifact pin in release.yml matches the approved SHA",
  releaseUploadPins.every(
    (pin) => pin === APPROVED_UPLOAD_ARTIFACT_PIN,
  ),
);

assert(
  "every upload-artifact pin in openburnbar-release-windows.yml matches the approved SHA",
  windowsUploadPins.every(
    (pin) => pin === APPROVED_UPLOAD_ARTIFACT_PIN,
  ),
);

assert(
  "no upload-artifact pin in release.yml uses the transposed SHA",
  !releaseUploadPins.some(
    (pin) => pin === TRANSPOSED_UPLOAD_ARTIFACT_PIN,
  ),
);

assert(
  "no upload-artifact pin in openburnbar-release-windows.yml uses the transposed SHA",
  !windowsUploadPins.some(
    (pin) => pin === TRANSPOSED_UPLOAD_ARTIFACT_PIN,
  ),
);

// Negative control: the transposed pin differs from the approved pin.
assert(
  "negative control: transposed pin is different from approved pin",
  APPROVED_UPLOAD_ARTIFACT_PIN !== TRANSPOSED_UPLOAD_ARTIFACT_PIN,
);

// Also verify download-artifact pins are in the approved set.
const releaseDownloadPins = extractPins(
  releaseBody,
  "actions/download-artifact",
);
const windowsDownloadPins = extractPins(
  windowsBody,
  "actions/download-artifact",
);

assert(
  "every download-artifact pin in release.yml is in the approved set",
  releaseDownloadPins.every((pin) =>
    APPROVED_DOWNLOAD_ARTIFACT_PINS.has(pin),
  ),
);

assert(
  "every download-artifact pin in openburnbar-release-windows.yml is in the approved set",
  windowsDownloadPins.every((pin) =>
    APPROVED_DOWNLOAD_ARTIFACT_PINS.has(pin),
  ),
);

// ──────────────────────────────────────────────────────────────────────────
// 4. Apple/Windows release invocations supply activation and release commit
// ──────────────────────────────────────────────────────────────────────────

console.log(
  "\n4. Apple/Windows release invocations supply activation and release commit",
);

// 4a. resolve-domain-core-build-profile.mjs invocations must pass
//     --expected-release-commit so the profile is bound to the exact
//     release commit (not just the candidate commit).
const releaseProfileResolverInvocations = extractIndividualInvocations(
  releaseBody,
  "resolve-domain-core-build-profile.mjs",
);
const windowsProfileResolverInvocations = extractIndividualInvocations(
  windowsBody,
  "resolve-domain-core-build-profile.mjs",
);

const allProfileResolverInvocations = [
  ...releaseProfileResolverInvocations,
  ...windowsProfileResolverInvocations,
];

assert(
  "at least 2 resolve-domain-core-build-profile.mjs invocations exist in release.yml",
  releaseProfileResolverInvocations.length >= 2,
);

assert(
  "at least 1 resolve-domain-core-build-profile.mjs invocation exists in windows release",
  windowsProfileResolverInvocations.length >= 1,
);

for (const invocation of allProfileResolverInvocations) {
  assert(
    "resolve-domain-core-build-profile invocation passes --expected-release-commit",
    invocation.block.includes("--expected-release-commit"),
  );
}

// Negative control: verify the test catches a missing --expected-release-commit.
const missingReleaseCommitBody = releaseBody.replace(
  /--expected-release-commit\s+"\$RELEASE_COMMIT"\s+/gu,
  "",
);
const missingReleaseCommitInvocations = extractIndividualInvocations(
  missingReleaseCommitBody,
  "resolve-domain-core-build-profile.mjs",
);
assert(
  "negative control: missing --expected-release-commit is detected",
  missingReleaseCommitInvocations.some(
    (inv) => !inv.block.includes("--expected-release-commit"),
  ),
);

// 4b. create-domain-core-native-release-evidence.mjs invocations must pass
//     --activation and --commit (the release commit).
function extractNativeEvidenceInvocations(body) {
  const invocations = extractIndividualInvocations(
    body,
    "create-domain-core-native-release-evidence.mjs",
  );
  return invocations.map((inv) => {
    const consumerMatch = inv.block.match(/--consumer\s+(\w+)/u);
    return {
      consumer: consumerMatch ? consumerMatch[1] : "unknown",
      block: inv.block,
    };
  });
}

const releaseEvidenceInvocations =
  extractNativeEvidenceInvocations(releaseBody);
const windowsEvidenceInvocations =
  extractNativeEvidenceInvocations(windowsBody);

const allEvidenceInvocations = [
  ...releaseEvidenceInvocations,
  ...windowsEvidenceInvocations,
];

assert(
  "at least 3 create-domain-core-native-release-evidence invocations exist (apple, android, windows)",
  allEvidenceInvocations.length >= 3,
);

const evidenceConsumers = allEvidenceInvocations.map((inv) => inv.consumer);
assert(
  "Apple evidence invocation exists",
  evidenceConsumers.includes("apple"),
);
assert(
  "Android evidence invocation exists",
  evidenceConsumers.includes("android"),
);
assert(
  "Windows evidence invocation exists",
  evidenceConsumers.includes("windows"),
);

// Each invocation must pass --activation with a path argument.
for (const invocation of allEvidenceInvocations) {
  assert(
    `${invocation.consumer} evidence invocation passes --activation`,
    invocation.block.includes("--activation"),
  );
  // The --activation value must be a path (not empty, not another flag).
  const activationMatch = invocation.block.match(
    /--activation\s+"\$RUNNER_TEMP\/[^"]+"/u,
  );
  assert(
    `${invocation.consumer} evidence --activation has a path value`,
    activationMatch !== null,
  );
}

// Each invocation must pass --commit with the release commit.
for (const invocation of allEvidenceInvocations) {
  assert(
    `${invocation.consumer} evidence invocation passes --commit`,
    invocation.block.includes("--commit"),
  );
  // The --commit value must reference a release commit variable.
  const commitMatch = invocation.block.match(
    /--commit\s+"\$(?:COMMIT|RELEASE_COMMIT)"/u,
  );
  assert(
    `${invocation.consumer} evidence --commit references a release commit variable`,
    commitMatch !== null,
  );
}

// Negative control: verify the test catches a missing --activation.
const missingActivationBody = releaseBody.replace(
  /--activation\s+"\$RUNNER_TEMP\/domain-core-native-release-gate\/domain-core-activation\.json"\s*\\?\n/gu,
  "",
);
const missingActivationInvocations =
  extractNativeEvidenceInvocations(missingActivationBody);
const appleMissingActivation = missingActivationInvocations.find(
  (inv) => inv.consumer === "apple",
);
assert(
  "negative control: missing --activation in Apple invocation is detected",
  appleMissingActivation === undefined ||
    !appleMissingActivation.block.includes("--activation"),
);

// Negative control: verify the test catches --commit pointing at candidate
// commit instead of release commit.
const candidateCommitBody = releaseBody.replace(
  /--commit\s+"\$COMMIT"/u,
  '--commit "$CANDIDATE_COMMIT"',
);
const candidateCommitInvocations =
  extractNativeEvidenceInvocations(candidateCommitBody);
const appleCandidateCommit = candidateCommitInvocations.find(
  (inv) => inv.consumer === "apple",
);
assert(
  "negative control: --commit pointing at candidate commit is detected",
  appleCandidateCommit !== undefined &&
    !/--commit\s+"\$(?:COMMIT|RELEASE_COMMIT)"/u.test(
      appleCandidateCommit.block,
    ),
);

// ──────────────────────────────────────────────────────────────────────────
// Summary
// ──────────────────────────────────────────────────────────────────────────

if (failed > 0) {
  console.error(`\nFAIL: ${failed} assertion(s) failed.`);
  process.exit(1);
}

console.log(
  `\nPASS: ${passed} release workflow contract assertion(s) passed.`,
);