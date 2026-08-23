import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { join } from "node:path";

import { validateDomainCoreCandidateIdentity } from "./domain-core-candidate-receipt.mjs";
import { DOMAIN_CORE_PROTECTED_SIGNER_WORKFLOW } from "./domain-core-release-evidence.mjs";

const FULL_SHA = /^[0-9a-f]{40}$/u;
const DIGEST_RE = /^[0-9a-f]{64}$/u;
const ACTIVATION_RECEIPT_KEYS = Object.freeze([
  "candidateCommit",
  "activationCommit",
  "coreVersion",
  "abiVersion",
  "sourceSha256",
  "changedPathsSha256",
]);
const REQUIRED_EXACT = new Set([
  "config/domain-core-build-profiles.json",
  "config/domain-core-legacy-deletion.json",
]);
const OPTIONAL_EXACT = new Set([
  "config/domain-core-control-plane-manifest.json",
]);
const ATTESTED_SOURCE_PREFIX = "crates/openburnbar-domain-core/";
// Deployed domain-core artifacts (vendored bindings, wasm packages, and the
// prebuilt Android/Apple binaries) are what production actually executes. The
// promotion sidecars pin the Rust *source* fingerprint, not the artifact
// bytes, so an incidental protected-main commit that swaps one of these files
// between candidate C and release R would ship unattested code while every
// digest check still passes. Treat them like attested Rust source: fail
// closed whenever a path-disjoint commit touches them.
export const DEPLOYED_ARTIFACT_PREFIXES = Object.freeze([
  "OpenBurnBarCore/Sources/OpenBurnBarDomainCore/Generated/",
  "Vendor/OpenBurnBarDomainCore.xcframework/",
  "Vendor/openburnbar-domain-core.aar",
  "android/openburnbar-domain-core/src/main/java/uniffi/",
  "apps/console/vendor/openburnbar-domain-core-wasm/",
  "functions/vendor/openburnbar/domain-core-wasm/",
]);
const AUTHORITY_EVIDENCE_PREFIXES = [
  "config/domain-core-legacy-deletion-receipts/",
  "config/domain-core-promotion-attestations/",
  "config/domain-core-promotion-bundles/",
  "config/domain-core-promotion-provenance/",
];
const ALLOWED_PREFIXES = [
  ...AUTHORITY_EVIDENCE_PREFIXES,
  "docs/runbooks/shared-rust-",
  "docs/SHARED_RUST_DOMAIN_",
];
const DOMAIN_ROWS = Object.freeze({
  quota: [
    "quota.claude_statusline",
    "quota.codex_usage",
    "quota.cursor_usage",
    "quota.anthropic_headers",
  ],
  cloudVault: ["cloudvault.portable_primitives"],
  cloudVaultRewrap: ["cloudvault.document_rewrap"],
  cloudVaultSearch: ["cloudvault.search"],
  hermes: ["hermes.relay_crypto", "hermes.ratchet_transforms"],
  pricing: ["pricing.token_cost", "pricing.kimi_historical"],
});
const DOMAIN_SCOPES = Object.freeze({
  quota: "quota",
  cloudVault: "cloudvault",
  cloudVaultRewrap: "cloudvault-rewrap",
  cloudVaultSearch: "cloudvault-search",
  hermes: "hermes",
  pricing: "pricing",
});

function git(repoRoot, args) {
  return execFileSync("git", ["-C", repoRoot, ...args], {
    encoding: "utf8",
  }).trim();
}

function latestFirstParentCommitChangingPath(repoRoot, releaseCommit, path) {
  requireRepoRelativePath(path);
  const revision = git(repoRoot, [
    "rev-list",
    "--first-parent",
    "-n",
    "1",
    releaseCommit,
    "--",
    path,
  ]);
  if (revision === "") {
    throw new Error(
      `activation authority path has no committed history: ${path}`,
    );
  }
  return commit(revision, `${path} activation commit`);
}

function resolveActivationAuthorityCommit(repoRoot, releaseCommit) {
  const authorityCommits = [...REQUIRED_EXACT].map((path) =>
    latestFirstParentCommitChangingPath(repoRoot, releaseCommit, path),
  );
  if (new Set(authorityCommits).size !== 1) {
    throw new Error(
      "activation authority files must resolve to the same first-parent commit",
    );
  }
  return authorityCommits[0];
}

