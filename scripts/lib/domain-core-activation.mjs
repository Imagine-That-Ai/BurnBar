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
  activationCommit,
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
      const attestation = JSON.parse(
        readFileSync(join(repoRoot, receipt.promotionAttestation.path), "utf8"),
      );
      candidates.add(attestation.candidate?.candidateCommit);
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
