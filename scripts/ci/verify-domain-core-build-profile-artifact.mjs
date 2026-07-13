#!/usr/bin/env node
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFileSync, statSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { loadDomainCoreBuildProfiles, resolveDomainCoreBuildProfile } from "../lib/domain-core-build-profile.mjs";

const args = new Map();
for (let index = 2; index < process.argv.length; index += 2) args.set(process.argv[index], process.argv[index + 1]);
const profileName = args.get("--profile");
if (!profileName) throw new Error("--profile is required");
const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const expected = resolveDomainCoreBuildProfile(
  loadDomainCoreBuildProfiles(join(repoRoot, "config/domain-core-build-profiles.json")),
  profileName,
);

let actual;
if (args.has("--receipt")) {
  actual = JSON.parse(readFileSync(resolve(args.get("--receipt")), "utf8"));
} else if (args.has("--windows-dir")) {
  actual = JSON.parse(readFileSync(join(resolve(args.get("--windows-dir")), "domain-core-build-profile.json"), "utf8"));
} else if (args.has("--console-dir")) {
  actual = JSON.parse(readFileSync(join(resolve(args.get("--console-dir")), "domain-core-build-profile.json"), "utf8"));
} else if (args.has("--android-aab")) {
  const content = execFileSync("unzip", ["-p", resolve(args.get("--android-aab")), "base/assets/domain-core-build-profile.json"], {
    encoding: "utf8",
  });
  actual = JSON.parse(content);
} else if (args.has("--apple-app")) {
  const candidate = resolve(args.get("--apple-app"));
  const plist = statSync(candidate).isDirectory() ? join(candidate, "Contents/Info.plist") : candidate;
  const read = (key) => execFileSync("plutil", ["-extract", key, "raw", "-o", "-", plist], { encoding: "utf8" }).trim();
  actual = {
    schemaVersion: 1,
    name: read("OpenBurnBarDomainCoreBuildProfile"),
    artifactAuthority: read("OpenBurnBarDomainCoreBuildAuthority"),
    distribution: read("OpenBurnBarDomainCoreDistribution"),
    rolloutChannel: read("OpenBurnBarDomainCoreRolloutChannel") || null,
    evidenceEnabled: ["1", "YES", "true"].includes(read("OpenBurnBarDomainCoreEvidenceEnabled")),
    modes: {
      quota: read("OpenBurnBarDomainCoreModeQuota"),
      cloudVault: read("OpenBurnBarDomainCoreModeCloudVault"),
      cloudVaultRewrap: read("OpenBurnBarDomainCoreModeCloudVaultRewrap"),
      cloudVaultSearch: read("OpenBurnBarDomainCoreModeCloudVaultSearch"),
      hermes: read("OpenBurnBarDomainCoreModeHermes"),
      pricing: read("OpenBurnBarDomainCoreModePricing"),
    },
  };
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