function requireNoAuthorityDriftAfterActivation({
  repoRoot,
  activationCommit,
  releaseCommit,
  paths,
  prefixes = [],
}) {
  if (activationCommit === releaseCommit) return;
  try {
    execFileSync("git", [
      "-C",
      repoRoot,
      "merge-base",
      "--is-ancestor",
      activationCommit,
      releaseCommit,
    ]);
  } catch {
    throw new Error(
      "domain-core activation commit must be an ancestor of release commit",
    );
  }
  const protectedPaths = [...new Set(paths)].sort();
  const protectedSet = new Set(protectedPaths);
  const protectedPrefixes = [...new Set(prefixes)].sort();
  const changed = new Set();
  const revisions = git(repoRoot, [
    "rev-list",
    "--first-parent",
    "--reverse",
    `${activationCommit}..${releaseCommit}`,
  ])
    .split("\n")
    .filter(Boolean);
  for (const revision of revisions) {
    const parent = git(repoRoot, ["rev-parse", `${revision}^1`]);
    const revisionPaths = git(repoRoot, [
      "diff",
      "--name-only",
      "--diff-filter=ACDMRTUXB",
      `${parent}..${revision}`,
    ])
      .split("\n")
      .filter(Boolean);
    for (const path of revisionPaths) {
      if (
        protectedSet.has(path) ||
        protectedPrefixes.some((prefix) => path.startsWith(prefix))
      ) {
        changed.add(path);
      }
    }
  }
  if (changed.size > 0) {
    throw new Error(
      `domain-core activation authority drift after activation: ${[...changed]
        .sort()
        .join(", ")}`,
    );
  }
}

function provenanceError() {
  return new Error("attestation candidate provenance unverifiable");
}

function requireExactKeys(value, expected) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw provenanceError();
  }
  const actual = Object.keys(value).sort();
  const wanted = [...expected].sort();
  if (
    actual.length !== wanted.length ||
    actual.some((key, index) => key !== wanted[index])
  ) {
    throw provenanceError();
  }
  return value;
}

function requirePositiveInteger(value) {
  if (!Number.isSafeInteger(value) || value < 1) throw provenanceError();
  return value;
}

function requireRepoRelativePath(value) {
  if (
    typeof value !== "string" ||
    value.length === 0 ||
    value.includes("\u0000") ||
    value.includes("\\") ||
    value.startsWith("/") ||
    value.endsWith("/")
  ) {
    throw provenanceError();
  }
  const parts = value.split("/");
  if (parts.some((part) => part === "" || part === "." || part === "..")) {
    throw provenanceError();
  }
  return value;
}

// Hash the exact committed git-blob bytes. Evidence is release-authoritative
// only when it is bound to activation commit P; reading the worktree would add
// a pathname race and a second, mutable authority even in a nominally clean
// checkout. No decoding or trimming is performed.
function sha256GitBlob(repoRoot, revision, path) {
  requireRepoRelativePath(path);
  let blob;
  try {
    blob = execFileSync("git", ["-C", repoRoot, "show", `${revision}:${path}`]);
  } catch {
    throw provenanceError();
  }
  return createHash("sha256").update(blob).digest("hex");
}

function requireCleanCheckout(repoRoot) {
  if (
    git(repoRoot, ["status", "--porcelain=v1", "--untracked-files=all"]) !== ""
  ) {
    throw new Error("signed domain-core activation checkout must be clean");
  }
}

function requireExactCheckout(repoRoot, expectedCommit) {
  if (git(repoRoot, ["rev-parse", "HEAD"]) !== expectedCommit) {
    throw new Error(
      "signed domain-core activation checkout must match the activation commit",
    );
  }
  requireCleanCheckout(repoRoot);
}

function commit(value, label) {
  if (typeof value !== "string" || !FULL_SHA.test(value)) {
    throw new Error(`${label} must be a full lowercase Git SHA-1`);
  }
  return value;
}

function gitJson(repoRoot, revision, path, label) {
  try {
    return JSON.parse(git(repoRoot, ["show", `${revision}:${path}`]));
  } catch (error) {
    throw new Error(`${label} is not valid committed JSON: ${error.message}`);
  }
}

function candidateAt(repoRoot, revision) {
  const manifest = gitJson(
    repoRoot,
    revision,
    "crates/openburnbar-domain-core/union-abi-manifest.json",
    "domain-core union ABI manifest",
  );
  return validateDomainCoreCandidateIdentity({
    candidateCommit: revision,
    coreVersion: manifest.coreVersion,
    abiVersion: manifest.abiVersion,
    sourceSha256: manifest.sourceSha256,
  });
}

function canonicalSha256(value) {
  const canonical = (item) => {
    if (Array.isArray(item)) return `[${item.map(canonical).join(",")}]`;
    if (item && typeof item === "object") {
      return `{${Object.keys(item)
        .sort()
        .map((key) => `${JSON.stringify(key)}:${canonical(item[key])}`)
        .join(",")}}`;
    }
    return JSON.stringify(item);
  };
  return createHash("sha256").update(canonical(value)).digest("hex");
}

export function domainCoreActivationReceiptClosure(value) {
  const activation = requireExactKeys(value, [
    "active",
    ...ACTIVATION_RECEIPT_KEYS,
  ]);
  if (activation.active !== true) {
    throw new Error("previous activation annulment closure is not active");
  }
  return Object.fromEntries(
    ACTIVATION_RECEIPT_KEYS.map((key) => [key, activation[key]]),
  );
}

