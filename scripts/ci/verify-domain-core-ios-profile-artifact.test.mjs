#!/usr/bin/env node
/**
 * Contract tests for the iOS domain-core build-profile artifact forwarding
 * and verification path (PR #1820 exact-head review defect).
 *
 * These tests defend two observable contracts:
 *
 *  1. The selected `public-production-rollback` profile is FORWARDED through
 *     `release.yml` -> the reusable `domain-core-ios-release-evidence.yml`
 *     workflow and consumed by every iOS verification/receipt command, rather
 *     than being hard-coded to `public-production`. (Static workflow contract:
 *     production behavior here IS the workflow text.)
 *
 *  2. `verify-domain-core-build-profile-artifact.mjs --apple-app` accepts an
 *     activation checkout where HEAD is the activation commit P while the
 *     expected candidate is an ANCESTOR commit C != P, and the signed artifact
 *     plist matches the activation-derived metadata. Wrong candidate C, wrong
 *     activation P, and wrong profile all fail closed. (Behavioral subprocess
 *     contract against a synthetic git worktree + real plutil plist.)
 *
 * Red on the pre-fix behavior (hard-coded `public-production`, HEAD==C only);
 * green after the fix. Tests only.
 */

import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import {
  mkdtempSync,
  mkdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

import { resolveDomainCoreBuildProfile } from "../lib/domain-core-build-profile.mjs";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(SCRIPT_DIR, "..", "..");

const RELEASE_YML = join(REPO_ROOT, ".github/workflows/release.yml");
const IOS_EVIDENCE_YML = join(
  REPO_ROOT,
  ".github/workflows/domain-core-ios-release-evidence.yml",
);
const PROFILES_JSON = join(REPO_ROOT, "config/domain-core-build-profiles.json");
const VERIFIER_REL = "scripts/ci/verify-domain-core-build-profile-artifact.mjs";
const VERIFIER_SUPPORT_RELS = [
  VERIFIER_REL,
  "scripts/lib/domain-core-activation.mjs",
  "scripts/lib/domain-core-artifact-profile.mjs",
  "scripts/lib/domain-core-build-profile.mjs",
  "scripts/lib/domain-core-candidate-receipt.mjs",
  "scripts/lib/domain-core-release-evidence.mjs",
];

const releaseBody = readFileSync(RELEASE_YML, "utf8");
const iosEvidenceBody = readFileSync(IOS_EVIDENCE_YML, "utf8");
const catalog = JSON.parse(readFileSync(PROFILES_JSON, "utf8"));

// ---------------------------------------------------------------------------
// Workflow static contract: the selected rollback profile is forwarded
// end-to-end and consumed by every iOS verifier/receipt command.
// ---------------------------------------------------------------------------

/**
 * Extract each individual invocation of a named node script from a workflow
 * body. Mirrors the helper in verify-domain-core-release-workflow.test.mjs so
 * each `node scripts/ci/<name>` block is evaluated in isolation. Returns
 * `{ block, line }` for every invocation.
 */
function extractInvocations(body, scriptName) {
  const invocations = [];
  const lines = body.split("\n");
  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i];
    const match = line.match(/^(.*?\bnode\s+)(scripts\/ci\/[^"'\s]+)(.*)$/);
    if (match && match[2].endsWith(scriptName)) {
      // Collect continuation lines until the next command boundary.
      let block = line;
      let j = i + 1;
      while (j < lines.length) {
        const next = lines[j];
        if (/^\s*#/.test(next)) break;
        if (
          /\bnode\s+scripts\/ci\//.test(next) &&
          !/\\\s*$/.test(lines[j - 1])
        ) {
          break;
        }
        block += "\n" + next;
        j += 1;
        if (!/\\\s*$/.test(next)) break;
      }
      invocations.push({ block, line: i + 1 });
    }
  }
  return invocations;
}

// The reusable-call block and the workflow_call input shape are asserted by
// several tests below; keep one reader for each so a shape change lands once.
function iosEvidenceReusableCallBlock() {
  const callMatch = releaseBody.match(
    /  domain-core-ios-release-evidence:[\s\S]*?secrets: inherit/u,
  );
  assert.ok(callMatch, "domain-core-ios-release-evidence reusable call exists");
  return callMatch[0];
}

function requiredStringInputDeclaration(name) {
  return [
    `      ${name}:`,
    "        required: true",
    "        type: string",
    "",
  ].join("\n");
}

test("release.yml forwards the selected domain-core profile to the iOS evidence reusable workflow", () => {
  // The reusable call `domain-core-ios-release-evidence` in release.yml must
  // pass `domain_core_profile: ${{ needs.release-preflight.outputs.domain_core_profile }}`.
  // The pre-fix code omits this input entirely, so the reusable workflow's
  // hard-coded `public-production` is used even for rollback dispatches.
  const callBlock = iosEvidenceReusableCallBlock();
  assert.match(
    callBlock,
    /domain_core_profile:\s*\$\{\{ needs\.release-preflight\.outputs\.domain_core_profile \}\}/u,
    "reusable call must forward domain_core_profile from release-preflight",
  );

  // Negative control: simulate the pre-fix state (no domain_core_profile input)
  // and confirm the assertion would fail.
  const preFix = callBlock.replace(
    /\s*domain_core_profile:\s*\$\{\{ needs\.release-preflight\.outputs\.domain_core_profile \}\}/u,
    "",
  );
  assert.doesNotMatch(
    preFix,
    /domain_core_profile:/u,
    "negative control: removing the forwarded input must drop the assertion",
  );
});

test("domain-core-ios-release-evidence.yml declares a required domain_core_profile workflow_call input", () => {
  const declaration = requiredStringInputDeclaration("domain_core_profile");
  assert.ok(
    iosEvidenceBody.includes(declaration),
    "domain_core_profile must be a required string workflow_call input",
  );

  const preFix = iosEvidenceBody.replace(declaration, "");
  const preOn = preFix.match(/^on:[\s\S]*?^permissions:/mu);
  assert.ok(preOn, "negative-control workflow on: block remains parseable");
  assert.doesNotMatch(
    preOn[0],
    /domain_core_profile:/u,
    "negative control: dropping the input declaration must drop the assertion",
  );
});

test("every iOS verify-domain-core-build-profile-artifact invocation uses the forwarded profile, not a hard-coded public-production literal", () => {
  const verifierInvocations = extractInvocations(
    iosEvidenceBody,
    "verify-domain-core-build-profile-artifact.mjs",
  );
  assert.ok(
    verifierInvocations.length >= 2,
    `expected >= 2 iOS artifact verifier invocations, found ${verifierInvocations.length}`,
  );

  assert.match(
    iosEvidenceBody,
    /DOMAIN_CORE_PROFILE:\s*\$\{\{ inputs\.domain_core_profile \}\}/u,
    "the verifier step must bind DOMAIN_CORE_PROFILE to the forwarded input",
  );
  for (const inv of verifierInvocations) {
    assert.match(
      inv.block,
      /--profile\s+"\$DOMAIN_CORE_PROFILE"/u,
      `iOS verifier invocation at line ${inv.line} must use the bound profile`,
    );
    assert.doesNotMatch(
      inv.block,
      /--profile\s+public-production\b/u,
      `iOS verifier invocation at line ${inv.line} must not hard-code --profile public-production`,
    );
  }

  const preFixHardcoded = iosEvidenceBody.replace(
    /--profile\s+"\$DOMAIN_CORE_PROFILE"/gu,
    "--profile public-production",
  );
  const preInv = extractInvocations(
    preFixHardcoded,
    "verify-domain-core-build-profile-artifact.mjs",
  );
  assert.ok(
    preInv.some((inv) => /--profile\s+public-production\b/u.test(inv.block)),
    "negative control: hard-coded public-production must be detectable",
  );
});

test("every iOS verify-domain-core-build-profile-artifact --apple-app call supplies the full expected-release-commit/version/tag triplet", () => {
  const verifierInvocations = extractInvocations(
    iosEvidenceBody,
    "verify-domain-core-build-profile-artifact.mjs",
  );
  const appleInvocations = verifierInvocations.filter((inv) =>
    inv.block.includes("--apple-app"),
  );
  assert.ok(
    appleInvocations.length >= 2,
    "expected >= 2 --apple-app verifier invocations (xcarchive + IPA)",
  );
  for (const inv of appleInvocations) {
    assert.match(
      inv.block,
      /--expected-release-commit\s+"\$RELEASE_COMMIT"/u,
      `--apple-app verifier at line ${inv.line} must pass --expected-release-commit`,
    );
    assert.match(
      inv.block,
      /--expected-release-version\s+"\$VERSION"/u,
      `--apple-app verifier at line ${inv.line} must pass --expected-release-version`,
    );
    assert.match(
      inv.block,
      /--expected-release-tag\s+"v\$\{VERSION\}"/u,
      `--apple-app verifier at line ${inv.line} must pass --expected-release-tag`,
    );
  }

  const preFixBody = iosEvidenceBody
    .replace(/\s*--expected-release-commit\s+"\$RELEASE_COMMIT"/gu, "")
    .replace(/\s*--expected-release-version\s+"\$VERSION"/gu, "")
    .replace(/\s*--expected-release-tag\s+"v\$\{VERSION\}"/gu, "");
  const preInv = extractInvocations(
    preFixBody,
    "verify-domain-core-build-profile-artifact.mjs",
  ).filter((inv) => inv.block.includes("--apple-app"));
  assert.ok(
    preInv.some((inv) => !/--expected-release-commit/u.test(inv.block)),
    "negative control: missing --expected-release-commit must be detectable",
  );
});

test("iOS resolve-domain-core-build-profile invocation uses the forwarded profile", () => {
  const resolverInvocations = extractInvocations(
    iosEvidenceBody,
    "resolve-domain-core-build-profile.mjs",
  );
  assert.ok(
    resolverInvocations.length >= 1,
    "expected the iOS evidence workflow to resolve the build profile",
  );
  assert.match(
    iosEvidenceBody,
    /DOMAIN_CORE_PROFILE:\s*\$\{\{ inputs\.domain_core_profile \}\}/u,
    "the resolver step must bind DOMAIN_CORE_PROFILE to the forwarded input",
  );
  for (const inv of resolverInvocations) {
    assert.match(
      inv.block,
      /--profile\s+"\$DOMAIN_CORE_PROFILE"/u,
      `resolve-domain-core-build-profile invocation at line ${inv.line} must use the bound profile`,
    );
    assert.doesNotMatch(
      inv.block,
      /--profile\s+public-production\b/u,
      `resolve-domain-core-build-profile invocation at line ${inv.line} must not hard-code public-production`,
    );
  }
});

test("iOS evidence never re-resolves the activation on its own runner", () => {
  // The gate resolves the activation once and uploads the selector it proved.
  // Re-resolving here re-derives the activation authority commit P, which on
  // the legacy `active: false` lane is NOT the candidate the artifacts were
  // built against (the gate rebinds C = P = R), so the exact identity compare
  // fails a stable cut.
  assert.doesNotMatch(
    iosEvidenceBody,
    /node\s+scripts\/ci\/resolve-domain-core-activation\.mjs/u,
    "iOS evidence must consume the gate's activation selector, not re-resolve one",
  );

  const preFix = iosEvidenceBody.replace(
    /activation="\$\(cat "\$RUNNER_TEMP\/ios-release\/domain-core-activation\.json"\)"/gu,
    'activation="$(node scripts/ci/resolve-domain-core-activation.mjs --release-commit "$RELEASE_COMMIT" --format json)"',
  );
  assert.match(
    preFix,
    /node\s+scripts\/ci\/resolve-domain-core-activation\.mjs/u,
    "negative control: restoring the re-resolve must be detectable",
  );
});

test("every iOS activation consumer reads the gate's downloaded selector", () => {
  const assignments = iosEvidenceBody.match(/^\s*activation="[^\n]*$/gmu) ?? [];
  assert.equal(
    assignments.length,
    3,
    `expected the three iOS activation consumers, found ${assignments.length}`,
  );
  for (const assignment of assignments) {
    assert.match(
      assignment,
      /activation="\$\(cat "\$RUNNER_TEMP\/ios-release\/domain-core-activation\.json"\)"/u,
      `activation must come from the bound gate selector: ${assignment.trim()}`,
    );
  }

  // The candidate fed to every verifier is the gate's, not a jq re-read of a
  // locally resolved document.
  assert.match(
    iosEvidenceBody,
    /candidate="\$GATE_CANDIDATE_COMMIT"/u,
    "the verifier step must bind $candidate to the gate's candidate commit",
  );
  assert.doesNotMatch(
    iosEvidenceBody,
    /candidate="\$\(jq -er '\.candidateCommit'/u,
    "the candidate must not be re-derived from a locally resolved activation",
  );
});

test("iOS evidence downloads and fail-closed binds the gate selector before verifying", () => {
  const download = iosEvidenceBody.indexOf(
    "name: Download verified native release gate inputs",
  );
  const bind = iosEvidenceBody.indexOf(
    "name: Bind iOS verification to the gate's release-bound activation",
  );
  const verify = iosEvidenceBody.indexOf(
    "name: Verify canonical iOS archive and candidate-bound build profile",
  );
  assert.ok(download >= 0, "gate artifact download step is missing");
  assert.ok(bind >= 0, "gate binding step is missing");
  assert.ok(verify >= 0, "archive verification step is missing");
  assert.ok(
    download < bind && bind < verify,
    "the gate artifact must be downloaded and bound before verification",
  );

  assert.match(
    iosEvidenceBody,
    /name: \$\{\{ inputs\.gate_artifact_name \}\}/u,
    "the download must name the gate's own artifact",
  );
  for (const [pattern, why] of [
    [
      /test "\$\(jq -er '\.candidateCommit' "\$gate_activation"\)" = "\$GATE_CANDIDATE_COMMIT"/u,
      "the selector's candidate must equal the gate's candidate_commit output",
    ],
    [
      /test "\$\(jq -er '\.activationCommit' "\$gate_activation"\)" = "\$RELEASE_COMMIT"/u,
      "the selector must be bound to the release commit",
    ],
    [
      /test "\$\(jq -er '\.active \| tostring' "\$gate_activation"\)" = "\$GATE_RUST_ACTIVE"/u,
      "the selector's active flag must equal the gate's rust_active output",
    ],
    [
      /test "\$GATE_PROFILE_NAME" = "\$DOMAIN_CORE_PROFILE"/u,
      "the forwarded profile must equal the gate's validated profile_name",
    ],
  ]) {
    assert.match(iosEvidenceBody, pattern, why);
  }

  const preFix = iosEvidenceBody.replace(
    /\n\s*test "\$\(jq -er '\.candidateCommit' "\$gate_activation"\)" = "\$GATE_CANDIDATE_COMMIT"/u,
    "",
  );
  assert.doesNotMatch(
    preFix,
    /jq -er '\.candidateCommit' "\$gate_activation"/u,
    "negative control: dropping the candidate binding must be detectable",
  );
});

test("release.yml forwards the native release gate verdict to the iOS evidence reusable workflow", () => {
  const callBlock = iosEvidenceReusableCallBlock();
  assert.match(
    callBlock,
    /^      - domain-core-native-release-gate$/mu,
    "the iOS evidence job must depend on the native release gate",
  );
  for (const input of [
    "gate_artifact_name: ${{ needs.domain-core-native-release-gate.outputs.artifact_name }}",
    "gate_candidate_commit: ${{ needs.domain-core-native-release-gate.outputs.candidate_commit }}",
    "gate_profile_name: ${{ needs.domain-core-native-release-gate.outputs.profile_name }}",
    "gate_rust_active: ${{ needs.domain-core-native-release-gate.outputs.rust_active }}",
  ]) {
    assert.ok(
      callBlock.includes(input),
      `reusable call must forward ${input.split(":")[0]} from the gate`,
    );
  }

  // build-and-release bakes the gate's candidate into the iOS app; iOS evidence
  // must verify against that same commit.
  assert.match(
    releaseBody,
    /--expected-candidate-commit "\$\{\{ needs\.domain-core-native-release-gate\.outputs\.candidate_commit \}\}"/u,
    "the packaging lane must bind the artifacts to the gate candidate",
  );

  const preFix = callBlock.replace(
    /\s*gate_candidate_commit: \$\{\{ needs\.domain-core-native-release-gate\.outputs\.candidate_commit \}\}/u,
    "",
  );
  assert.doesNotMatch(
    preFix,
    /gate_candidate_commit:/u,
    "negative control: removing the forwarded candidate must drop the assertion",
  );
});

test("domain-core-ios-release-evidence.yml declares the gate-bound workflow_call inputs", () => {
  for (const name of [
    "gate_artifact_name",
    "gate_candidate_commit",
    "gate_profile_name",
    "gate_rust_active",
  ]) {
    const declaration = requiredStringInputDeclaration(name);
    assert.ok(
      iosEvidenceBody.includes(declaration),
      `${name} must be a required string workflow_call input`,
    );
  }

  const preFix = iosEvidenceBody.replace(
    requiredStringInputDeclaration("gate_candidate_commit"),
    "",
  );
  const preOn = preFix.match(/^on:[\s\S]*?^permissions:/mu);
  assert.ok(preOn, "negative-control workflow on: block remains parseable");
  assert.doesNotMatch(
    preOn[0],
    /gate_candidate_commit:/u,
    "negative control: dropping the input declaration must drop the assertion",
  );
});

// ---------------------------------------------------------------------------
// Behavioral fixture: signed apple-app verification with HEAD == activation P
// and expected candidate an ancestor C != P.
// ---------------------------------------------------------------------------

const MANIFEST_REL = "crates/openburnbar-domain-core/union-abi-manifest.json";
const PROFILES_REL = "config/domain-core-build-profiles.json";
const DELETION_REL = "config/domain-core-legacy-deletion.json";

function git(root, ...args) {
  return execFileSync("git", ["-C", root, ...args], {
    encoding: "utf8",
  }).trim();
}

/**
 * Build a synthetic git repo where:
 *   - commit C is the candidate (carries the union ABI manifest),
 *   - commit P is the activation (descendant of C) with an allowed-path diff
 *     that does not change the attested Rust core closure.
 * HEAD is left at P. Returns { root, candidate, activation, manifest }.
 *
 * Mirrors the fixture shape from domain-core-activation.test.mjs so the
 * activation validator's allowed-path / identity-drift rules are exercised for
 * real, then the verifier script is run as a subprocess against the same
 * checkout.
 */
function stageVerifierSources(root) {
  for (const relativePath of VERIFIER_SUPPORT_RELS) {
    const destination = join(root, relativePath);
    mkdirSync(dirname(destination), { recursive: true });
    writeFileSync(destination, readFileSync(join(REPO_ROOT, relativePath)));
  }
}

function activationFixture() {
  const root = mkdtempSync(join(tmpdir(), "ios-profile-artifact-"));
  const appRoot = mkdtempSync(join(tmpdir(), "ios-profile-artifact-app-"));
  stageVerifierSources(root);
  mkdirSync(join(root, "crates/openburnbar-domain-core"), { recursive: true });
  mkdirSync(join(root, "config"), { recursive: true });
  const manifest = {
    coreVersion: "0.3.0",
    abiVersion: 3,
    sourceSha256: "a".repeat(64),
  };
  writeFileSync(join(root, MANIFEST_REL), JSON.stringify(manifest));
  // Keep the candidate catalog valid but byte-distinct from activation P so
  // the required build-profile activation path is present in C..P.
  writeFileSync(join(root, PROFILES_REL), JSON.stringify(catalog));
  writeFileSync(join(root, DELETION_REL), JSON.stringify({ rows: [] }));
  git(root, "init", "-q");
  git(root, "config", "user.email", "test@openburnbar.invalid");
  git(root, "config", "user.name", "OpenBurnBar Test");
  git(root, "add", ".");
  git(root, "commit", "-qm", "candidate C");
  const candidate = git(root, "rev-parse", "HEAD");

  // Activation P: change only the two ALLOWED_EXACT paths (the activation
  // validator requires both in the diff) without touching the manifest, so the
  // attested core closure is unchanged.
  writeFileSync(join(root, PROFILES_REL), JSON.stringify(catalog, null, 2));
  writeFileSync(
    join(root, DELETION_REL),
    JSON.stringify({ rows: [{ id: "x" }] }),
  );
  git(root, "add", ".");
  git(root, "commit", "-qm", "activation P");
  const activation = git(root, "rev-parse", "HEAD");
  assert.notEqual(candidate, activation, "fixture requires distinct C and P");
  return { root, appRoot, candidate, activation, manifest };
}

/**
 * Write an iOS app bundle Info.plist whose domain-core receipt keys encode the
 * resolved build profile. The verifier reads these via `plutil -extract ...
 * raw`, so this is the same observable surface a real signed artifact exposes.
 */
function writeAppPlist(appDir, profile) {
  mkdirSync(appDir, { recursive: true });
  const lines = [
    `<?xml version="1.0" encoding="UTF-8"?>`,
    `<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">`,
    `<plist version="1.0">`,
    `<dict>`,
  ];
  const entries = [
    ["OpenBurnBarDomainCoreBuildProfile", profile.name],
    ["OpenBurnBarDomainCoreBuildAuthority", profile.artifactAuthority],
    ["OpenBurnBarDomainCoreDistribution", profile.distribution],
    ["OpenBurnBarDomainCoreRolloutChannel", profile.rolloutChannel ?? ""],
    [
      "OpenBurnBarDomainCoreEvidenceEnabled",
      profile.evidenceEnabled ? "1" : "0",
    ],
    [
      "OpenBurnBarDomainCoreCandidateCommit",
      profile.candidateIdentity.candidateCommit,
    ],
    [
      "OpenBurnBarDomainCoreExpectedVersion",
      profile.candidateIdentity.coreVersion,
    ],
    [
      "OpenBurnBarDomainCoreExpectedABIVersion",
      profile.candidateIdentity.abiVersion,
    ],
    [
      "OpenBurnBarDomainCoreExpectedSourceSHA256",
      profile.candidateIdentity.sourceSha256,
    ],
    ["OpenBurnBarDomainCoreModeQuota", profile.modes.quota],
    ["OpenBurnBarDomainCoreModeCloudVault", profile.modes.cloudVault],
    [
      "OpenBurnBarDomainCoreModeCloudVaultRewrap",
      profile.modes.cloudVaultRewrap,
    ],
    [
      "OpenBurnBarDomainCoreModeCloudVaultSearch",
      profile.modes.cloudVaultSearch,
    ],
    ["OpenBurnBarDomainCoreModeHermes", profile.modes.hermes],
    ["OpenBurnBarDomainCoreModePricing", profile.modes.pricing],
  ];
  for (const [key, value] of entries) {
    if (key === "OpenBurnBarDomainCoreExpectedABIVersion") {
      lines.push(`  <key>${key}</key>`);
      lines.push(`  <integer>${value}</integer>`);
    } else {
      lines.push(`  <key>${key}</key>`);
      lines.push(`  <string>${value}</string>`);
    }
  }
  lines.push(`</dict>`, `</plist>`);
  writeFileSync(join(appDir, "Info.plist"), lines.join("\n") + "\n", "utf8");
}

function runVerifier(repoRoot, { profile, candidate, release, appDir }) {
  const argv = [
    join(repoRoot, VERIFIER_REL),
    "--profile",
    profile,
    "--expected-candidate-commit",
    candidate,
    "--expected-release-commit",
    release.commit,
    "--expected-release-version",
    release.version,
    "--expected-release-tag",
    release.tag,
    "--apple-app",
    appDir,
  ];
  return spawnSync(process.execPath, argv, {
    encoding: "utf8",
    cwd: repoRoot,
  });
}

test("signed apple-app verifies when HEAD is activation P and the candidate is an ancestor C != P with matching metadata", () => {
  const fx = activationFixture();
  try {
    const releaseVersion = "1.2.3";
    const releaseTag = `v${releaseVersion}`;
    // The verifier resolves candidate identity through validateDomainCoreActivation
    // at repoRoot with HEAD == P (activation). The expected profile carries the
    // candidate identity derived from C (unchanged at P).
    const expected = resolveDomainCoreBuildProfile(
      catalog,
      "public-production-rollback",
      {
        candidateCommit: fx.candidate,
        coreVersion: fx.manifest.coreVersion,
        abiVersion: fx.manifest.abiVersion,
        sourceSha256: fx.manifest.sourceSha256,
      },
      { version: releaseVersion, tag: releaseTag, commit: fx.activation },
    );
    const appDir = join(fx.appRoot, "OpenBurnBarMobile.app");
    writeAppPlist(appDir, expected);

    const result = runVerifier(fx.root, {
      profile: "public-production-rollback",
      candidate: fx.candidate,
      release: {
        version: releaseVersion,
        tag: releaseTag,
        commit: fx.activation,
      },
      appDir,
    });
    assert.equal(
      result.status,
      0,
      `expected verification to pass; stderr=${result.stderr} stdout=${result.stdout}`,
    );
    assert.match(
      result.stdout,
      /domain-core artifact profile verified: public-production-rollback/,
    );
  } finally {
    rmSync(fx.root, { recursive: true, force: true });
    rmSync(fx.appRoot, { recursive: true, force: true });
  }
});

test("signed apple-app fails closed when the plist candidate commit (wrong C) disagrees with activation metadata", () => {
  const fx = activationFixture();
  try {
    const releaseVersion = "1.2.3";
    const releaseTag = `v${releaseVersion}`;
    // Build a profile that claims a WRONG candidate commit in the plist. The
    // verifier must fail because the activation-derived candidate identity (C)
    // does not match the plist's claimed candidate commit.
    const wrongCandidate = "d".repeat(40);
    const expected = resolveDomainCoreBuildProfile(
      catalog,
      "public-production-rollback",
      {
        candidateCommit: wrongCandidate,
        coreVersion: fx.manifest.coreVersion,
        abiVersion: fx.manifest.abiVersion,
        sourceSha256: fx.manifest.sourceSha256,
      },
      { version: releaseVersion, tag: releaseTag, commit: fx.activation },
    );
    const appDir = join(fx.appRoot, "OpenBurnBarMobile.app");
    writeAppPlist(appDir, expected);

    const result = runVerifier(fx.root, {
      profile: "public-production-rollback",
      candidate: fx.candidate,
      release: {
        version: releaseVersion,
        tag: releaseTag,
        commit: fx.activation,
      },
      appDir,
    });
    assert.notEqual(
      result.status,
      0,
      "wrong candidate commit in the plist must fail verification",
    );
    assert.match(result.stderr, /artifact profile mismatch/);
  } finally {
    rmSync(fx.root, { recursive: true, force: true });
    rmSync(fx.appRoot, { recursive: true, force: true });
  }
});

test("signed apple-app fails closed when the activation P changes the attested Rust core closure", () => {
  const fx = activationFixture();
  try {
    const releaseVersion = "1.2.3";
    const releaseTag = `v${releaseVersion}`;
    // Tamper with the manifest AT the activation checkout (HEAD == P) so the
    // attested closure drifts between C and P. validateDomainCoreActivation
    // must reject this with "activation changed the attested Rust core closure".
    const drifted = { ...fx.manifest, sourceSha256: "b".repeat(64) };
    writeFileSync(join(fx.root, MANIFEST_REL), JSON.stringify(drifted));
    git(fx.root, "add", ".");
    git(fx.root, "commit", "-qm", "forbidden identity drift");
    const driftedActivation = git(fx.root, "rev-parse", "HEAD");

    const expected = resolveDomainCoreBuildProfile(
      catalog,
      "public-production-rollback",
      {
        candidateCommit: fx.candidate,
        coreVersion: drifted.coreVersion,
        abiVersion: drifted.abiVersion,
        sourceSha256: drifted.sourceSha256,
      },
      { version: releaseVersion, tag: releaseTag, commit: driftedActivation },
    );
    const appDir = join(fx.appRoot, "OpenBurnBarMobile.app");
    writeAppPlist(appDir, expected);

    const result = runVerifier(fx.root, {
      profile: "public-production-rollback",
      candidate: fx.candidate,
      release: {
        version: releaseVersion,
        tag: releaseTag,
        commit: driftedActivation,
      },
      appDir,
    });
    assert.notEqual(
      result.status,
      0,
      "activation that changes the attested core closure must fail verification",
    );
    assert.match(result.stderr, /attested Rust core closure/);
  } finally {
    rmSync(fx.root, { recursive: true, force: true });
    rmSync(fx.appRoot, { recursive: true, force: true });
  }
});

test("signed apple-app fails closed when the plist profile name disagrees with the forwarded profile", () => {
  const fx = activationFixture();
  try {
    const releaseVersion = "1.2.3";
    const releaseTag = `v${releaseVersion}`;
    // The plist claims public-production while the forwarded profile is
    // public-production-rollback. The verifier must fail on the name mismatch.
    const expected = resolveDomainCoreBuildProfile(
      catalog,
      "public-production",
      {
        candidateCommit: fx.candidate,
        coreVersion: fx.manifest.coreVersion,
        abiVersion: fx.manifest.abiVersion,
        sourceSha256: fx.manifest.sourceSha256,
      },
      { version: releaseVersion, tag: releaseTag, commit: fx.activation },
    );
    const appDir = join(fx.appRoot, "OpenBurnBarMobile.app");
    writeAppPlist(appDir, expected);

    const result = runVerifier(fx.root, {
      profile: "public-production-rollback",
      candidate: fx.candidate,
      release: {
        version: releaseVersion,
        tag: releaseTag,
        commit: fx.activation,
      },
      appDir,
    });
    assert.notEqual(
      result.status,
      0,
      "plist profile name mismatch must fail verification",
    );
    assert.match(result.stderr, /artifact profile mismatch/);
  } finally {
    rmSync(fx.root, { recursive: true, force: true });
    rmSync(fx.appRoot, { recursive: true, force: true });
  }
});

test("signed apple-app fails closed without the --expected-release-commit triplet (HEAD==C only path rejects ancestor C != P)", () => {
  // Pin the pre-fix regression: without --expected-release-commit, the verifier
  // falls back to resolveDomainCoreCandidateIdentity which requires HEAD == C.
  // With HEAD == P and C an ancestor != P, that path MUST fail closed rather
  // than silently accepting the wrong checkout.
  const fx = activationFixture();
  try {
    const expected = resolveDomainCoreBuildProfile(
      catalog,
      "public-production-rollback",
      {
        candidateCommit: fx.candidate,
        coreVersion: fx.manifest.coreVersion,
        abiVersion: fx.manifest.abiVersion,
        sourceSha256: fx.manifest.sourceSha256,
      },
    );
    const appDir = join(fx.root, "app/OpenBurnBarMobile.app");
    writeAppPlist(appDir, expected);

    const result = spawnSync(
      process.execPath,
      [
        join(fx.root, VERIFIER_REL),
        "--profile",
        "public-production-rollback",
        "--expected-candidate-commit",
        fx.candidate,
        "--apple-app",
        appDir,
      ],
      { encoding: "utf8", cwd: fx.root },
    );
    assert.notEqual(
      result.status,
      0,
      "HEAD==P with ancestor C != P and no release-commit triplet must fail (no silent HEAD==C acceptance)",
    );
    assert.match(result.stderr, /candidate commit mismatch/);
  } finally {
    rmSync(fx.root, { recursive: true, force: true });
    rmSync(fx.appRoot, { recursive: true, force: true });
  }
});
