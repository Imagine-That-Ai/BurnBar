import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { join } from "node:path";

import { validateDomainCoreCandidateIdentity } from "./domain-core-candidate-receipt.mjs";
import { DOMAIN_CORE_PROTECTED_SIGNER_WORKFLOW } from "./domain-core-release-evidence.mjs";

const FULL_SHA = /^[0-9a-f]{40}$/u;
const ALLOWED_EXACT = new Set([
  "config/domain-core-build-profiles.json",
  "config/domain-core-legacy-deletion.json",
]);
const ALLOWED_PREFIXES = [
  "config/domain-core-legacy-deletion-receipts/",
  "config/domain-core-promotion-attestations/",
  "config/domain-core-promotion-bundles/",
  "config/domain-core-promotion-provenance/",
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

function git(repoRoot, args) {
  return execFileSync("git", ["-C", repoRoot, ...args], {
    encoding: "utf8",
  }).trim();
}

function requireCleanCheckout(repoRoot) {
  if (
    git(repoRoot, ["status", "--porcelain=v1", "--untracked-files=all"]) !== ""
  ) {
    throw new Error("signed domain-core activation checkout must be clean");
  }
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

export function activationChangedPaths(
  repoRoot,
  candidateCommit,
  activationCommit,
) {
  const candidate = commit(candidateCommit, "candidate commit");
  const activation = commit(activationCommit, "activation commit");
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
    throw new Error(
      "candidate commit must be an ancestor of activation commit",
    );
  }
  const paths = git(repoRoot, [
    "diff",
    "--name-only",
    "--diff-filter=ACDMRTUXB",
    `${candidate}..${activation}`,
  ])
    .split("\n")
    .filter(Boolean)
    .sort();
  if (paths.length === 0) throw new Error("activation diff must not be empty");
  const forbidden = paths.filter(
    (path) =>
      !ALLOWED_EXACT.has(path) &&
      !ALLOWED_PREFIXES.some((prefix) => path.startsWith(prefix)),
  );
  if (forbidden.length > 0) {
    throw new Error(
      `activation diff contains forbidden paths: ${forbidden.join(", ")}`,
    );
  }
  for (const required of ALLOWED_EXACT) {
    if (!paths.includes(required)) {
      throw new Error(`activation diff must include ${required}`);
    }
  }
  return paths;
}

export function validateDomainCoreActivation({
  repoRoot,
  candidateCommit,
  activationCommit,
  requireHead = true,
}) {
  requireCleanCheckout(repoRoot);
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
  attestation,
  verifyArtifactIdentity,
}) {
  const claimedCandidate = attestation?.candidate;
  if (
    !claimedCandidate ||
    typeof claimedCandidate !== "object" ||
    Array.isArray(claimedCandidate)
  ) {
    throw new Error("attestation candidate provenance unverifiable");
  }
  const claimedCommit = claimedCandidate.candidateCommit;
  if (typeof claimedCommit !== "string" || !FULL_SHA.test(claimedCommit)) {
    throw new Error("attestation candidate provenance unverifiable");
  }
  // Re-derive the protected candidate identity from the git checkout at the
  // claimed commit. candidateAt reads union-abi-manifest.json from git and runs
  // it through validateDomainCoreCandidateIdentity, so a forged or
  // digest-substituted attestation tuple that disagrees with the committed Rust
  // core closure fails here. A non-existent or unreadable candidate commit is
  // also fail-closed under the same provenance-unverifiable error.
  let verifiedCandidate;
  try {
    verifiedCandidate = candidateAt(repoRoot, claimedCommit);
  } catch {
    throw new Error("attestation candidate provenance unverifiable");
  }
  if (
    verifiedCandidate.candidateCommit !== claimedCandidate.candidateCommit ||
    verifiedCandidate.coreVersion !== claimedCandidate.coreVersion ||
    verifiedCandidate.abiVersion !== claimedCandidate.abiVersion ||
    verifiedCandidate.sourceSha256 !== claimedCandidate.sourceSha256
  ) {
    throw new Error("attestation candidate provenance unverifiable");
  }
  // Bind the provenance to the single protected signer workflow and run
  // coordinates already established by the promotion-proof pipeline. This
  // rejects wrong-workflow, wrong-run, and unsigned-or-substituted provenance
  // without inventing a parallel authority.
  const provenance = attestation?.provenance;
  if (
    !provenance ||
    typeof provenance !== "object" ||
    Array.isArray(provenance)
  ) {
    throw new Error("attestation candidate provenance unverifiable");
  }
  if (provenance.signerWorkflow !== DOMAIN_CORE_PROTECTED_SIGNER_WORKFLOW) {
    throw new Error("attestation workflow mismatch");
  }
  if (
    !Number.isSafeInteger(provenance.signerRunId) ||
    provenance.signerRunId < 1 ||
    !Number.isSafeInteger(provenance.signerRunAttempt) ||
    provenance.signerRunAttempt < 1
  ) {
    throw new Error("attestation signer run mismatch");
  }
  if (
    typeof provenance.trustedMainCommit !== "string" ||
    !FULL_SHA.test(provenance.trustedMainCommit)
  ) {
    throw new Error("attestation candidate provenance unverifiable");
  }
  // The trusted-main evaluator must be a real ancestor of the candidate so the
  // policy/evaluator digests the provenance binds are anchored to a commit the
  // candidate descends from.
  try {
    execFileSync("git", [
      "-C",
      repoRoot,
      "merge-base",
      "--is-ancestor",
      provenance.trustedMainCommit,
      verifiedCandidate.candidateCommit,
    ]);
  } catch {
    throw new Error("attestation candidate provenance unverifiable");
  }
  // Bind the provenance policy and evaluator digests to the trusted-main
  // commit's committed bytes, mirroring the Python gate's
  // file_sha256_at_commit checks. This rejects digest-substituted provenance.
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
    typeof provenance.policySha256 !== "string" ||
    provenance.policySha256 !== policyDigest ||
    typeof provenance.evaluatorSha256 !== "string" ||
    provenance.evaluatorSha256 !== evaluatorDigest
  ) {
    throw new Error("attestation source digest mismatch");
  }
  // When the full artifact-identity gate is requested (CI default), the
  // verified candidate's source digest must match the re-derived source
  // fingerprint produced by the union gate. Offline deterministic tests pass
  // verifyArtifactIdentity: false to use this same provenance binding without
  // requiring the python union gate against a synthetic repository.
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