export function activationChangedPaths(
  repoRoot,
  candidateCommit,
  activationCommit,
) {
  return firstParentActivationChangedPaths({
    repoRoot,
    candidateCommit,
    activationCommit,
    label: "activation",
  });
}

function firstParentActivationChangedPaths({
  repoRoot,
  candidateCommit,
  activationCommit,
  label,
}) {
  const candidate = commit(candidateCommit, "candidate commit");
  const activation = commit(activationCommit, "activation commit");
  if (candidate === activation) {
    throw new Error(`${label} diff must not be empty`);
  }
  try {
    execFileSync("git", [
      "-C",
      repoRoot,
      "merge-base",
      "--is-ancestor",
      candidate,
      activation,
    ]);
  } catch {
    throw new Error(`candidate commit must be an ancestor of ${label} commit`);
  }
  const activationCommits = git(repoRoot, [
    "rev-list",
    "--first-parent",
    "--reverse",
    `${candidate}..${activation}`,
  ])
    .split("\n")
    .filter(Boolean);
  const incidentalPaths = new Set();
  for (const revision of activationCommits) {
    const lineage = git(repoRoot, [
      "rev-list",
      "--parents",
      "-n",
      "1",
      revision,
    ]).split(/\s+/u);
    if (lineage.length < 2) {
      throw new Error(`${label} commit must have a parent`);
    }
    const commitPaths = git(repoRoot, [
      "diff",
      "--name-only",
      "--diff-filter=ACDMRTUXB",
      `${lineage[1]}..${revision}`,
    ])
      .split("\n")
      .filter(Boolean)
      .sort();
    const commitForbidden = commitPaths.filter(
      (path) =>
        !REQUIRED_EXACT.has(path) &&
        !OPTIONAL_EXACT.has(path) &&
        !ALLOWED_PREFIXES.some((prefix) => path.startsWith(prefix)),
    );
    if (commitForbidden.length > 0) {
      if (revision === activation) {
        throw new Error(
          `${label} final diff contains forbidden paths: ${commitForbidden.join(", ")}`,
        );
      }
      if (commitPaths.some((path) => path.startsWith(ATTESTED_SOURCE_PREFIX))) {
        throw new Error(
          `${label} incidental protected-main commit ${revision} must not change attested Rust source`,
        );
      }
      if (
        commitPaths.some((path) =>
          DEPLOYED_ARTIFACT_PREFIXES.some((prefix) => path.startsWith(prefix)),
        )
      ) {
        throw new Error(
          `${label} incidental protected-main commit ${revision} must not change deployed domain-core artifacts`,
        );
      }
      // A commit is incidental only when it changes no activation-authority
      // path. A mixed commit would silently drop authority changes from the
      // annulment closure, so fail closed.
      if (commitForbidden.length !== commitPaths.length) {
        throw new Error(
          `${label} incidental protected-main commit ${revision} must not change activation authority paths`,
        );
      }
      for (const path of commitPaths) incidentalPaths.add(path);
    }
  }
  // Bind the full candidate..activation closure while excluding paths proven
  // to come solely from separate, path-disjoint protected-main commits. The
  // activation commit itself remains path-restricted and mixed commits fail
  // closed, so an unrelated main advance cannot become activation authority.
  const paths = git(repoRoot, [
    "diff",
    "--name-only",
    "--diff-filter=ACDMRTUXB",
    `${candidate}..${activation}`,
  ])
    .split("\n")
    .filter((path) => path && !incidentalPaths.has(path))
    .sort();
  if (paths.length === 0) {
    throw new Error(`${label} diff must not be empty`);
  }
  const forbidden = paths.filter(
    (path) =>
      !REQUIRED_EXACT.has(path) &&
      !OPTIONAL_EXACT.has(path) &&
      !ALLOWED_PREFIXES.some((prefix) => path.startsWith(prefix)),
  );
  if (forbidden.length > 0) {
    throw new Error(
      `${label} suffix contains forbidden paths: ${forbidden.join(", ")}`,
    );
  }
  for (const required of REQUIRED_EXACT) {
    if (!paths.includes(required)) {
      throw new Error(`${label} diff must include ${required}`);
    }
  }
  return paths;
}

export function annullableActivationChangedPaths(
  repoRoot,
  candidateCommit,
  activationCommit,
) {
  return firstParentActivationChangedPaths({
    repoRoot,
    candidateCommit,
    activationCommit,
    label: "annullable activation",
  });
}

