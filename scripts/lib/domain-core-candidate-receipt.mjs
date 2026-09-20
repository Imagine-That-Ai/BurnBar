import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const FULL_GIT_SHA1_PATTERN = /^[0-9a-f]{40}$/;
const SEMVER_PATTERN =
  /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-(?:(?:0|[1-9]\d*)|(?:\d*[A-Za-z-][0-9A-Za-z-]*))(?:\.(?:(?:0|[1-9]\d*)|(?:\d*[A-Za-z-][0-9A-Za-z-]*)))*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/;
const SHA256_PATTERN = /^[0-9a-f]{64}$/;
const CANDIDATE_IDENTITY_KEYS = [
  "abiVersion",
  "candidateCommit",
  "coreVersion",
  "sourceSha256",
];

export function parseDomainCoreBuildProfileResolverArgs(argv) {
  const allowed = new Set([
    "--profile",
    "--format",
    "--output",
    "--expected-candidate-commit",
    "--expected-release-commit",
    "--expected-release-version",
    "--expected-release-tag",
    "--allow-dirty",
  ]);
  const args = new Map();
  for (let index = 0; index < argv.length; index += 1) {
    const flag = argv[index];
    if (!allowed.has(flag)) throw new Error(`unknown argument: ${flag}`);
    if (args.has(flag)) throw new Error(`duplicate argument: ${flag}`);
    if (flag === "--allow-dirty") {
      args.set(flag, true);
      continue;
    }
    const value = argv[index + 1];
    if (value === undefined || value.startsWith("--"))
      throw new Error(`${flag} requires a value`);
    args.set(flag, value);
    index += 1;
  }
  if (!args.has("--profile")) throw new Error("--profile is required");
  return args;
}

export function validateDomainCoreCandidateIdentity(identity) {
  if (!identity || typeof identity !== "object" || Array.isArray(identity)) {
    throw new Error("candidate identity must be an object");
  }
  const keys = Object.keys(identity).sort();
  if (
    keys.length !== CANDIDATE_IDENTITY_KEYS.length ||
    keys.some((key, index) => key !== CANDIDATE_IDENTITY_KEYS[index])
  ) {
    throw new Error(
      "candidate identity must contain exactly candidateCommit, coreVersion, abiVersion, and sourceSha256",
    );
  }
  if (
    typeof identity.candidateCommit !== "string" ||
    !FULL_GIT_SHA1_PATTERN.test(identity.candidateCommit)
  ) {
    throw new Error("candidateCommit must be a full lowercase Git SHA-1");
  }
  if (
    typeof identity.coreVersion !== "string" ||
    identity.coreVersion.length > 64 ||
    !SEMVER_PATTERN.test(identity.coreVersion)
  ) {
    throw new Error(
      "coreVersion must be a canonical SemVer string of at most 64 characters",
    );
  }
  if (
    !Number.isSafeInteger(identity.abiVersion) ||
    identity.abiVersion < 1 ||
    identity.abiVersion > 0xffffffff
  ) {
    throw new Error(
      "abiVersion must be an unsigned 32-bit integer greater than zero",
    );
  }
  if (
    typeof identity.sourceSha256 !== "string" ||
    !SHA256_PATTERN.test(identity.sourceSha256)
  ) {
    throw new Error("sourceSha256 must be a lowercase SHA-256 digest");
  }
  return structuredClone(identity);
}

export function loadDomainCoreArtifactIdentity(repoRoot) {
  const path = join(
    repoRoot,
    "crates/openburnbar-domain-core/union-abi-manifest.json",
  );
  const manifest = JSON.parse(readFileSync(path, "utf8"));
  return validateDomainCoreCandidateIdentity({
    candidateCommit: "0".repeat(40),
    coreVersion: manifest.coreVersion,
    abiVersion: manifest.abiVersion,
    sourceSha256: manifest.sourceSha256,
  });
}

function git(repoRoot, args) {
  return execFileSync("git", ["-C", repoRoot, ...args], {
    encoding: "utf8",
  }).trim();
}

export function resolveDomainCoreCandidateIdentity({
  repoRoot,
  expectedCandidateCommit,
  requireClean = true,
  verifyArtifactIdentity = true,
  unionGatePath = join(repoRoot, "scripts/ci/domain-core-union-gate.py"),
}) {
  if (!repoRoot) throw new Error("repoRoot is required");
  const candidateCommit = git(repoRoot, ["rev-parse", "HEAD"]);
  if (!FULL_GIT_SHA1_PATTERN.test(candidateCommit)) {
    throw new Error(
      "current checkout does not resolve to a full lowercase Git SHA-1",
    );
  }
  if (expectedCandidateCommit !== undefined) {
    if (
      typeof expectedCandidateCommit !== "string" ||
      !FULL_GIT_SHA1_PATTERN.test(expectedCandidateCommit)
    ) {
      throw new Error(
        "expected candidate commit must be a full lowercase Git SHA-1",
      );
    }
    if (candidateCommit !== expectedCandidateCommit) {
      throw new Error(
        `candidate commit mismatch: checkout=${candidateCommit} expected=${expectedCandidateCommit}`,
      );
    }
  }
  if (
    requireClean &&
    git(repoRoot, ["status", "--porcelain=v1", "--untracked-files=all"]) !== ""
  ) {
    throw new Error("signed domain-core candidate checkout must be clean");
  }
  const artifactIdentity = loadDomainCoreArtifactIdentity(repoRoot);
  if (verifyArtifactIdentity) {
    const verifiedSourceSha256 = execFileSync(
      "python3",
      [
        unionGatePath,
        "--root",
        repoRoot,
        "--source-fingerprint",
        "--check-build-identity",
      ],
      { encoding: "utf8" },
    ).trim();
    if (verifiedSourceSha256 !== artifactIdentity.sourceSha256) {
      throw new Error(
        `verified domain-core source identity mismatch: manifest=${artifactIdentity.sourceSha256} gate=${verifiedSourceSha256}`,
      );
    }
  }
  return validateDomainCoreCandidateIdentity({
    ...artifactIdentity,
    candidateCommit,
  });
}
