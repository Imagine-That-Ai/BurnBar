import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  resolveActiveDomainCoreActivation,
  validateDomainCoreActivation,
} from "./domain-core-activation.mjs";

function git(root, ...args) {
  return execFileSync("git", ["-C", root, ...args], {
    encoding: "utf8",
  }).trim();
}

function fixture() {
  const root = mkdtempSync(join(tmpdir(), "domain-core-activation-"));
  mkdirSync(join(root, "crates/openburnbar-domain-core"), { recursive: true });
  mkdirSync(join(root, "config"), { recursive: true });
  writeFileSync(
    join(root, "crates/openburnbar-domain-core/union-abi-manifest.json"),
    JSON.stringify({
      coreVersion: "0.3.0",
      abiVersion: 3,
      sourceSha256: "a".repeat(64),
    }),
  );
  writeFileSync(
    join(root, "config/domain-core-build-profiles.json"),
    "legacy\n",
  );
  writeFileSync(
    join(root, "config/domain-core-legacy-deletion.json"),
    "rollout\n",
  );
  git(root, "init", "-q");
  git(root, "config", "user.email", "test@openburnbar.invalid");
  git(root, "config", "user.name", "OpenBurnBar Test");
  git(root, "add", ".");
  git(root, "commit", "-qm", "candidate C");
  const candidate = git(root, "rev-parse", "HEAD");
  writeFileSync(join(root, "config/domain-core-build-profiles.json"), "rust\n");
  writeFileSync(
    join(root, "config/domain-core-legacy-deletion.json"),
    "promotion receipt\n",
  );
  git(root, "add", ".");
  git(root, "commit", "-qm", "activation P");
  return { root, candidate, activation: git(root, "rev-parse", "HEAD") };
}

const QUOTA_ROWS = [
  "quota.claude_statusline",
  "quota.codex_usage",
  "quota.cursor_usage",
  "quota.anthropic_headers",
];
const PROFILE_DOMAINS = [
  "quota",
  "cloudVault",
  "cloudVaultRewrap",
  "cloudVaultSearch",
  "hermes",
  "pricing",
];

