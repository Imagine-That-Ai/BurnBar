import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
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
  assert.deepEqual(result.domains, []);
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
  const sha256GitBlob = (revision, path) =>
    createHash("sha256")
      .update(git(root, "show", `${revision}:${path}`))
      .digest("hex");
  const attest = (domain, generation, candidate) => {
    const scope = domain === "cloudVault" ? "cloudvault" : domain;
    const manifest = JSON.parse(
      git(root, "show", `${candidate}:crates/openburnbar-domain-core/union-abi-manifest.json`),
    );
    const attestationPath = `config/domain-core-promotion-attestations/${scope}/${generation}.json`;
    mkdirSync(join(root, attestationPath, ".."), { recursive: true });
    writeFileSync(
      join(root, attestationPath),
      JSON.stringify({
        candidate: {
          candidateCommit: candidate,
          coreVersion: manifest.coreVersion,
          abiVersion: manifest.abiVersion,
          sourceSha256: manifest.sourceSha256,
        },
        unsignedBundle: {
          path: `config/domain-core-promotion-bundles/${scope}/${generation}.json`,
        },
        provenance: {
          path: `config/domain-core-promotion-provenance/${scope}/${generation}.json`,
          signerWorkflow: ".github/workflows/domain-core-promotion-proof.yml",
          signerRunId: generation,
          signerRunAttempt: 1,
          trustedMainCommit: candidate,
          policySha256: sha256GitBlob(
            candidate,
            "config/domain-core-promotion-policy.json",
          ),
          evaluatorSha256: sha256GitBlob(
            candidate,
            "scripts/lib/domain-core-deterministic-candidate-bundle.mjs",
          ),
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
  mkdirSync(join(root, "scripts/lib"), { recursive: true });
  writeFileSync(
    join(root, "config/domain-core-promotion-policy.json"),
    JSON.stringify({ schemaVersion: 3, authority: "unsigned-candidate-evaluation" }),
  );
  writeFileSync(
    join(root, "scripts/lib/domain-core-deterministic-candidate-bundle.mjs"),
    "// deterministic candidate bundle evaluator (test fixture)\n",
  );
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
    verifyArtifactIdentity: false,
  });
  assert.equal(resolved.candidateCommit, candidateOne);
  assert.deepEqual(resolved.domains.map(({ domain }) => domain), ["quota"]);

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
    verifyArtifactIdentity: false,
  });
  assert.equal(resolved.candidateCommit, candidateTwo);
  assert.deepEqual(
    resolved.domains.map(({ domain }) => domain),
    ["quota", "cloudVault"],
  );
});

// ---------------------------------------------------------------------------
// Adversarial attestation-authority tests (PR #1820 review blockers).
//
// resolveActiveDomainCoreActivation must reject forged, unsigned, or
// unverified promotion attestation material even when the candidate ancestry,
// the identity tuple, and the allowlisted C..P path set all match.  The
// attestation JSON on disk is attacker-writable; the resolver must re-derive
// candidate truth from the git checkout's own protected substrate and fail
// closed when the attestation claim disagrees.
//
// Every test passes verifyArtifactIdentity: false so the offline synthetic
// repo does not need the live python union gate; the committed-coordinate
// binding added by the fix still fires.
// ---------------------------------------------------------------------------

const SIGNER_WORKFLOW = ".github/workflows/domain-core-promotion-proof.yml";

function sha256GitBlob(root, revision, path) {
  return createHash("sha256")
    .update(git(root, "show", `${revision}:${path}`))
    .digest("hex");
}

