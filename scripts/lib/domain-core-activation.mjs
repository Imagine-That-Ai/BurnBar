import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { join } from "node:path";

import { validateDomainCoreCandidateIdentity } from "./domain-core-candidate-receipt.mjs";

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

export function resolveActiveDomainCoreActivation({
  repoRoot,
  releaseCommit: requestedReleaseCommit,
  activationCommit,
}) {
  if (
    requestedReleaseCommit !== undefined &&
    activationCommit !== undefined &&
    requestedReleaseCommit !== activationCommit
  ) {
    throw new Error("release commit arguments must identify the same commit");
  }
  const releaseCommit = commit(
    requestedReleaseCommit ?? activationCommit,
    "release commit",
  );
  requireCleanCheckout(repoRoot);
  if (git(repoRoot, ["rev-parse", "HEAD"]) !== releaseCommit) {
    throw new Error(
      "release commit must equal the exact release checkout HEAD",
    );
  }
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
  const stableAuthorities = new Map();
  const domains = [];
  for (const [domain, rowIds] of Object.entries(DOMAIN_ROWS)) {
    if (profiles.profiles?.["public-production"]?.modes?.[domain] !== "rust") {
      if (rowIds.some((rowId) => rows.get(rowId)?.state === "legacy_deleted")) {
        throw new Error(
          `${domain}: deleted legacy authority requires public-production mode rust`,
        );
      }
      continue;
    }
    for (const rowId of rowIds) {
      const row = rows.get(rowId);
      const pointer = row?.receipts?.promotion;
      if (typeof pointer !== "string") {
        throw new Error(
          `${domain}: Rust activation is missing promotion receipt for ${rowId}`,
        );
      }
      const receipt = JSON.parse(readFileSync(join(repoRoot, pointer), "utf8"));
      const attestation = JSON.parse(
        readFileSync(join(repoRoot, receipt.promotionAttestation.path), "utf8"),
      );
      candidates.add(attestation.candidate?.candidateCommit);
      if (row.state === "legacy_deleted") {
        const stablePointer = row.receipts?.stableRelease;
        if (typeof stablePointer !== "string") {
          throw new Error(
            `${domain}: deleted row ${rowId} is missing its stable-release authority`,
          );
        }
        const stable = JSON.parse(
          readFileSync(join(repoRoot, stablePointer), "utf8"),
        );
        const stableCandidate = validateDomainCoreCandidateIdentity(
          stable.release?.candidate,
        );
        const stableActivation = stable.release?.activation;
        const stableCandidateCommit = stableCandidate?.candidateCommit;
        const stableActivationCommit = stableActivation?.activationCommit;
        if (
          stableCandidateCommit !== attestation.candidate?.candidateCommit ||
          stableActivation?.candidateCommit !== stableCandidateCommit ||
          stable.commit !== stableActivationCommit ||
          typeof stableActivationCommit !== "string"
        ) {
          throw new Error(
            `${domain}: stable-release authority does not cross-bind candidate C and activation P`,
          );
        }
        const authorityKey = canonicalSha256({
          candidate: stableCandidate,
          activation: stableActivation,
        });
        stableAuthorities.set(authorityKey, {
          candidate: stableCandidate,
          activation: stableActivation,
        });
      }
      if (!domains.some((item) => item.domain === domain)) {
        domains.push({
          domain,
          rowId,
          promotionReceiptPath: pointer,
          attestationPath: receipt.promotionAttestation.path,
          bundlePath: attestation.unsignedBundle.path,
          provenancePath: attestation.provenance.path,
          signerRunId: attestation.provenance.signerRunId,
          signerRunAttempt: attestation.provenance.signerRunAttempt,
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
      releaseCommit,
      domains: [],
    };
  }
  if (candidates.size !== 1) {
    throw new Error(
      "public Rust profile must resolve to exactly one protected candidate commit",
    );
  }
  const candidateCommit = [...candidates][0];
  if (stableAuthorities.size > 1) {
    throw new Error(
      "deleted public Rust rows must share one stable candidate and activation authority",
    );
  }
  if (stableAuthorities.size === 1) {
    const [{ candidate: stableCandidate, activation: stableActivation }] =
      stableAuthorities.values();
    if (stableCandidate.candidateCommit !== candidateCommit) {
      throw new Error(
        "stable-release candidate differs from the protected promotion candidate",
      );
    }
    const authority = validateDomainCoreActivation({
      repoRoot,
      candidateCommit,
      activationCommit: stableActivation.activationCommit,
      requireHead: false,
    });
    const activationProfiles = gitJson(
      repoRoot,
      authority.activationCommit,
      "config/domain-core-build-profiles.json",
      "activation build profiles",
    );
    for (const { domain } of domains) {
      if (
        activationProfiles.profiles?.["public-production"]?.modes?.[domain] !==
        "rust"
      ) {
        throw new Error(
          `${domain}: stable activation P was not Rust-authoritative`,
        );
      }
    }
    if (
      authority.coreVersion !== stableCandidate.coreVersion ||
      authority.abiVersion !== stableCandidate.abiVersion ||
      authority.sourceSha256 !== stableCandidate.sourceSha256 ||
      authority.coreVersion !== stableActivation.coreVersion ||
      authority.abiVersion !== stableActivation.abiVersion ||
      authority.sourceSha256 !== stableActivation.sourceSha256 ||
      authority.changedPathsSha256 !== stableActivation.changedPathsSha256
    ) {
      throw new Error(
        "stable-release activation does not match the repository-derived C to P authority",
      );
    }
    try {
      execFileSync("git", [
        "-C",
        repoRoot,
        "merge-base",
        "--is-ancestor",
        authority.activationCommit,
        releaseCommit,
      ]);
    } catch {
      throw new Error(
        "stable activation P must be an ancestor of release commit D",
      );
    }
    const releaseIdentity = candidateAt(repoRoot, releaseCommit);
    if (
      releaseIdentity.coreVersion !== authority.coreVersion ||
      releaseIdentity.abiVersion !== authority.abiVersion ||
      releaseIdentity.sourceSha256 !== authority.sourceSha256
    ) {
      throw new Error("release commit changed the attested Rust core closure");
    }
    return {
      active: true,
      ...authority,
      releaseCommit,
      domains,
    };
  }
  return {
    active: true,
    ...validateDomainCoreActivation({
      repoRoot,
      candidateCommit,
      activationCommit: releaseCommit,
    }),
    releaseCommit,
    domains,
  };
}