function releaseEpochFixture({
  stableCandidateCommit,
  divergentStableActivation = false,
  disagreeStableActivation = false,
  mutateDeletion,
} = {}) {
  const root = mkdtempSync(join(tmpdir(), "domain-core-release-epoch-"));
  mkdirSync(join(root, "crates/openburnbar-domain-core"), { recursive: true });
  mkdirSync(join(root, "config"), { recursive: true });
  const manifest = {
    coreVersion: "0.3.0",
    abiVersion: 3,
    sourceSha256: "a".repeat(64),
  };
  const profile = {
    profiles: {
      "public-production": {
        artifactAuthority: "signed",
        distribution: "public",
        rolloutChannel: "stable",
        evidenceEnabled: true,
        modes: Object.fromEntries(
          PROFILE_DOMAINS.map((domain) => [domain, "legacy"]),
        ),
      },
    },
  };
  const ledger = {
    rows: QUOTA_ROWS.map((id) => ({
      id,
      state: "rollout",
      authorityGeneration: 0,
      receipts: {},
    })),
  };
  const writeState = () => {
    writeFileSync(
      join(root, "crates/openburnbar-domain-core/union-abi-manifest.json"),
      JSON.stringify(manifest),
    );
    writeFileSync(
      join(root, "config/domain-core-build-profiles.json"),
      JSON.stringify(profile),
    );
    writeFileSync(
      join(root, "config/domain-core-legacy-deletion.json"),
      JSON.stringify(ledger),
    );
  };
  const commitAll = (message) => {
    git(root, "add", ".");
    git(root, "commit", "-qm", message);
    return git(root, "rev-parse", "HEAD");
  };

  writeState();
  git(root, "init", "-q");
  git(root, "config", "user.email", "test@openburnbar.invalid");
  git(root, "config", "user.name", "OpenBurnBar Test");
  const candidate = commitAll("candidate C");
  const candidateIdentity = { candidateCommit: candidate, ...manifest };

  profile.profiles["public-production"].modes.quota = "rust";
  for (const [index, row] of ledger.rows.entries()) {
    const attestationPath =
      "config/domain-core-promotion-attestations/quota/1.json";
    const promotionPath = `config/domain-core-legacy-deletion-receipts/${row.id}/1/promotion.json`;
    mkdirSync(join(root, promotionPath, ".."), { recursive: true });
    mkdirSync(join(root, attestationPath, ".."), { recursive: true });
    writeFileSync(
      join(root, attestationPath),
      JSON.stringify({
        candidate: candidateIdentity,
        unsignedBundle: { path: "config/bundles/quota/1.json" },
        provenance: {
          path: "config/provenance/quota/1.json",
          signerRunId: 100 + index,
          signerRunAttempt: 1,
        },
      }),
    );
    writeFileSync(
      join(root, promotionPath),
      JSON.stringify({ promotionAttestation: { path: attestationPath } }),
    );
    row.state = "promotion_approved";
    row.authorityGeneration = 1;
    row.receipts = { promotion: promotionPath };
  }
  writeState();
  const activation = commitAll("activation P");
  const activationProof = validateDomainCoreActivation({
    repoRoot: root,
    candidateCommit: candidate,
    activationCommit: activation,
  });
  const alternateStableActivationCommit =
    divergentStableActivation || disagreeStableActivation
      ? git(
          root,
          "commit-tree",
          `${activation}^{tree}`,
          "-p",
          candidate,
          "-m",
          "divergent activation",
        )
      : activation;

  for (const [index, row] of ledger.rows.entries()) {
    const stableActivationCommit =
      divergentStableActivation || (disagreeStableActivation && index === 0)
        ? alternateStableActivationCommit
        : activation;
    const stablePath = `config/domain-core-legacy-deletion-receipts/${row.id}/1/stable_release.json`;
    mkdirSync(join(root, stablePath, ".."), { recursive: true });
    writeFileSync(
      join(root, stablePath),
      JSON.stringify({
        commit: stableActivationCommit,
        release: {
          candidate: {
            ...candidateIdentity,
            candidateCommit: stableCandidateCommit ?? candidate,
          },
          activation: {
            ...activationProof,
            activationCommit: stableActivationCommit,
          },
        },
      }),
    );
    row.state = "rust_authoritative_with_rollback";
    row.receipts.stableRelease = stablePath;
  }
  writeState();
  const stableReceiptCommit = commitAll("stable release receipt");

  for (const row of ledger.rows) {
    const deletionPath = `config/domain-core-legacy-deletion-receipts/${row.id}/1/deletion_review.json`;
    mkdirSync(join(root, deletionPath, ".."), { recursive: true });
    writeFileSync(join(root, deletionPath), JSON.stringify({ approved: true }));
    row.state = "legacy_deleted";
    row.receipts.deletionReview = deletionPath;
  }
  mutateDeletion?.({ manifest, profile, ledger, root });
  writeState();
  const deletion = commitAll("deletion release D");
  return {
    root,
    candidate,
    activation,
    stableReceiptCommit,
    deletion,
  };
}

test("accepts candidate C plus path-restricted activation P", () => {
  const value = fixture();
  const proof = validateDomainCoreActivation({
    repoRoot: value.root,
    candidateCommit: value.candidate,
    activationCommit: value.activation,
  });
  assert.equal(proof.candidateCommit, value.candidate);
  assert.equal(proof.activationCommit, value.activation);
});

test("rejects source changes between candidate and activation", () => {
  const value = fixture();
  writeFileSync(
    join(value.root, "crates/openburnbar-domain-core/new.rs"),
    "fn changed() {}\n",
  );
  git(value.root, "add", ".");
  git(value.root, "commit", "-qm", "forbidden source drift");
  assert.throws(
    () =>
      validateDomainCoreActivation({
        repoRoot: value.root,
        candidateCommit: value.candidate,
        activationCommit: git(value.root, "rev-parse", "HEAD"),
      }),
    /forbidden paths/u,
  );
});

test("rejects activation that changes the attested closure", () => {
  const value = fixture();
  const path = join(
    value.root,
    "crates/openburnbar-domain-core/union-abi-manifest.json",
  );
  writeFileSync(
    path,
    JSON.stringify({
      coreVersion: "0.3.0",
      abiVersion: 3,
      sourceSha256: "b".repeat(64),
    }),
  );
  git(value.root, "add", ".");
  git(value.root, "commit", "-qm", "forbidden identity drift");
  assert.throws(
    () =>
      validateDomainCoreActivation({
        repoRoot: value.root,
        candidateCommit: value.candidate,
        activationCommit: git(value.root, "rev-parse", "HEAD"),
      }),
    /attested Rust core closure/u,
  );
});