function activationAuthorityFixture() {
  const root = mkdtempSync(join(tmpdir(), "domain-core-attest-authority-"));
  mkdirSync(join(root, "crates/openburnbar-domain-core"), { recursive: true });
  mkdirSync(join(root, "config"), { recursive: true });
  mkdirSync(join(root, "scripts/lib"), { recursive: true });
  const rowIds = [
    "quota.claude_statusline",
    "quota.codex_usage",
    "quota.cursor_usage",
    "quota.anthropic_headers",
  ];
  const ledger = {
    rows: rowIds.map((id) => ({ id, authorityGeneration: 0, receipts: {} })),
  };
  const profile = {
    profiles: {
      "public-production": {
        artifactAuthority: "signed",
        distribution: "public",
        rolloutChannel: "stable",
        evidenceEnabled: true,
        modes: { quota: "legacy" },
      },
    },
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
  const manifest = {
    coreVersion: "0.3.0",
    abiVersion: 3,
    sourceSha256: "a".repeat(64),
  };
  writeFileSync(
    join(root, "crates/openburnbar-domain-core/union-abi-manifest.json"),
    JSON.stringify(manifest),
  );
  writeFileSync(
    join(root, "config/domain-core-promotion-policy.json"),
    JSON.stringify({
      schemaVersion: 3,
      authority: "unsigned-candidate-evaluation",
    }),
  );
  writeFileSync(
    join(root, "scripts/lib/domain-core-deterministic-candidate-bundle.mjs"),
    "// deterministic candidate bundle evaluator (test fixture)\n",
  );
  writeState();
  git(root, "init", "-q");
  git(root, "config", "user.email", "test@openburnbar.invalid");
  git(root, "config", "user.name", "OpenBurnBar Test");
  git(root, "add", ".");
  git(root, "commit", "-qm", "candidate C");
  const candidate = git(root, "rev-parse", "HEAD");
  const policySha256 = sha256GitBlob(
    root,
    candidate,
    "config/domain-core-promotion-policy.json",
  );
  const evaluatorSha256 = sha256GitBlob(
    root,
    candidate,
    "scripts/lib/domain-core-deterministic-candidate-bundle.mjs",
  );
  const attestationPath = "config/domain-core-promotion-attestations/quota/1.json";
  function buildValidAttestation(commit) {
    return {
      candidate: {
        candidateCommit: commit,
        coreVersion: manifest.coreVersion,
        abiVersion: manifest.abiVersion,
        sourceSha256: manifest.sourceSha256,
      },
      unsignedBundle: {
        path: "config/domain-core-promotion-bundles/quota/1.json",
      },
      provenance: {
        path: "config/domain-core-promotion-provenance/quota/1.json",
        signerWorkflow: SIGNER_WORKFLOW,
        signerRunId: 1,
        signerRunAttempt: 1,
        trustedMainCommit: commit,
        policySha256,
        evaluatorSha256,
      },
    };
  }
  function writeAttestation(attestation) {
    mkdirSync(join(root, attestationPath, ".."), { recursive: true });
    writeFileSync(join(root, attestationPath), JSON.stringify(attestation));
    for (const id of rowIds) {
      const row = ledger.rows.find((item) => item.id === id);
      row.authorityGeneration = 1;
      const receiptPath = `config/domain-core-legacy-deletion-receipts/${id}/1/promotion.json`;
      mkdirSync(join(root, receiptPath, ".."), { recursive: true });
      writeFileSync(
        join(root, receiptPath),
        JSON.stringify({ promotionAttestation: { path: attestationPath } }),
      );
      row.receipts = { promotion: receiptPath };
    }
  }
  profile.profiles["public-production"].modes.quota = "rust";
  writeAttestation(buildValidAttestation(candidate));
  writeState();
  git(root, "add", ".");
  git(root, "commit", "-qm", "activation P");
  const activation = git(root, "rev-parse", "HEAD");
  return {
    root,
    candidate,
    activation,
    attestationPath,
    buildValidAttestation,
    writeAttestation,
    manifest,
    policySha256,
    evaluatorSha256,
  };
}

function readJson(root, relPath) {
  return JSON.parse(readFileSync(join(root, relPath), "utf8"));
}

function writeJson(root, relPath, value) {
  writeFileSync(join(root, relPath), JSON.stringify(value));
}

function recommit(root) {
  git(root, "add", ".");
  git(root, "commit", "-qm", "tampered attestation material");
  return git(root, "rev-parse", "HEAD");
}

function resolve(root, activation) {
  return resolveActiveDomainCoreActivation({
    repoRoot: root,
    activationCommit: activation,
    verifyArtifactIdentity: false,
  });
}

test("rejects attestation with a forged candidate commit even when ancestry and identity match", () => {
  const fx = activationAuthorityFixture();
  const attestation = readJson(fx.root, fx.attestationPath);
  // Swap the candidate commit for a plausible-but-wrong 40-hex SHA that does
  // not exist in the repo.  The checkout's real candidate ancestry is
  // untouched, so ancestry and identity-tuple checks would pass on their own.
  // The resolver must reject because the attestation claim disagrees with the
  // git-derived protected candidate.
  attestation.candidate.candidateCommit = "f".repeat(40);
  writeJson(fx.root, fx.attestationPath, attestation);
  const activation = recommit(fx.root);
  assert.throws(() => resolve(fx.root, activation), /attestation /u);
});

test("rejects attestation with a forged candidate identity tuple", () => {
  const fx = activationAuthorityFixture();
  const attestation = readJson(fx.root, fx.attestationPath);
  // The candidate commit is correct, but the identity tuple is wrong — the
  // sourceSha256 does not match the manifest at that commit.
  attestation.candidate.sourceSha256 = "b".repeat(64);
  writeJson(fx.root, fx.attestationPath, attestation);
  const activation = recommit(fx.root);
  assert.throws(
    () => resolve(fx.root, activation),
    /attestation candidate provenance unverifiable/u,
  );
});

test("rejects attestation with a non-integer signer run id", () => {
  const fx = activationAuthorityFixture();
  const attestation = readJson(fx.root, fx.attestationPath);
  attestation.provenance.signerRunId = 0;
  writeJson(fx.root, fx.attestationPath, attestation);
  const activation = recommit(fx.root);
  assert.throws(
    () => resolve(fx.root, activation),
    /attestation signer run/u,
  );
});

test("rejects attestation with a non-integer signer run attempt", () => {
  const fx = activationAuthorityFixture();
  const attestation = readJson(fx.root, fx.attestationPath);
  attestation.provenance.signerRunAttempt = "1";
  writeJson(fx.root, fx.attestationPath, attestation);
  const activation = recommit(fx.root);
  assert.throws(
    () => resolve(fx.root, activation),
    /attestation signer run/u,
  );
});

test("rejects attestation with a wrong signer workflow", () => {
  const fx = activationAuthorityFixture();
  const attestation = readJson(fx.root, fx.attestationPath);
  attestation.provenance.signerWorkflow =
    ".github/workflows/attacker-signer.yml";
  writeJson(fx.root, fx.attestationPath, attestation);
  const activation = recommit(fx.root);
  assert.throws(
    () => resolve(fx.root, activation),
    /attestation workflow mismatch/u,
  );
});

test("rejects attestation with a forged trusted-main commit", () => {
  const fx = activationAuthorityFixture();
  const attestation = readJson(fx.root, fx.attestationPath);
  // Point trustedMainCommit at a non-existent commit.
  attestation.provenance.trustedMainCommit = "e".repeat(40);
  writeJson(fx.root, fx.attestationPath, attestation);
  const activation = recommit(fx.root);
  assert.throws(
    () => resolve(fx.root, activation),
    /attestation candidate provenance unverifiable/u,
  );
});

test("rejects attestation with a tampered policy digest", () => {
  const fx = activationAuthorityFixture();
  const attestation = readJson(fx.root, fx.attestationPath);
  attestation.provenance.policySha256 = "0".repeat(64);
  writeJson(fx.root, fx.attestationPath, attestation);
  const activation = recommit(fx.root);
  assert.throws(
    () => resolve(fx.root, activation),
    /attestation source digest mismatch/u,
  );
});

test("rejects attestation with a tampered evaluator digest", () => {
  const fx = activationAuthorityFixture();
  const attestation = readJson(fx.root, fx.attestationPath);
  attestation.provenance.evaluatorSha256 = "0".repeat(64);
  writeJson(fx.root, fx.attestationPath, attestation);
  const activation = recommit(fx.root);
  assert.throws(
    () => resolve(fx.root, activation),
    /attestation source digest mismatch/u,
  );
});

test("rejects attestation that omits the candidate binding entirely", () => {
  const fx = activationAuthorityFixture();
  const attestation = readJson(fx.root, fx.attestationPath);
  delete attestation.candidate;
  writeJson(fx.root, fx.attestationPath, attestation);
  const activation = recommit(fx.root);
  assert.throws(
    () => resolve(fx.root, activation),
    /attestation candidate provenance unverifiable/u,
  );
});

test("rejects attestation that omits the provenance binding entirely", () => {
  const fx = activationAuthorityFixture();
  const attestation = readJson(fx.root, fx.attestationPath);
  delete attestation.provenance;
  writeJson(fx.root, fx.attestationPath, attestation);
  const activation = recommit(fx.root);
  assert.throws(
    () => resolve(fx.root, activation),
    /attestation candidate provenance unverifiable/u,
  );
});

test("rejects forged attestation material even when ancestry, identity tuple, and allowlisted C..P path set match", () => {
  // The comprehensive bypass: every secondary gate is satisfied.
  //   - Candidate ancestry: the forged candidate is an ancestor of activation.
  //   - Identity tuple: coreVersion/abiVersion/sourceSha256 match the manifest.
  //   - Allowlisted paths: only config/domain-core-* files changed.
  // Yet the attestation material is forged — the candidate commit in the
  // attestation JSON is swapped for a divergent commit whose manifest differs
  // from the attestation's claimed identity tuple.  Without attestation
  // provenance verification the resolver would accept this; the fix must fail
  // closed because candidateAt at the forged commit re-derives a different
  // identity tuple than the attestation claims.
  const fx = activationAuthorityFixture();
  // Create a divergent commit with a different manifest so the forged
  // candidate's git-derived identity disagrees with the attestation's claim.
  writeFileSync(
    join(fx.root, "crates/openburnbar-domain-core/union-abi-manifest.json"),
    JSON.stringify({
      coreVersion: "0.4.0",
      abiVersion: 4,
      sourceSha256: "b".repeat(64),
    }),
  );
  git(fx.root, "add", ".");
  git(fx.root, "commit", "-qm", "divergent candidate with different manifest");
  const decoyCandidate = git(fx.root, "rev-parse", "HEAD");
  // Forge the attestation to claim the decoy candidate but keep the original
  // identity tuple — the resolver must reject because candidateAt at the
  // decoy returns 0.4.0/4/b... which disagrees with the attestation's
  // 0.3.0/3/a... claim.
  const attestation = readJson(fx.root, fx.attestationPath);
  attestation.candidate.candidateCommit = decoyCandidate;
  writeJson(fx.root, fx.attestationPath, attestation);
  const activation = recommit(fx.root);
  assert.throws(
    () => resolve(fx.root, activation),
    /attestation candidate provenance unverifiable/u,
  );
});