export function validateDomainCoreActivation({
  repoRoot,
  candidateCommit,
  activationCommit,
  requireHead = true,
  requireClean = true,
}) {
  if (requireClean) {
    requireCleanCheckout(repoRoot);
  }
  const candidate = candidateAt(
    repoRoot,
    commit(candidateCommit, "candidate commit"),
  );
  const activationSha = commit(activationCommit, "activation commit");
  if (requireHead && git(repoRoot, ["rev-parse", "HEAD"]) !== activationSha) {
    throw new Error(
      "activation commit must equal the exact release checkout HEAD",
    );
  }
  const activationIdentity = candidateAt(repoRoot, activationSha);
  if (
    activationIdentity.coreVersion !== candidate.coreVersion ||
    activationIdentity.abiVersion !== candidate.abiVersion ||
    activationIdentity.sourceSha256 !== candidate.sourceSha256
  ) {
    throw new Error("activation changed the attested Rust core closure");
  }
  if (candidate.candidateCommit === activationSha) {
    const profiles = JSON.parse(
      readFileSync(
        join(repoRoot, "config/domain-core-build-profiles.json"),
        "utf8",
      ),
    );
    if (
      Object.values(
        profiles.profiles?.["public-production"]?.modes ?? {},
      ).includes("rust")
    ) {
      throw new Error(
        "Rust activation requires distinct candidate C and activation P commits",
      );
    }
    return {
      active: false,
      candidateCommit: candidate.candidateCommit,
      activationCommit: activationSha,
      coreVersion: candidate.coreVersion,
      abiVersion: candidate.abiVersion,
      sourceSha256: candidate.sourceSha256,
      changedPathsSha256: createHash("sha256").update("[]").digest("hex"),
    };
  }
  const paths = activationChangedPaths(
    repoRoot,
    candidate.candidateCommit,
    activationSha,
  );
  const changedPathsSha256 = createHash("sha256")
    .update(JSON.stringify(paths))
    .digest("hex");
  return {
    active: true,
    candidateCommit: candidate.candidateCommit,
    activationCommit: activationSha,
    coreVersion: candidate.coreVersion,
    abiVersion: candidate.abiVersion,
    sourceSha256: candidate.sourceSha256,
    changedPathsSha256,
  };
}

// Validate the activation closure against a release checkout R whose HEAD may
// have advanced past activation P on protected main. The activation commit is
// re-derived from the committed authority files (the same single-authority
// resolution used by resolveActiveDomainCoreActivation), never trusted from
// the release coordinates: a release commit R is release-authoritative but is
// not itself the activation authority once path-disjoint protected-main
// commits land after P. Post-activation drift of the activation closure paths
// and the deployed domain-core artifacts stays fail-closed across P..R.
export function validateDomainCoreReleaseActivation({
  repoRoot,
  candidateCommit,
  releaseCommit,
  requireHead = true,
  requireClean = true,
}) {
  const release = commit(releaseCommit, "release commit");
  if (requireHead && git(repoRoot, ["rev-parse", "HEAD"]) !== release) {
    throw new Error(
      "release commit must equal the exact release checkout HEAD",
    );
  }
  if (requireClean) {
    requireCleanCheckout(repoRoot);
  }
  const activationSha = resolveActivationAuthorityCommit(repoRoot, release);
  const activation = validateDomainCoreActivation({
    repoRoot,
    candidateCommit,
    activationCommit: activationSha,
    requireHead: false,
    requireClean,
  });
  // Post-activation drift protects the authority files and the activation's
  // append-only evidence (receipts, attestations, bundles, provenance) — the
  // same set resolveActiveDomainCoreActivation pins across P..R. The trusted
  // control-plane manifest and runbook docs legitimately keep evolving with
  // ordinary protected-main work after activation, so they stay unprotected.
  const protectedPaths = new Set(REQUIRED_EXACT);
  if (activation.active) {
    for (const path of activationChangedPaths(
      repoRoot,
      activation.candidateCommit,
      activationSha,
    )) {
      if (
        REQUIRED_EXACT.has(path) ||
        AUTHORITY_EVIDENCE_PREFIXES.some((prefix) => path.startsWith(prefix))
      ) {
        protectedPaths.add(path);
      }
    }
  }
  requireNoAuthorityDriftAfterActivation({
    repoRoot,
    activationCommit: activationSha,
    releaseCommit: release,
    paths: protectedPaths,
    prefixes: activation.active ? DEPLOYED_ARTIFACT_PREFIXES : [],
  });
  return { ...activation, releaseCommit: release };
}

export function validateDomainCoreAnnullableActivation({
  repoRoot,
  candidateCommit,
  activationCommit,
}) {
  requireCleanCheckout(repoRoot);
  const candidate = candidateAt(
    repoRoot,
    commit(candidateCommit, "candidate commit"),
  );
  const activationSha = commit(activationCommit, "activation commit");
  const activationIdentity = candidateAt(repoRoot, activationSha);
  if (
    activationIdentity.coreVersion !== candidate.coreVersion ||
    activationIdentity.abiVersion !== candidate.abiVersion ||
    activationIdentity.sourceSha256 !== candidate.sourceSha256
  ) {
    throw new Error(
      "annullable activation changed the attested Rust core closure",
    );
  }
  const paths = annullableActivationChangedPaths(
    repoRoot,
    candidate.candidateCommit,
    activationSha,
  );
  return {
    active: true,
    candidateCommit: candidate.candidateCommit,
    activationCommit: activationSha,
    coreVersion: candidate.coreVersion,
    abiVersion: candidate.abiVersion,
    sourceSha256: candidate.sourceSha256,
    changedPathsSha256: createHash("sha256")
      .update(JSON.stringify(paths))
      .digest("hex"),
  };
}