function sha256GitBlob(repoRoot, revision, path) {
  try {
    const blob = git(repoRoot, ["show", `${revision}:${path}`]);
    return createHash("sha256").update(blob).digest("hex");
  } catch {
    throw new Error("attestation candidate provenance unverifiable");
  }
}

export function resolveActiveDomainCoreActivation({
  repoRoot,
  activationCommit,
  verifyArtifactIdentity = true,
}) {
  const releaseCommit = commit(activationCommit, "activation commit");
  requireCleanCheckout(repoRoot);
  const profiles = JSON.parse(
    readFileSync(
      join(repoRoot, "config/domain-core-build-profiles.json"),
      "utf8",
    ),
  );
  const ledger = JSON.parse(
    readFileSync(
      join(repoRoot, "config/domain-core-legacy-deletion.json"),
      "utf8",
    ),
  );
  const rows = new Map(ledger.rows.map((row) => [row.id, row]));
  const candidates = new Set();
  const domains = [];
  for (const [domain, rowIds] of Object.entries(DOMAIN_ROWS)) {
    if (profiles.profiles?.["public-production"]?.modes?.[domain] !== "rust")
      continue;
    for (const rowId of rowIds) {
      const row = rows.get(rowId);
      const pointer = row?.receipts?.promotion;
      if (typeof pointer !== "string") {
        throw new Error(
          `${domain}: Rust activation is missing promotion receipt for ${rowId}`,
        );
      }
      const receipt = JSON.parse(readFileSync(join(repoRoot, pointer), "utf8"));
      const attestationPath = receipt.promotionAttestation?.path;
      if (typeof attestationPath !== "string" || attestationPath.length === 0) {
        throw new Error(
          `${domain}: Rust activation promotion receipt must reference an attestation`,
        );
      }
      const attestation = JSON.parse(
        readFileSync(join(repoRoot, attestationPath), "utf8"),
      );
      const { verifiedCandidate, provenance } =
        verifyProtectedAttestationProvenance({
          repoRoot,
          attestation,
          verifyArtifactIdentity,
        });
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
  if (candidates.size === 0) {
    return {
      ...validateDomainCoreActivation({
        repoRoot,
        candidateCommit: releaseCommit,
        activationCommit: releaseCommit,
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
      activationCommit: releaseCommit,
    }),
    domains,
  };
}