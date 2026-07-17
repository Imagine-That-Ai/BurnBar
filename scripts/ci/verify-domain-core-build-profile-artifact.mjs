#!/usr/bin/env node
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, statSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  domainCoreProfileFromApplePlist,
  parseDomainCoreArtifactVerifierArgs,
  verifyAndroidRuntimeProfile,
  verifyConsoleRuntimeProfile,
  verifyWindowsRuntimeProfile,
} from "../lib/domain-core-artifact-profile.mjs";
import {
  loadDomainCoreBuildProfiles,
  parseDomainCoreFunctionsJavaScript,
  resolveDomainCoreBuildProfile,
} from "../lib/domain-core-build-profile.mjs";
import { resolveDomainCoreCandidateIdentity } from "../lib/domain-core-candidate-receipt.mjs";
import { validateDomainCoreActivation } from "../lib/domain-core-activation.mjs";

const args = parseDomainCoreArtifactVerifierArgs(process.argv.slice(2));
const profileName = args.get("--profile");
if (!profileName) throw new Error("--profile is required");
const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const catalog = loadDomainCoreBuildProfiles(
  join(repoRoot, "config/domain-core-build-profiles.json"),
);
const catalogProfile = catalog.profiles[profileName];
if (!catalogProfile)
  throw new Error(`unknown domain-core build profile: ${profileName}`);

// Signed artifacts carry an exact candidate identity bound into the build
// profile. At an activation checkout P the verifier may be run with the
// candidate C != P (the Rust activation invariant): in that case the identity
// must be resolved through the release/activation metadata at P, not by
// requiring HEAD == C. This mirrors resolve-domain-core-build-profile.mjs so
// the same signed profile is expected whether the verifier runs at a
// candidate checkout (HEAD == C) or at the activation checkout (HEAD == P,
// C resolved from activation provenance). When C == P and no Rust mode is
// active the identity is still proven directly from HEAD, preserving the
// ordinary candidate-checkout behavior and exact signed-profile identity
// checks (assert.deepStrictEqual below against the artifact plist/receipt).
const expectedReleaseCommit = args.get("--expected-release-commit");
const expectedCandidateCommit = args.get("--expected-candidate-commit");
let candidateIdentity;
if (catalogProfile.artifactAuthority === "signed") {
  if (expectedReleaseCommit !== undefined) {
    if (expectedCandidateCommit === undefined) {
      throw new Error(
        "--expected-release-commit requires --expected-candidate-commit",
      );
    }
    const hasActiveRust = Object.values(catalogProfile.modes).includes("rust");
    if (!hasActiveRust && expectedCandidateCommit === expectedReleaseCommit) {
      candidateIdentity = resolveDomainCoreCandidateIdentity({
        repoRoot,
        expectedCandidateCommit,
        requireClean: false,
      });
    } else {
      const activation = validateDomainCoreActivation({
        repoRoot,
        candidateCommit: expectedCandidateCommit,
        activationCommit: expectedReleaseCommit,
      });
      candidateIdentity = {
        candidateCommit: activation.candidateCommit,
        coreVersion: activation.coreVersion,
        abiVersion: activation.abiVersion,
        sourceSha256: activation.sourceSha256,
      };
    }
  } else {
    candidateIdentity = resolveDomainCoreCandidateIdentity({
      repoRoot,
      expectedCandidateCommit,
      requireClean: false,
    });
  }
}
// releaseCoordinates attaches the `release` block to the expected profile.
// Only the --receipt selector (the canonical rollback-bundle profile JSON
// produced by resolve-domain-core-build-profile.mjs with release coordinates)
// carries that block; every other artifact selector (apple plist, windows/console
// runtime profile json, functions js, android aab) bakes only the profile +
// candidate identity, never the release coordinates. Driving candidate-identity
// resolution from --expected-release-commit (above) must not also attach
// `release` to the expected profile for those selectors, or the exact
// assert.deepStrictEqual against the artifact would fail. Gate the coordinates
// on --receipt so the signed-profile exact identity checks are preserved.
const releaseCoordinates =
  args.has("--receipt") && args.has("--expected-release-commit")
    ? {
        commit: args.get("--expected-release-commit"),
        version: args.get("--expected-release-version"),
        tag: args.get("--expected-release-tag"),
      }
    : undefined;
const expected = resolveDomainCoreBuildProfile(
  catalog,
  profileName,
  candidateIdentity,
  releaseCoordinates,
);

const parseJsonArtifact = (content) =>
  JSON.parse(content.charCodeAt(0) === 0xfeff ? content.slice(1) : content);

let actual;
if (args.has("--receipt")) {
  actual = parseJsonArtifact(
    readFileSync(resolve(args.get("--receipt")), "utf8"),
  );
} else if (args.has("--windows-dir")) {
  actual = parseJsonArtifact(
    readFileSync(
      join(
        resolve(args.get("--windows-dir")),
        "domain-core-build-profile.json",
      ),
      "utf8",
    ),
  );
  verifyWindowsRuntimeProfile(resolve(args.get("--windows-dir")), expected);
} else if (args.has("--console-dir")) {
  actual = parseJsonArtifact(
    readFileSync(
      join(
        resolve(args.get("--console-dir")),
        "domain-core-build-profile.json",
      ),
      "utf8",
    ),
  );
  verifyConsoleRuntimeProfile(resolve(args.get("--console-dir")), expected);
} else if (args.has("--functions-dir")) {
  const modulePath = join(
    resolve(args.get("--functions-dir")),
    "generated/domainCoreCandidateReceipt.js",
  );
  actual = parseDomainCoreFunctionsJavaScript(readFileSync(modulePath, "utf8"));
} else if (args.has("--android-aab")) {
  const androidAab = resolve(args.get("--android-aab"));
  const content = execFileSync(
    "unzip",
    ["-p", androidAab, "base/assets/domain-core-build-profile.json"],
    {
      encoding: "utf8",
    },
  );
  actual = parseJsonArtifact(content);
  const dexEntries = execFileSync("unzip", ["-Z1", androidAab], {
    encoding: "utf8",
  })
    .split("\n")
    .filter((entry) => /^base\/dex\/[^/]+\.dex$/.test(entry));
  const dexBuffers = dexEntries.map((entry) =>
    execFileSync("unzip", ["-p", androidAab, entry], {
      maxBuffer: 128 * 1024 * 1024,
    }),
  );
  verifyAndroidRuntimeProfile(dexBuffers, expected);
} else if (args.has("--apple-app")) {
  const candidate = resolve(args.get("--apple-app"));
  let plist = candidate;
  if (statSync(candidate).isDirectory()) {
    const macOSPlist = join(candidate, "Contents/Info.plist");
    const iOSPlist = join(candidate, "Info.plist");
    plist = existsSync(macOSPlist) ? macOSPlist : iOSPlist;
  }
  const read = (key) =>
    execFileSync("plutil", ["-extract", key, "raw", "-o", "-", plist], {
      encoding: "utf8",
    }).trim();
  actual = domainCoreProfileFromApplePlist(read);
} else {
  throw new Error("one artifact selector is required");
}

try {
  assert.deepStrictEqual(actual, expected);
} catch {
  throw new Error(
    `domain-core artifact profile mismatch\nexpected=${JSON.stringify(expected)}\nactual=${JSON.stringify(actual)}`,
  );
}
console.log(`domain-core artifact profile verified: ${profileName}`);