// Re-derive the protected candidate identity from git at the attestation's
// claimed candidate commit and bind every attestation field to that
// git-derived truth plus the existing protected-signer convention. This closes
// the resolver trust gap where committed attestation JSON could nominate an
// arbitrary candidate C without proving protected-signer provenance. No second
// authority is introduced: the same candidateAt / validateDomainCoreCandidateIdentity
// substrate that backs validateDomainCoreActivation is reused, and the signer
// coordinates are bound to the single DOMAIN_CORE_PROTECTED_SIGNER_WORKFLOW
// already used by verifyProtectedPromotionAttestation and the Python gate.
function verifyProtectedAttestationProvenance({
  repoRoot,
  activationCommit,
  authorityScope,
  authorityGeneration,
  attestation,
  verifyArtifactIdentity,
}) {
  requireExactKeys(attestation, [
    "schemaVersion",
    "authorityScope",
    "authorityGeneration",
    "candidate",
    "unsignedBundle",
    "provenance",
    "status",
    "generatedAt",
    "evidenceUri",
  ]);
  if (
    attestation.schemaVersion !== 2 ||
    attestation.authorityScope !== authorityScope ||
    attestation.authorityGeneration !== authorityGeneration ||
    attestation.status !== "attested" ||
    typeof attestation.generatedAt !== "string" ||
    !attestation.generatedAt.endsWith("Z") ||
    !Number.isFinite(Date.parse(attestation.generatedAt)) ||
    typeof attestation.evidenceUri !== "string" ||
    !/^https:\/\/github\.com\/Imagine-That-Ai\/BurnBar\/attestations\/[1-9][0-9]*$/u.test(
      attestation.evidenceUri,
    )
  ) {
    throw provenanceError();
  }

  const claimedCandidate = requireExactKeys(attestation.candidate, [
    "candidateCommit",
    "coreVersion",
    "abiVersion",
    "sourceSha256",
  ]);
  const claimedCommit = claimedCandidate.candidateCommit;
  if (typeof claimedCommit !== "string" || !FULL_SHA.test(claimedCommit)) {
    throw provenanceError();
  }

  // Re-derive candidate truth from the committed union manifest. Attestation
  // identity claims never become an independent candidate authority.
  let verifiedCandidate;
  try {
    verifiedCandidate = candidateAt(repoRoot, claimedCommit);
  } catch {
    throw provenanceError();
  }
  if (
    verifiedCandidate.candidateCommit !== claimedCandidate.candidateCommit ||
    verifiedCandidate.coreVersion !== claimedCandidate.coreVersion ||
    verifiedCandidate.abiVersion !== claimedCandidate.abiVersion ||
    verifiedCandidate.sourceSha256 !== claimedCandidate.sourceSha256
  ) {
    throw provenanceError();
  }

  const unsignedBundle = requireExactKeys(attestation.unsignedBundle, [
    "path",
    "sha256",
    "sourceRunId",
    "sourceRunAttempt",
  ]);
  const expectedBundlePath = `config/domain-core-promotion-bundles/${authorityScope}/${authorityGeneration}.json`;
  if (
    requireRepoRelativePath(unsignedBundle.path) !== expectedBundlePath ||
    typeof unsignedBundle.sha256 !== "string" ||
    !DIGEST_RE.test(unsignedBundle.sha256)
  ) {
    throw provenanceError();
  }
  requirePositiveInteger(unsignedBundle.sourceRunId);
  requirePositiveInteger(unsignedBundle.sourceRunAttempt);
  if (
    sha256GitBlob(repoRoot, activationCommit, unsignedBundle.path) !==
    unsignedBundle.sha256
  ) {
    throw new Error("attestation unsigned bundle digest mismatch");
  }

  const provenance = requireExactKeys(attestation.provenance, [
    "path",
    "sha256",
    "signerWorkflow",
    "signerRunId",
    "signerRunAttempt",
    "trustedMainCommit",
    "policySha256",
    "evaluatorSha256",
  ]);
  const expectedProvenancePath = `config/domain-core-promotion-provenance/${authorityScope}/${authorityGeneration}.json`;
  if (
    requireRepoRelativePath(provenance.path) !== expectedProvenancePath ||
    typeof provenance.sha256 !== "string" ||
    !DIGEST_RE.test(provenance.sha256)
  ) {
    throw provenanceError();
  }
  if (provenance.signerWorkflow !== DOMAIN_CORE_PROTECTED_SIGNER_WORKFLOW) {
    throw new Error("attestation workflow mismatch");
  }
  try {
    requirePositiveInteger(provenance.signerRunId);
    requirePositiveInteger(provenance.signerRunAttempt);
  } catch {
    throw new Error("attestation signer run mismatch");
  }
  if (
    typeof provenance.trustedMainCommit !== "string" ||
    !FULL_SHA.test(provenance.trustedMainCommit)
  ) {
    throw provenanceError();
  }

  // The protected evaluator runs after candidate C exists; C must therefore be
  // an ancestor of trusted-main M. Reversing this relation would authorize an
  // unevaluated descendant candidate.
  try {
    execFileSync("git", [
      "-C",
      repoRoot,
      "merge-base",
      "--is-ancestor",
      verifiedCandidate.candidateCommit,
      provenance.trustedMainCommit,
    ]);
  } catch {
    throw provenanceError();
  }
  const policyDigest = sha256GitBlob(
    repoRoot,
    provenance.trustedMainCommit,
    "config/domain-core-promotion-policy.json",
  );
  const evaluatorDigest = sha256GitBlob(
    repoRoot,
    provenance.trustedMainCommit,
    "scripts/lib/domain-core-deterministic-candidate-bundle.mjs",
  );
  if (
    provenance.policySha256 !== policyDigest ||
    provenance.evaluatorSha256 !== evaluatorDigest
  ) {
    throw new Error("attestation source digest mismatch");
  }
  if (
    sha256GitBlob(repoRoot, activationCommit, provenance.path) !==
    provenance.sha256
  ) {
    throw new Error("attestation provenance digest mismatch");
  }

  if (verifyArtifactIdentity) {
    const unionGatePath = join(
      repoRoot,
      "scripts/ci/domain-core-union-gate.py",
    );
    let verifiedSourceSha256;
    try {
      verifiedSourceSha256 = execFileSync(
        "python3",
        [unionGatePath, "--root", repoRoot, "--source-fingerprint"],
        { encoding: "utf8" },
      ).trim();
    } catch (error) {
      throw new Error(
        `attestation candidate provenance unverifiable: ${error.message}`,
      );
    }
    if (verifiedSourceSha256 !== verifiedCandidate.sourceSha256) {
      throw new Error("attestation source digest mismatch");
    }
  }
  return { verifiedCandidate, provenance };
}