test("keeps all-legacy releases valid before the first Rust activation", () => {
  const root = mkdtempSync(join(tmpdir(), "domain-core-preactivation-"));
  mkdirSync(join(root, "crates/openburnbar-domain-core"), { recursive: true });
  mkdirSync(join(root, "config"), { recursive: true });
  writeFileSync(
    join(root, "crates/openburnbar-domain-core/union-abi-manifest.json"),
    JSON.stringify({
      coreVersion: "0.3.0",
      abiVersion: 3,
      sourceSha256: "a".repeat(64),
    }),
  );
  writeFileSync(
    join(root, "config/domain-core-build-profiles.json"),
    JSON.stringify({
      profiles: {
        "public-production": {
          artifactAuthority: "signed",
          distribution: "public",
          rolloutChannel: "stable",
          evidenceEnabled: true,
          modes: Object.fromEntries(
            Object.keys({
              quota: 1,
              cloudVault: 1,
              cloudVaultRewrap: 1,
              cloudVaultSearch: 1,
              hermes: 1,
              pricing: 1,
            }).map((domain) => [domain, "legacy"]),
          ),
        },
      },
    }),
  );
  writeFileSync(
    join(root, "config/domain-core-legacy-deletion.json"),
    JSON.stringify({ rows: [] }),
  );
  git(root, "init", "-q");
  git(root, "config", "user.email", "test@openburnbar.invalid");
  git(root, "config", "user.name", "OpenBurnBar Test");
  git(root, "add", ".");
  git(root, "commit", "-qm", "legacy release");
  const head = git(root, "rev-parse", "HEAD");
  const result = resolveActiveDomainCoreActivation({
    repoRoot: root,
    activationCommit: head,
  });
  assert.equal(result.active, false);
  assert.equal(result.candidateCommit, head);
  assert.equal(result.activationCommit, head);
  assert.equal(result.releaseCommit, head);
  assert.deepEqual(result.domains, []);
});

test("release A resolves candidate C to authority P and release P", () => {
  const value = releaseEpochFixture();
  git(value.root, "checkout", "-q", value.activation);
  const result = resolveActiveDomainCoreActivation({
    repoRoot: value.root,
    activationCommit: value.activation,
  });
  assert.equal(result.candidateCommit, value.candidate);
  assert.equal(result.activationCommit, value.activation);
  assert.equal(result.releaseCommit, value.activation);
});

test("post-deletion release D retains stable authority P", () => {
  const value = releaseEpochFixture();
  const result = resolveActiveDomainCoreActivation({
    repoRoot: value.root,
    activationCommit: value.deletion,
  });
  assert.equal(result.candidateCommit, value.candidate);
  assert.equal(result.activationCommit, value.activation);
  assert.equal(result.releaseCommit, value.deletion);
});

test("rejects post-deletion stable receipts that disagree on candidate", () => {
  const value = releaseEpochFixture({
    stableCandidateCommit: "f".repeat(40),
  });
  assert.throws(
    () =>
      resolveActiveDomainCoreActivation({
        repoRoot: value.root,
        activationCommit: value.deletion,
      }),
    /candidate/u,
  );
});

test("rejects deleted rows that disagree on stable activation P", () => {
  const value = releaseEpochFixture({ disagreeStableActivation: true });
  assert.throws(
    () =>
      resolveActiveDomainCoreActivation({
        repoRoot: value.root,
        activationCommit: value.deletion,
      }),
    /share one stable|authority/u,
  );
});

test("rejects post-deletion release D outside stable authority P ancestry", () => {
  const value = releaseEpochFixture({ divergentStableActivation: true });
  assert.throws(
    () =>
      resolveActiveDomainCoreActivation({
        repoRoot: value.root,
        activationCommit: value.deletion,
      }),
    /ancestor|ancestry/u,
  );
});

test("rejects post-deletion Rust ABI tuple drift at release D", () => {
  const value = releaseEpochFixture({
    mutateDeletion: ({ manifest }) => {
      manifest.sourceSha256 = "b".repeat(64);
    },
  });
  assert.throws(
    () =>
      resolveActiveDomainCoreActivation({
        repoRoot: value.root,
        activationCommit: value.deletion,
      }),
    /closure|candidate|tuple/u,
  );
});

test("rejects deleted Rust authority when public production is no longer Rust", () => {
  const value = releaseEpochFixture({
    mutateDeletion: ({ profile }) => {
      profile.profiles["public-production"].modes.quota = "legacy";
    },
  });
  assert.throws(
    () =>
      resolveActiveDomainCoreActivation({
        repoRoot: value.root,
        activationCommit: value.deletion,
      }),
    /public-production|Rust|profile/u,
  );
});

