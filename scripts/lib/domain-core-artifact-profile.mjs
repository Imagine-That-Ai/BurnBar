import { readdirSync, readFileSync } from "node:fs";
import { basename, join } from "node:path";

export const DOMAIN_CORE_ARTIFACT_SELECTORS = [
  "--receipt",
  "--windows-dir",
  "--console-dir",
  "--functions-dir",
  "--android-aab",
  "--apple-app",
];

export function parseDomainCoreArtifactVerifierArgs(argv) {
  const releaseFlags = [
    "--expected-release-commit",
    "--expected-release-version",
    "--expected-release-tag",
  ];
  const allowed = new Set([
    "--profile",
    "--expected-candidate-commit",
    ...releaseFlags,
    ...DOMAIN_CORE_ARTIFACT_SELECTORS,
  ]);
  const args = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (!allowed.has(flag)) throw new Error(`unknown argument: ${flag}`);
    if (args.has(flag)) throw new Error(`duplicate argument: ${flag}`);
    if (value === undefined || value.startsWith("--")) {
      throw new Error(`${flag} requires a value`);
    }
    args.set(flag, value);
  }
  if (!args.has("--profile")) throw new Error("--profile is required");
  const releaseFlagCount = releaseFlags.filter((flag) => args.has(flag)).length;
  if (releaseFlagCount !== 0 && releaseFlagCount !== releaseFlags.length) {
    throw new Error(
      "expected release commit, version, and tag must be supplied together",
    );
  }
  const selectors = DOMAIN_CORE_ARTIFACT_SELECTORS.filter((flag) =>
    args.has(flag),
  );
  if (selectors.length !== 1)
    throw new Error("exactly one artifact selector is required");
  return args;
}

export function domainCoreProfileFromApplePlist(read) {
  return {
    schemaVersion: 1,
    name: read("OpenBurnBarDomainCoreBuildProfile"),
    artifactAuthority: read("OpenBurnBarDomainCoreBuildAuthority"),
    distribution: read("OpenBurnBarDomainCoreDistribution"),
    rolloutChannel: read("OpenBurnBarDomainCoreRolloutChannel") || null,
    evidenceEnabled: ["1", "YES", "true"].includes(
      read("OpenBurnBarDomainCoreEvidenceEnabled"),
    ),
    candidateIdentity: {
      candidateCommit: read("OpenBurnBarDomainCoreCandidateCommit"),
      coreVersion: read("OpenBurnBarDomainCoreExpectedVersion"),
      abiVersion: Number(read("OpenBurnBarDomainCoreExpectedABIVersion")),
      sourceSha256: read("OpenBurnBarDomainCoreExpectedSourceSHA256"),
    },
    modes: {
      quota: read("OpenBurnBarDomainCoreModeQuota"),
      cloudVault: read("OpenBurnBarDomainCoreModeCloudVault"),
      cloudVaultRewrap: read("OpenBurnBarDomainCoreModeCloudVaultRewrap"),
      cloudVaultSearch: read("OpenBurnBarDomainCoreModeCloudVaultSearch"),
      hermes: read("OpenBurnBarDomainCoreModeHermes"),
      pricing: read("OpenBurnBarDomainCoreModePricing"),
    },
  };
}

function filesRecursively(root, predicate) {
  const files = [];
  for (const entry of readdirSync(root, { withFileTypes: true })) {
    const path = join(root, entry.name);
    if (entry.isDirectory()) files.push(...filesRecursively(path, predicate));
    else if (entry.isFile() && predicate(path)) files.push(path);
  }
  return files;
}

function requiredRuntimeStrings(profile) {
  if (!profile.candidateIdentity)
    throw new Error("signed artifact profile is missing candidate identity");
  return [
    profile.name,
    profile.artifactAuthority,
    profile.distribution,
    profile.candidateIdentity.candidateCommit,
    profile.candidateIdentity.coreVersion,
    String(profile.candidateIdentity.abiVersion),
    profile.candidateIdentity.sourceSha256,
    ...Object.values(profile.modes),
  ];
}

export function assertBuffersContainStrings(label, buffers, requiredStrings) {
  if (!Array.isArray(buffers) || buffers.length === 0)
    throw new Error(`${label} has no runtime payloads`);
  for (const value of new Set(requiredStrings)) {
    const needle = Buffer.from(value, "utf8");
    if (!buffers.some((buffer) => buffer.includes(needle))) {
      throw new Error(
        `${label} does not embed required domain-core value: ${value}`,
      );
    }
  }
}

export function verifyConsoleRuntimeProfile(consoleDir, profile) {
  const javaScript = filesRecursively(consoleDir, (path) =>
    path.endsWith(".js"),
  ).map((path) => readFileSync(path));
  assertBuffersContainStrings(
    "Console JavaScript",
    javaScript,
    requiredRuntimeStrings(profile),
  );
}

export function verifyWindowsRuntimeProfile(windowsDir, profile) {
  const assemblies = filesRecursively(
    windowsDir,
    (path) =>
      basename(path).toLowerCase() === "openburnbar.app.configuration.dll",
  ).map((path) => readFileSync(path));
  const metadataKeys = [
    "OpenBurnBar.DomainCore.BuildProfile",
    "OpenBurnBar.DomainCore.BuildAuthority",
    "OpenBurnBar.DomainCore.CandidateCommit",
    "OpenBurnBar.DomainCore.ExpectedVersion",
    "OpenBurnBar.DomainCore.ExpectedAbiVersion",
    "OpenBurnBar.DomainCore.ExpectedSourceSha256",
  ];
  assertBuffersContainStrings("Windows configuration assembly", assemblies, [
    ...metadataKeys,
    ...requiredRuntimeStrings(profile),
  ]);
}

export function verifyAndroidRuntimeProfile(dexBuffers, profile) {
  if (!profile.candidateIdentity)
    throw new Error("signed Android profile is missing candidate identity");
  const identityWire = [
    profile.candidateIdentity.candidateCommit,
    profile.candidateIdentity.coreVersion,
    profile.candidateIdentity.abiVersion,
    profile.candidateIdentity.sourceSha256,
  ].join("|");
  assertBuffersContainStrings("Android DEX", dexBuffers, [identityWire]);
}