function verifySupersededAuthority({
  repoRoot,
  activationCommit,
  rowId,
  authorityGeneration,
  approvedAt,
  supersedes,
  candidateCommit,
}) {
  if (authorityGeneration === 1) {
    if (supersedes !== null) throw provenanceError();
    return;
  }
  const link = requireExactKeys(supersedes, ["transition", "path", "sha256"]);
  const fileName = {
    annulment: "annulment.json",
    rollback: "rollback.json",
    stable_release: "stable_release.json",
  }[link.transition];
  if (fileName === undefined) throw provenanceError();
  const expectedPath = `config/domain-core-legacy-deletion-receipts/${rowId}/${authorityGeneration - 1}/${fileName}`;
  if (
    requireRepoRelativePath(link.path) !== expectedPath ||
    typeof link.sha256 !== "string" ||
    !DIGEST_RE.test(link.sha256) ||
    sha256GitBlob(repoRoot, activationCommit, link.path) !== link.sha256
  ) {
    throw new Error("promotion supersession receipt mismatch");
  }
  const previous = gitJson(
    repoRoot,
    activationCommit,
    link.path,
    `${rowId} superseded authority receipt`,
  );
  const previousApprovedAt = Date.parse(previous?.approvedAt);
  if (
    previous?.schemaVersion !== 2 ||
    previous?.rowId !== rowId ||
    previous?.authorityGeneration !== authorityGeneration - 1 ||
    previous?.transition !== link.transition ||
    previous?.status !== "active" ||
    !Number.isFinite(previousApprovedAt) ||
    previousApprovedAt >= Date.parse(approvedAt)
  ) {
    throw new Error(
      "promotion supersession does not identify the previous active authority",
    );
  }
  if (link.transition === "rollback") {
    const activatedAt = Date.parse(previous?.rollback?.activatedAt);
    if (!Number.isFinite(activatedAt) || activatedAt > previousApprovedAt) {
      throw new Error(
        "previous rollback activation cannot follow rollback approval",
      );
    }
  }
  if (link.transition === "annulment") {
    const payload = requireExactKeys(previous?.activationAnnulment, [
      "promotionReceiptSha256",
      "candidate",
      "activation",
      "advancedMainCommit",
      "reason",
      "replacementCandidateRequired",
    ]);
    const candidate = requireExactKeys(payload.candidate, [
      "candidateCommit",
      "coreVersion",
      "abiVersion",
      "sourceSha256",
    ]);
    const activation = requireExactKeys(payload.activation, [
      "candidateCommit",
      "activationCommit",
      "coreVersion",
      "abiVersion",
      "sourceSha256",
      "changedPathsSha256",
    ]);
    const previousPromotionPath = `config/domain-core-legacy-deletion-receipts/${rowId}/${authorityGeneration - 1}/promotion.json`;
    if (
      payload.promotionReceiptSha256 !==
        sha256GitBlob(repoRoot, activationCommit, previousPromotionPath) ||
      payload.advancedMainCommit !== previous.commit ||
      payload.reason !== "release_train_advanced_before_stable_receipt" ||
      payload.replacementCandidateRequired !== true ||
      candidate.candidateCommit !== activation.candidateCommit ||
      !FULL_SHA.test(activation.activationCommit) ||
      activation.activationCommit === payload.advancedMainCommit
    ) {
      throw new Error("previous activation annulment authority is invalid");
    }
    const expectedActivation = validateDomainCoreAnnullableActivation({
      repoRoot,
      candidateCommit: candidate.candidateCommit,
      activationCommit: activation.activationCommit,
    });
    if (
      canonicalSha256(
        domainCoreActivationReceiptClosure(expectedActivation),
      ) !== canonicalSha256(activation)
    ) {
      throw new Error("previous activation annulment closure is invalid");
    }
    try {
      execFileSync("git", [
        "-C",
        repoRoot,
        "merge-base",
        "--is-ancestor",
        activation.activationCommit,
        payload.advancedMainCommit,
      ]);
    } catch {
      throw new Error("previous activation annulment main advance is invalid");
    }
    if (candidate.candidateCommit === candidateCommit) {
      throw new Error(
        "promotion after annulment must attest a fresh replacement candidate",
      );
    }
    try {
      execFileSync("git", [
        "-C",
        repoRoot,
        "merge-base",
        "--is-ancestor",
        payload.advancedMainCommit,
        candidateCommit,
      ]);
    } catch {
      throw new Error(
        "promotion after annulment must descend from the advanced main commit",
      );
    }
  }
}
function verifyPromotionReceipt({
  repoRoot,
  activationCommit,
  rowId,
  authorityScope,
  authorityGeneration,
  pointer,
}) {
  const expectedReceiptPath = `config/domain-core-legacy-deletion-receipts/${rowId}/${authorityGeneration}/promotion.json`;
  if (requireRepoRelativePath(pointer) !== expectedReceiptPath) {
    throw new Error(`${rowId}: promotion receipt path mismatch`);
  }
  const receipt = gitJson(
    repoRoot,
    activationCommit,
    pointer,
    `${rowId} promotion receipt`,
  );
  requireExactKeys(receipt, [
    "schemaVersion",
    "rowId",
    "authorityGeneration",
    "transition",
    "status",
    "evidence",
    "approvedBy",
    "approvedAt",
    "commit",
    "promotionAttestation",
  ]);
  if (
    receipt.schemaVersion !== 2 ||
    receipt.rowId !== rowId ||
    receipt.authorityGeneration !== authorityGeneration ||
    receipt.transition !== "promotion" ||
    receipt.status !== "active" ||
    !Array.isArray(receipt.evidence) ||
    receipt.evidence.length === 0 ||
    receipt.evidence.some(
      (value) =>
        typeof value !== "string" ||
        !/^https:\/\/(?![^/?#]*@)[^/?#]+(?:\/[^?#]*)?$/u.test(value),
    ) ||
    new Set(receipt.evidence).size !== receipt.evidence.length ||
    typeof receipt.approvedBy !== "string" ||
    !/^@[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$/u.test(
      receipt.approvedBy,
    ) ||
    typeof receipt.approvedAt !== "string" ||
    !receipt.approvedAt.endsWith("Z") ||
    !Number.isFinite(Date.parse(receipt.approvedAt)) ||
    typeof receipt.commit !== "string" ||
    !FULL_SHA.test(receipt.commit)
  ) {
    throw provenanceError();
  }
  const attestationPointer = requireExactKeys(receipt.promotionAttestation, [
    "path",
    "sha256",
    "supersedes",
  ]);
  const expectedAttestationPath = `config/domain-core-promotion-attestations/${authorityScope}/${authorityGeneration}.json`;
  if (
    requireRepoRelativePath(attestationPointer.path) !==
      expectedAttestationPath ||
    typeof attestationPointer.sha256 !== "string" ||
    !DIGEST_RE.test(attestationPointer.sha256) ||
    (attestationPointer.supersedes !== null &&
      (typeof attestationPointer.supersedes !== "object" ||
        Array.isArray(attestationPointer.supersedes)))
  ) {
    throw provenanceError();
  }
  verifySupersededAuthority({
    repoRoot,
    activationCommit,
    rowId,
    authorityGeneration,
    approvedAt: receipt.approvedAt,
    supersedes: attestationPointer.supersedes,
    candidateCommit: receipt.commit,
  });
  if (
    sha256GitBlob(repoRoot, activationCommit, attestationPointer.path) !==
    attestationPointer.sha256
  ) {
    throw new Error("promotion attestation digest mismatch");
  }
  return { receipt, attestationPath: attestationPointer.path };
}

export function resolveActiveDomainCoreActivation({
  repoRoot,
  activationCommit,
  verifyArtifactIdentity = true,
  requireClean = true,
}) {
  const releaseCommit = commit(activationCommit, "activation commit");
  if (requireClean) {
    requireExactCheckout(repoRoot, releaseCommit);
  } else if (git(repoRoot, ["rev-parse", "HEAD"]) !== releaseCommit) {
    throw new Error(
      "signed domain-core activation checkout must match the activation commit",
    );
  }
  const authorityActivationCommit = resolveActivationAuthorityCommit(
    repoRoot,
    releaseCommit,
  );
  const profiles = gitJson(
    repoRoot,
    authorityActivationCommit,
    "config/domain-core-build-profiles.json",
    "domain-core build profiles",
  );
  const ledger = gitJson(
    repoRoot,
    authorityActivationCommit,
    "config/domain-core-legacy-deletion.json",
    "domain-core authority ledger",
  );
  const rows = new Map(ledger.rows.map((row) => [row.id, row]));
  const candidates = new Set();
  const domains = [];
  const protectedAuthorityPaths = new Set(REQUIRED_EXACT);
  for (const [domain, rowIds] of Object.entries(DOMAIN_ROWS)) {
    if (profiles.profiles?.["public-production"]?.modes?.[domain] !== "rust")
      continue;
    for (const rowId of rowIds) {
      const row = rows.get(rowId);
      const authorityGeneration = row?.authorityGeneration;
      const pointer = row?.receipts?.promotion;
      if (
        !Number.isSafeInteger(authorityGeneration) ||
        authorityGeneration < 1 ||
        typeof pointer !== "string"
      ) {
        throw new Error(
          `${domain}: Rust activation is missing promotion receipt for ${rowId}`,
        );
      }
      const authorityScope = DOMAIN_SCOPES[domain];
      const { receipt, attestationPath } = verifyPromotionReceipt({
        repoRoot,
        activationCommit: authorityActivationCommit,
        rowId,
        authorityScope,
        authorityGeneration,
        pointer,
      });
      protectedAuthorityPaths.add(pointer);
      const supersedesPath = receipt.promotionAttestation.supersedes?.path;
      if (typeof supersedesPath === "string") {
        protectedAuthorityPaths.add(supersedesPath);
      }
      const attestation = gitJson(
        repoRoot,
        authorityActivationCommit,
        attestationPath,
        `${rowId} promotion attestation`,
      );
      const { verifiedCandidate, provenance } =
        verifyProtectedAttestationProvenance({
          repoRoot,
          activationCommit: authorityActivationCommit,
          authorityScope,
          authorityGeneration,
          attestation,
          verifyArtifactIdentity,
        });
      protectedAuthorityPaths.add(attestationPath);
      protectedAuthorityPaths.add(attestation.unsignedBundle.path);
      protectedAuthorityPaths.add(provenance.path);
      if (receipt.commit !== verifiedCandidate.candidateCommit) {
        throw new Error(`${rowId}: promotion receipt candidate mismatch`);
      }
      candidates.add(verifiedCandidate.candidateCommit);
      if (!domains.some((item) => item.domain === domain)) {
        domains.push({
          domain,
          rowId,
          promotionReceiptPath: pointer,
          attestationPath,
          bundlePath: attestation.unsignedBundle.path,
          provenancePath: provenance.path,
          signerRunId: provenance.signerRunId,
          signerRunAttempt: provenance.signerRunAttempt,
          publicProfileSha256: canonicalSha256({
            artifactAuthority:
              profiles.profiles["public-production"].artifactAuthority,
            distribution: profiles.profiles["public-production"].distribution,
            rolloutChannel:
              profiles.profiles["public-production"].rolloutChannel,
            evidenceEnabled:
              profiles.profiles["public-production"].evidenceEnabled,
            domain,
            mode: "rust",
          }),
        });
      }
    }
  }
  requireNoAuthorityDriftAfterActivation({
    repoRoot,
    activationCommit: authorityActivationCommit,
    releaseCommit,
    paths: protectedAuthorityPaths,
    prefixes: candidates.size > 0 ? DEPLOYED_ARTIFACT_PREFIXES : [],
  });
  if (candidates.size === 0) {
    return {
      ...validateDomainCoreActivation({
        repoRoot,
        candidateCommit: authorityActivationCommit,
        activationCommit: authorityActivationCommit,
        requireHead: false,
      }),
      domains: [],
    };
  }
  if (candidates.size !== 1) {
    throw new Error(
      "public Rust profile must resolve to exactly one protected candidate commit",
    );
  }
  return {
    active: true,
    ...validateDomainCoreActivation({
      repoRoot,
      candidateCommit: [...candidates][0],
      activationCommit: authorityActivationCommit,
      requireHead: false,
    }),
    domains,
  };
}
