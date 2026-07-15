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
const candidateIdentity =
  catalogProfile.artifactAuthority === "signed"
    ? resolveDomainCoreCandidateIdentity({
        repoRoot,
        expectedCandidateCommit: args.get("--expected-candidate-commit"),
        requireClean: false,
      })
    : undefined;
const expected = resolveDomainCoreBuildProfile(
  catalog,
  profileName,
  candidateIdentity,
);

const parseJsonArtifact = (content) =>
  JSON.parse(content.charCodeAt(0) === 0xfeff ? content.slice(1) : content);

let actual;
if (args.has("--receipt")) {
  actual = parseJsonArtifact(readFileSync(resolve(args.get("--receipt")), "utf8"));
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