test("re-attests every active domain across two incremental release epochs", () => {
  const root = mkdtempSync(join(tmpdir(), "domain-core-two-epochs-"));
  mkdirSync(join(root, "crates/openburnbar-domain-core"), { recursive: true });
  mkdirSync(join(root, "config"), { recursive: true });
  const domains = [
    "quota",
    "cloudVault",
    "cloudVaultRewrap",
    "cloudVaultSearch",
    "hermes",
    "pricing",
  ];
  const rowIds = {
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
  };
  const profile = {
    profiles: {
      "public-production": {
        artifactAuthority: "signed",
        distribution: "public",
        rolloutChannel: "stable",
        evidenceEnabled: true,
        modes: Object.fromEntries(domains.map((domain) => [domain, "legacy"])),
      },
    },
  };
  const ledger = {
    rows: Object.values(rowIds)
      .flat()
      .map((id) => ({ id, authorityGeneration: 0, receipts: {} })),
  };
  const writeState = () => {
    writeFileSync(
      join(root, "config/domain-core-build-profiles.json"),
      JSON.stringify(profile),
    );
    writeFileSync(
      join(root, "config/domain-core-legacy-deletion.json"),
      JSON.stringify(ledger),
    );
  };
  const attest = (domain, generation, candidate) => {
    const scope = domain === "cloudVault" ? "cloudvault" : domain;
    const attestationPath = `config/domain-core-promotion-attestations/${scope}/${generation}.json`;
    mkdirSync(join(root, attestationPath, ".."), { recursive: true });
    writeFileSync(
      join(root, attestationPath),
      JSON.stringify({
        candidate: { candidateCommit: candidate },
        unsignedBundle: { path: `config/bundles/${scope}/${generation}.json` },
        provenance: {
          path: `config/provenance/${scope}/${generation}.json`,
          signerRunId: generation,
          signerRunAttempt: 1,
        },
      }),
    );
    for (const id of rowIds[domain]) {
      const row = ledger.rows.find((item) => item.id === id);
      row.authorityGeneration = generation;
      const receiptPath = `config/domain-core-legacy-deletion-receipts/${id}/${generation}/promotion.json`;
      mkdirSync(join(root, receiptPath, ".."), { recursive: true });
      writeFileSync(
        join(root, receiptPath),
        JSON.stringify({ promotionAttestation: { path: attestationPath } }),
      );
      row.receipts = { promotion: receiptPath };
    }
  };
  writeFileSync(
    join(root, "crates/openburnbar-domain-core/union-abi-manifest.json"),
    JSON.stringify({
      coreVersion: "0.3.0",
      abiVersion: 3,
      sourceSha256: "a".repeat(64),
    }),
  );
  writeState();
  git(root, "init", "-q");
  git(root, "config", "user.email", "test@openburnbar.invalid");
  git(root, "config", "user.name", "OpenBurnBar Test");
  git(root, "add", ".");
  git(root, "commit", "-qm", "epoch one candidate C1");
  const candidateOne = git(root, "rev-parse", "HEAD");
  profile.profiles["public-production"].modes.quota = "rust";
  attest("quota", 1, candidateOne);
  writeState();
  git(root, "add", ".");
  git(root, "commit", "-qm", "epoch one activation P1");
  let resolved = resolveActiveDomainCoreActivation({
    repoRoot: root,
    activationCommit: git(root, "rev-parse", "HEAD"),
  });
  assert.equal(resolved.candidateCommit, candidateOne);
  assert.deepEqual(
    resolved.domains.map(({ domain }) => domain),
    ["quota"],
  );

  writeFileSync(
    join(root, "crates/openburnbar-domain-core/union-abi-manifest.json"),
    JSON.stringify({
      coreVersion: "0.4.0",
      abiVersion: 4,
      sourceSha256: "b".repeat(64),
    }),
  );
  git(root, "add", ".");
  git(root, "commit", "-qm", "epoch two candidate C2");
  const candidateTwo = git(root, "rev-parse", "HEAD");
  profile.profiles["public-production"].modes.cloudVault = "rust";
  attest("quota", 2, candidateTwo);
  attest("cloudVault", 1, candidateTwo);
  writeState();
  git(root, "add", ".");
  git(root, "commit", "-qm", "epoch two activation P2");
  resolved = resolveActiveDomainCoreActivation({
    repoRoot: root,
    activationCommit: git(root, "rev-parse", "HEAD"),
  });
  assert.equal(resolved.candidateCommit, candidateTwo);
  assert.deepEqual(
    resolved.domains.map(({ domain }) => domain),
    ["quota", "cloudVault"],
  );
});
