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
  });
  assert.equal(resolved.candidateCommit, candidateTwo);
  assert.deepEqual(
    resolved.domains.map(({ domain }) => domain),
    ["quota", "cloudVault"],
  );
});
// ---------------------------------------------------------------------------
// Exact-byte digest parity + unsignedBundle/provenance artifact-integrity
// tests (PR #1820 exact-head review blockers).
//
// sha256GitBlob must hash the EXACT git-blob bytes (no .trim()), so a
// newline-terminated policy/evaluator file binds to its newline-inclusive
// digest, matching the authoritative Python file_sha256_at_commit.  The
// pre-fix git() helper returned a .trim()-ed UTF-8 string, so a trailing
// newline was stripped and the gate silently accepted the trimmed digest.
//
// verifyProtectedAttestationProvenance must validate unsignedBundle.path /
// provenance.path against a secure repo-relative resolver and, when the
// respective .sha256 field is present, validate it against the exact
// working-tree file bytes read via O_NOFOLLOW.  Pre-fix the resolver trusted
// those paths and any claimed digest without reading a byte; a tampered,
// traversed, or symlink-substituted artifact sailed through.
//
// The .sha256 verification is conditional on presence (mirrors the gate
// without breaking the 18 ancestry/authority fixtures that omit it); path
// shape is unconditional.  These tests set the .sha256 fields and write the
// backing files to exercise the new contract.
// ---------------------------------------------------------------------------

// Exact-bytes git-blob digest: reads `git show` as a raw Buffer (no text
// decoding, no .trim()), mirroring the post-fix production sha256GitBlob.
// Contrast with the file-scoped sha256GitBlob helper (line 354) which still
// uses git() -> .trim(); that helper reproduces the PRE-FIX trimmed digest.
function sha256ExactGitBlob(root, revision, path) {
  const blob = execFileSync("git", ["-C", root, "show", `${revision}:${path}`]);
  return createHash("sha256").update(blob).digest("hex");
}

function sha256Bytes(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

// Apply a mutation to the attestation JSON in place, recommit the working
// tree, and return the new activation commit.
function recommitWith(root, mutator) {
  const fx = { root, attestationPath: undefined };
  // Read the current attestation, mutate, and recommit.  Caller supplies the
  // attestation path via the returned closure below.
  return function apply(attestationPath, mutatorFn) {
    const attestation = readJson(root, attestationPath);
    mutatorFn(attestation);
    writeJson(root, attestationPath, attestation);
    return recommit(root);
  };
}

// ---------------------------------------------------------------------------
// Exact-byte digest parity for newline-terminated policy/evaluator blobs.
// The authority fixture's evaluator file ends in "\n"; the policy file
// (JSON.stringify, no trailing newline) is the control that both digests
// agree on.  These pin the newline-inclusive contract.
// ---------------------------------------------------------------------------

test("rejects attestation whose evaluator digest is the trimmed (newline-stripped) digest of a newline-terminated evaluator", () => {
  const fx = activationAuthorityFixture();
  // The fixture's evaluator blob ends in "\n".  The pre-fix production
  // sha256GitBlob trimmed it, so the file-scoped test helper (which also
  // trims) yields the PRE-FIX digest.  The post-fix gate hashes the exact
  // bytes and must reject the trimmed digest as a source-digest mismatch.
  const trimmedEvaluator = sha256GitBlob(
    fx.root,
    fx.candidate,
    "scripts/lib/domain-core-deterministic-candidate-bundle.mjs",
  );
  const attestation = readJson(fx.root, fx.attestationPath);
  attestation.provenance.policySha256 = fx.policySha256;
  attestation.provenance.evaluatorSha256 = trimmedEvaluator;
  writeJson(fx.root, fx.attestationPath, attestation);
  const activation = recommit(fx.root);
  // Pre-fix: production also trimmed -> trimmed == trimmed -> ACCEPTS (red).
  // Post-fix: production exact -> trimmed != exact -> rejects (green).
  assert.throws(
    () => resolve(fx.root, activation),
    /attestation source digest mismatch/u,
  );
});

test("accepts attestation whose evaluator digest is the exact (newline-inclusive) digest of a newline-terminated evaluator", () => {
  const fx = activationAuthorityFixture();
  // Exact bytes (Buffer, no trim) of the newline-terminated evaluator.
  const exactEvaluator = sha256ExactGitBlob(
    fx.root,
    fx.candidate,
    "scripts/lib/domain-core-deterministic-candidate-bundle.mjs",
  );
  const attestation = readJson(fx.root, fx.attestationPath);
  attestation.provenance.policySha256 = fx.policySha256;
  attestation.provenance.evaluatorSha256 = exactEvaluator;
  writeJson(fx.root, fx.attestationPath, attestation);
  const activation = recommit(fx.root);
  // Pre-fix: production trimmed -> exact != trimmed -> rejects (red).
  // Post-fix: production exact -> exact == exact -> accepts (green).
  const resolved = resolve(fx.root, activation);
  assert.equal(resolved.active, true);
  assert.equal(resolved.candidateCommit, fx.candidate);
});

test("rejects attestation whose policy digest is the trimmed digest when the policy blob is newline-terminated", () => {
  const fx = activationAuthorityFixture();
  // Rewrite the policy file with a trailing newline so the trimmed vs exact
  // digests diverge, then recommit the candidate so the trusted-main bytes
  // carry the newline.  Rebuild the fixture's activation on top.
  const policyRel = "config/domain-core-promotion-policy.json";
  const policyObj = { schemaVersion: 3, authority: "unsigned-candidate-evaluation" };
  writeFileSync(join(fx.root, policyRel), JSON.stringify(policyObj) + "\n");
  git(fx.root, "add", ".");
  git(fx.root, "commit", "-qm", "newline-terminated policy");
  const trustedMain = git(fx.root, "rev-parse", "HEAD");
  const trimmedPolicy = sha256GitBlob(fx.root, trustedMain, policyRel);
  const exactPolicy = sha256ExactGitBlob(fx.root, trustedMain, policyRel);
  // Sanity: the two must diverge or the test has no lever.
  assert.notEqual(trimmedPolicy, exactPolicy);
  const exactEvaluator = sha256ExactGitBlob(
    fx.root,
    trustedMain,
    "scripts/lib/domain-core-deterministic-candidate-bundle.mjs",
  );
  const attestation = readJson(fx.root, fx.attestationPath);
  attestation.candidate.candidateCommit = fx.candidate;
  attestation.provenance.trustedMainCommit = trustedMain;
  attestation.provenance.policySha256 = trimmedPolicy;
  attestation.provenance.evaluatorSha256 = exactEvaluator;
  writeJson(fx.root, fx.attestationPath, attestation);
  const activation = recommit(fx.root);
  assert.throws(
    () => resolve(fx.root, activation),
    /attestation source digest mismatch/u,
  );
});

// ---------------------------------------------------------------------------
// unsignedBundle.sha256 / provenance.sha256 artifact-integrity verification.
// The fix reads the exact working-tree bytes at the secure path and rejects a
// digest or file-byte mismatch.  These prove the gate validates the artifacts
// the resolver later trusts as bundlePath / provenancePath.
// ---------------------------------------------------------------------------

// Write a bundle + provenance file at the attested paths and set the matching
// exact-byte sha256 fields on a copy of the authority fixture's attestation.
function attestWithArtifacts(fx, { bundleBytes, provenanceBytes } = {}) {
  const bundleRel = "config/domain-core-promotion-bundles/quota/1.json";
  const provenanceRel = "config/domain-core-promotion-provenance/quota/1.json";
  const bundle = Buffer.from(bundleBytes ?? "{\"bundle\":\"quota-1\"}");
  const provenance = Buffer.from(provenanceBytes ?? "{\"provenance\":\"quota-1\"}");
  mkdirSync(join(fx.root, bundleRel, ".."), { recursive: true });
  mkdirSync(join(fx.root, provenanceRel, ".."), { recursive: true });
  writeFileSync(join(fx.root, bundleRel), bundle);
  writeFileSync(join(fx.root, provenanceRel), provenance);
  git(fx.root, "add", ".");
  git(fx.root, "commit", "-qm", "stage bundle+provenance artifacts");
  const activation = git(fx.root, "rev-parse", "HEAD");
  const attestation = readJson(fx.root, fx.attestationPath);
  attestation.unsignedBundle.path = bundleRel;
  attestation.unsignedBundle.sha256 = sha256Bytes(bundle);
  attestation.provenance.path = provenanceRel;
  attestation.provenance.sha256 = sha256Bytes(provenance);
  writeJson(fx.root, fx.attestationPath, attestation);
  return recommit(fx.root);
}

test("accepts attestation with matching unsignedBundle.sha256 and provenance.sha256 over real artifact files", () => {
  const fx = activationAuthorityFixture();
  const activation = attestWithArtifacts(fx);
  // Post-fix: both digests match the exact file bytes -> accepts (green).
  // Pre-fix: the fields are ignored entirely -> also accepts (so this is a
  // guard against regressions, paired with the tamper tests below).
  const resolved = resolve(fx.root, activation);
  assert.equal(resolved.active, true);
  assert.equal(resolved.candidateCommit, fx.candidate);
});

test("rejects attestation whose unsignedBundle.sha256 disagrees with the bundle file bytes", () => {
  const fx = activationAuthorityFixture();
  const activation = attestWithArtifacts(fx);
  // Tamper only the claimed unsignedBundle.sha256 to a valid-but-wrong
  // 64-hex digest.  Pre-fix: ignored -> accepts (red).  Post-fix: reads the
  // bundle bytes and rejects with the specific mismatch (green).
  const attestation = readJson(fx.root, fx.attestationPath);
  attestation.unsignedBundle.sha256 = "c".repeat(64);
  writeJson(fx.root, fx.attestationPath, attestation);
  const tamperedActivation = recommit(fx.root);
  assert.throws(
    () => resolve(fx.root, tamperedActivation),
    /attestation unsigned bundle digest mismatch/u,
  );
});

test("rejects attestation whose provenance.sha256 disagrees with the provenance file bytes", () => {
  const fx = activationAuthorityFixture();
  const activation = attestWithArtifacts(fx);
  const attestation = readJson(fx.root, fx.attestationPath);
  attestation.provenance.sha256 = "d".repeat(64);
  writeJson(fx.root, fx.attestationPath, attestation);
  const tamperedActivation = recommit(fx.root);
  assert.throws(
    () => resolve(fx.root, tamperedActivation),
    /attestation provenance digest mismatch/u,
  );
});

test("rejects attestation whose unsignedBundle.sha256 is not a 64-hex lowercase digest", () => {
  const fx = activationAuthorityFixture();
  attestWithArtifacts(fx);
  const attestation = readJson(fx.root, fx.attestationPath);
  attestation.unsignedBundle.sha256 = "not-a-hex-digest";
  writeJson(fx.root, fx.attestationPath, attestation);
  const activation = recommit(fx.root);
  assert.throws(
    () => resolve(fx.root, activation),
    /attestation candidate provenance unverifiable/u,
  );
});

test("rejects attestation when the bundle file bytes are tampered after the digest was set", () => {
  const fx = activationAuthorityFixture();
  const activation = attestWithArtifacts(fx);
  // Mutate the bundle FILE bytes on disk so the committed sha256 no longer
  // matches the file.  This proves the gate reads the actual file bytes
  // rather than trusting the attested digest.
  const bundleRel = "config/domain-core-promotion-bundles/quota/1.json";
  writeFileSync(join(fx.root, bundleRel), "{\"bundle\":\"TAMPERED\"}");
  git(fx.root, "add", ".");
  git(fx.root, "commit", "-qm", "tamper bundle bytes");
  const tamperedActivation = git(fx.root, "rev-parse", "HEAD");
  assert.throws(
    () => resolve(fx.root, tamperedActivation),
    /attestation unsigned bundle digest mismatch/u,
  );
});

test("rejects attestation when the provenance file bytes are tampered after the digest was set", () => {
  const fx = activationAuthorityFixture();
  const activation = attestWithArtifacts(fx);
  const provenanceRel = "config/domain-core-promotion-provenance/quota/1.json";
  writeFileSync(join(fx.root, provenanceRel), "{\"provenance\":\"TAMPERED\"}");
  git(fx.root, "add", ".");
  git(fx.root, "commit", "-qm", "tamper provenance bytes");
  const tamperedActivation = git(fx.root, "rev-parse", "HEAD");
  assert.throws(
    () => resolve(fx.root, tamperedActivation),
    /attestation provenance digest mismatch/u,
  );
});

// ---------------------------------------------------------------------------
// Secure path-resolution: unsignedBundle.path / provenance.path must be
// canonical repo-relative and reject traversal, absolute, backslash, and
// symlink substitution.  Path-shape validation is unconditional (the resolver
// consumes these paths downstream), so these fire with or without .sha256.
// ---------------------------------------------------------------------------

test("rejects attestation whose unsignedBundle.path escapes the repo via traversal", () => {
  const fx = activationAuthorityFixture();
  const attestation = readJson(fx.root, fx.attestationPath);
  attestation.unsignedBundle.path = "../../etc/passwd";
  writeJson(fx.root, fx.attestationPath, attestation);
  const activation = recommit(fx.root);
  assert.throws(
    () => resolve(fx.root, activation),
    /attestation candidate provenance unverifiable/u,
  );
});

test("rejects attestation whose unsignedBundle.path is absolute", () => {
  const fx = activationAuthorityFixture();
  const attestation = readJson(fx.root, fx.attestationPath);
  attestation.unsignedBundle.path = "/etc/passwd";
  writeJson(fx.root, fx.attestationPath, attestation);
  const activation = recommit(fx.root);
  assert.throws(
    () => resolve(fx.root, activation),
    /attestation candidate provenance unverifiable/u,
  );
});

test("rejects attestation whose provenance.path contains a backslash escape", () => {
  const fx = activationAuthorityFixture();
  const attestation = readJson(fx.root, fx.attestationPath);
  attestation.provenance.path = "config\\domain-core-promotion-provenance\\quota\\1.json";
  writeJson(fx.root, fx.attestationPath, attestation);
  const activation = recommit(fx.root);
  assert.throws(
    () => resolve(fx.root, activation),
    /attestation candidate provenance unverifiable/u,
  );
});

test("rejects attestation whose provenance.path escapes the repo via traversal", () => {
  const fx = activationAuthorityFixture();
  const attestation = readJson(fx.root, fx.attestationPath);
  attestation.provenance.path = "../../../etc/shadow";
  writeJson(fx.root, fx.attestationPath, attestation);
  const activation = recommit(fx.root);
  assert.throws(
    () => resolve(fx.root, activation),
    /attestation candidate provenance unverifiable/u,
  );
});

test("rejects attestation whose unsignedBundle.path is a symlink substituting for a real file", () => {
  const fx = activationAuthorityFixture();
  // Stage a legitimate bundle, then replace the path target with a symlink
  // pointing at an attacker-controlled file.  O_NOFOLLOW + lstat-identity
  // must reject the symlink component / leaf substitution.
  const bundleRel = "config/domain-core-promotion-bundles/quota/1.json";
  const attackerRel = "config/domain-core-promotion-bundles/quota/attacker.json";
  mkdirSync(join(fx.root, bundleRel, ".."), { recursive: true });
  writeFileSync(join(fx.root, attackerRel), "{\"bundle\":\"attacker\"}");
  writeFileSync(join(fx.root, bundleRel), "{\"bundle\":\"legit\"}");
  // Replace the legit file with a symlink to the attacker file.
  try {
    symlinkSync(join(fx.root, attackerRel), join(fx.root, bundleRel));
  } catch {
    // If the platform refuses to overwrite, remove then link.
    rmSync(join(fx.root, bundleRel), { force: true });
    symlinkSync(join(fx.root, attackerRel), join(fx.root, bundleRel));
  }
  const bundle = readFileSync(join(fx.root, attackerRel));
  const attestation = readJson(fx.root, fx.attestationPath);
  attestation.unsignedBundle.path = bundleRel;
  attestation.unsignedBundle.sha256 = sha256Bytes(bundle);
  writeJson(fx.root, fx.attestationPath, attestation);
  git(fx.root, "add", ".");
  git(fx.root, "commit", "-qm", "symlink-substituted bundle");
  const activation = git(fx.root, "rev-parse", "HEAD");
  assert.throws(
    () => resolve(fx.root, activation),
    /attestation candidate provenance unverifiable/u,
  );
});
// ---------------------------------------------------------------------------
// Exact-byte digest parity + unsignedBundle/provenance artifact-integrity
// tests (PR #1820 exact-head review blockers).
//
// sha256GitBlob must hash the EXACT git-blob bytes (no .trim()), so a
// newline-terminated policy/evaluator file binds to its newline-inclusive
// digest, matching the authoritative Python file_sha256_at_commit.  The
// pre-fix git() helper returned a .trim()-ed UTF-8 string, so a trailing
// newline was stripped and the gate silently accepted the trimmed digest.
//
// verifyProtectedAttestationProvenance must validate unsignedBundle.path /
// provenance.path against a secure repo-relative resolver and, when the
// respective .sha256 field is present, validate it against the exact
// working-tree file bytes read via O_NOFOLLOW.  Pre-fix the resolver trusted
// those paths and any claimed digest without reading a byte; a tampered,
// traversed, or symlink-substituted artifact sailed through.
//
// The .sha256 verification is conditional on presence (mirrors the gate
// without breaking the 18 ancestry/authority fixtures that omit it); path
// shape is unconditional.  These tests set the .sha256 fields and write the
// backing files to exercise the new contract.
// ---------------------------------------------------------------------------

// Exact-bytes git-blob digest: reads `git show` as a raw Buffer (no text
// decoding, no .trim()), mirroring the post-fix production sha256GitBlob.
// Contrast with the file-scoped sha256GitBlob helper (line 354) which still
// uses git() -> .trim(); that helper reproduces the PRE-FIX trimmed digest.
function sha256ExactGitBlob(root, revision, path) {
  const blob = execFileSync("git", ["-C", root, "show", `${revision}:${path}`]);
  return createHash("sha256").update(blob).digest("hex");
}

function sha256Bytes(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

// Write a bundle + provenance file at the attested paths and set the matching
// exact-byte sha256 fields on the authority fixture's attestation, returning
// the new activation commit.
function attestWithArtifacts(fx, { bundleBytes, provenanceBytes } = {}) {
  const bundleRel = "config/domain-core-promotion-bundles/quota/1.json";
  const provenanceRel = "config/domain-core-promotion-provenance/quota/1.json";
  const bundle = Buffer.from(bundleBytes ?? '{"bundle":"quota-1"}');
  const provenance = Buffer.from(
    provenanceBytes ?? '{"provenance":"quota-1"}',
  );
  mkdirSync(join(fx.root, bundleRel, ".."), { recursive: true });
  mkdirSync(join(fx.root, provenanceRel, ".."), { recursive: true });
  writeFileSync(join(fx.root, bundleRel), bundle);
  writeFileSync(join(fx.root, provenanceRel), provenance);
  git(fx.root, "add", ".");
  git(fx.root, "commit", "-qm", "stage bundle+provenance artifacts");
  const attestation = readJson(fx.root, fx.attestationPath);
  attestation.unsignedBundle.path = bundleRel;
  attestation.unsignedBundle.sha256 = sha256Bytes(bundle);
  attestation.provenance.path = provenanceRel;
  attestation.provenance.sha256 = sha256Bytes(provenance);
  writeJson(fx.root, fx.attestationPath, attestation);
  return recommit(fx.root);
}

// ---------------------------------------------------------------------------
// Exact-byte digest parity for newline-terminated policy/evaluator blobs.
// The authority fixture's evaluator file ends in "\n"; the policy file
// (JSON.stringify, no trailing newline) is the control that both digests
// agree on.  These pin the newline-inclusive contract.
// ---------------------------------------------------------------------------

test("rejects attestation whose evaluator digest is the trimmed (newline-stripped) digest of a newline-terminated evaluator", () => {
  const fx = activationAuthorityFixture();
  // The fixture's evaluator blob ends in "\n".  The pre-fix production
  // sha256GitBlob trimmed it, so the file-scoped test helper (which also
  // trims) yields the PRE-FIX digest.  The post-fix gate hashes the exact
  // bytes and must reject the trimmed digest as a source-digest mismatch.
  const trimmedEvaluator = sha256GitBlob(
    fx.root,
    fx.candidate,
    "scripts/lib/domain-core-deterministic-candidate-bundle.mjs",
  );
  const attestation = readJson(fx.root, fx.attestationPath);
  attestation.provenance.policySha256 = fx.policySha256;
  attestation.provenance.evaluatorSha256 = trimmedEvaluator;
  writeJson(fx.root, fx.attestationPath, attestation);
  const activation = recommit(fx.root);
  // Pre-fix: production also trimmed -> trimmed == trimmed -> ACCEPTS (red).
  // Post-fix: production exact -> trimmed != exact -> rejects (green).
  assert.throws(
    () => resolve(fx.root, activation),
    /attestation source digest mismatch/u,
  );
});

test("accepts attestation whose evaluator digest is the exact (newline-inclusive) digest of a newline-terminated evaluator", () => {
  const fx = activationAuthorityFixture();
  // Exact bytes (Buffer, no trim) of the newline-terminated evaluator.
  const exactEvaluator = sha256ExactGitBlob(
    fx.root,
    fx.candidate,
    "scripts/lib/deterministic-candidate-bundle.mjs".replace(
      "deterministic",
      "domain-core-deterministic",
    ),
  );
  const attestation = readJson(fx.root, fx.attestationPath);
  attestation.provenance.policySha256 = fx.policySha256;
  attestation.provenance.evaluatorSha256 = exactEvaluator;
  writeJson(fx.root, fx.attestationPath, attestation);
  const activation = recommit(fx.root);
  // Pre-fix: production trimmed -> exact != trimmed -> rejects (red).
  // Post-fix: production exact -> exact == exact -> accepts (green).
  const resolved = resolve(fx.root, activation);
  assert.equal(resolved.active, true);
  assert.equal(resolved.candidateCommit, fx.candidate);
});

test("rejects attestation whose policy digest is the trimmed digest when the policy blob is newline-terminated", () => {
  const fx = activationAuthorityFixture();
  // Rewrite the policy file with a trailing newline so the trimmed vs exact
  // digests diverge, then recommit so the trusted-main bytes carry the
  // newline.  The candidate ancestry (C ancestor of the new trusted-main)
  // still holds because the new commit descends from the candidate.
  const policyRel = "config/domain-core-promotion-policy.json";
  const policyObj = {
    schemaVersion: 3,
    authority: "unsigned-candidate-evaluation",
  };
  writeFileSync(join(fx.root, policyRel), JSON.stringify(policyObj) + "\n");
  git(fx.root, "add", ".");
  git(fx.root, "commit", "-qm", "newline-terminated policy");
  const trustedMain = git(fx.root, "rev-parse", "HEAD");
  const trimmedPolicy = sha256GitBlob(fx.root, trustedMain, policyRel);
  const exactPolicy = sha256ExactGitBlob(fx.root, trustedMain, policyRel);
  // Sanity: the two must diverge or the test has no lever.
  assert.notEqual(trimmedPolicy, exactPolicy);
  const exactEvaluator = sha256ExactGitBlob(
    fx.root,
    trustedMain,
    "scripts/lib/domain-core-deterministic-candidate-bundle.mjs",
  );
  const attestation = readJson(fx.root, fx.attestationPath);
  attestation.candidate.candidateCommit = fx.candidate;
  attestation.provenance.trustedMainCommit = trustedMain;
  attestation.provenance.policySha256 = trimmedPolicy;
  attestation.provenance.evaluatorSha256 = exactEvaluator;
  writeJson(fx.root, fx.attestationPath, attestation);
  const activation = recommit(fx.root);
  assert.throws(
    () => resolve(fx.root, activation),
    /attestation source digest mismatch/u,
  );
});

// ---------------------------------------------------------------------------
// unsignedBundle.sha256 / provenance.sha256 artifact-integrity verification.
// The fix reads the exact working-tree bytes at the secure path and rejects a
// digest or file-byte mismatch.  These prove the gate validates the artifacts
// the resolver later trusts as bundlePath / provenancePath.
// ---------------------------------------------------------------------------

test("accepts attestation with matching unsignedBundle.sha256 and provenance.sha256 over real artifact files", () => {
  const fx = activationAuthorityFixture();
  const activation = attestWithArtifacts(fx);
  // Post-fix: both digests match the exact file bytes -> accepts (green).
  // Pre-fix: the fields are ignored entirely -> also accepts (guard against
  // regressions, paired with the tamper tests below).
  const resolved = resolve(fx.root, activation);
  assert.equal(resolved.active, true);
  assert.equal(resolved.candidateCommit, fx.candidate);
});

test("rejects attestation whose unsignedBundle.sha256 disagrees with the bundle file bytes", () => {
  const fx = activationAuthorityFixture();
  attestWithArtifacts(fx);
  // Tamper only the claimed unsignedBundle.sha256 to a valid-but-wrong
  // 64-hex digest.  Pre-fix: ignored -> accepts (red).  Post-fix: reads the
  // bundle bytes and rejects with the specific mismatch (green).
  const attestation = readJson(fx.root, fx.attestationPath);
  attestation.unsignedBundle.sha256 = "c".repeat(64);
  writeJson(fx.root, fx.attestationPath, attestation);
  const tamperedActivation = recommit(fx.root);
  assert.throws(
    () => resolve(fx.root, tamperedActivation),
    /attestation unsigned bundle digest mismatch/u,
  );
});

test("rejects attestation whose provenance.sha256 disagrees with the provenance file bytes", () => {
  const fx = activationAuthorityFixture();
  attestWithArtifacts(fx);
  const attestation = readJson(fx.root, fx.attestationPath);
  attestation.provenance.sha256 = "d".repeat(64);
  writeJson(fx.root, fx.attestationPath, attestation);
  const tamperedActivation = recommit(fx.root);
  assert.throws(
    () => resolve(fx.root, tamperedActivation),
    /attestation provenance digest mismatch/u,
  );
});

test("rejects attestation whose unsignedBundle.sha256 is not a 64-hex lowercase digest", () => {
  const fx = activationAuthorityFixture();
  attestWithArtifacts(fx);
  const attestation = readJson(fx.root, fx.attestationPath);
  attestation.unsignedBundle.sha256 = "not-a-hex-digest";
  writeJson(fx.root, fx.attestationPath, attestation);
  const activation = recommit(fx.root);
  assert.throws(
    () => resolve(fx.root, activation),
    /attestation candidate provenance unverifiable/u,
  );
});

test("rejects attestation when the bundle file bytes are tampered after the digest was set", () => {
  const fx = activationAuthorityFixture();
  attestWithArtifacts(fx);
  // Mutate the bundle FILE bytes on disk so the committed sha256 no longer
  // matches the file.  This proves the gate reads the actual file bytes
  // rather than trusting the attested digest.
  const bundleRel = "config/domain-core-promotion-bundles/quota/1.json";
  writeFileSync(join(fx.root, bundleRel), '{"bundle":"TAMPERED"}');
  git(fx.root, "add", ".");
  git(fx.root, "commit", "-qm", "tamper bundle bytes");
  const tamperedActivation = git(fx.root, "rev-parse", "HEAD");
  assert.throws(
    () => resolve(fx.root, tamperedActivation),
    /attestation unsigned bundle digest mismatch/u,
  );
});

test("rejects attestation when the provenance file bytes are tampered after the digest was set", () => {
  const fx = activationAuthorityFixture();
  attestWithArtifacts(fx);
  const provenanceRel = "config/domain-core-promotion-provenance/quota/1.json";
  writeFileSync(join(fx.root, provenanceRel), '{"provenance":"TAMPERED"}');
  git(fx.root, "add", ".");
  git(fx.root, "commit", "-qm", "tamper provenance bytes");
  const tamperedActivation = git(fx.root, "rev-parse", "HEAD");
  assert.throws(
    () => resolve(fx.root, tamperedActivation),
    /attestation provenance digest mismatch/u,
  );
});

// ---------------------------------------------------------------------------
// Secure path-resolution: unsignedBundle.path / provenance.path must be
// canonical repo-relative and reject traversal, absolute, backslash, and
// symlink substitution.  Path-shape validation is unconditional (the resolver
// consumes these paths downstream), so these fire with or without .sha256.
// ---------------------------------------------------------------------------

test("rejects attestation whose unsignedBundle.path escapes the repo via traversal", () => {
  const fx = activationAuthorityFixture();
  const attestation = readJson(fx.root, fx.attestationPath);
  attestation.unsignedBundle.path = "../../etc/passwd";
  writeJson(fx.root, fx.attestationPath, attestation);
  const activation = recommit(fx.root);
  assert.throws(
    () => resolve(fx.root, activation),
    /attestation candidate provenance unverifiable/u,
  );
});

test("rejects attestation whose unsignedBundle.path is absolute", () => {
  const fx = activationAuthorityFixture();
  const attestation = readJson(fx.root, fx.attestationPath);
  attestation.unsignedBundle.path = "/etc/passwd";
  writeJson(fx.root, fx.attestationPath, attestation);
  const activation = recommit(fx.root);
  assert.throws(
    () => resolve(fx.root, activation),
    /attestation candidate provenance unverifiable/u,
  );
});

test("rejects attestation whose provenance.path contains a backslash escape", () => {
  const fx = activationAuthorityFixture();
  const attestation = readJson(fx.root, fx.attestationPath);
  attestation.provenance.path =
    "config\\domain-core-promotion-provenance\\quota\\1.json";
  writeJson(fx.root, fx.attestationPath, attestation);
  const activation = recommit(fx.root);
  assert.throws(
    () => resolve(fx.root, activation),
    /attestation candidate provenance unverifiable/u,
  );
});

test("rejects attestation whose provenance.path escapes the repo via traversal", () => {
  const fx = activationAuthorityFixture();
  const attestation = readJson(fx.root, fx.attestationPath);
  attestation.provenance.path = "../../../etc/shadow";
  writeJson(fx.root, fx.attestationPath, attestation);
  const activation = recommit(fx.root);
  assert.throws(
    () => resolve(fx.root, activation),
    /attestation candidate provenance unverifiable/u,
  );
});

test("rejects attestation whose unsignedBundle.path is a symlink substituting for a real file", () => {
  const fx = activationAuthorityFixture();
  // Stage a legitimate bundle, then replace the path target with a symlink
  // pointing at an attacker-controlled file.  O_NOFOLLOW + lstat-identity
  // must reject the symlink component / leaf substitution.
  const bundleRel = "config/domain-core-promotion-bundles/quota/1.json";
  const attackerRel = "config/domain-core-promotion-bundles/quota/attacker.json";
  mkdirSync(join(fx.root, bundleRel, ".."), { recursive: true });
  writeFileSync(join(fx.root, attackerRel), '{"bundle":"attacker"}');
  writeFileSync(join(fx.root, bundleRel), '{"bundle":"legit"}');
  // Replace the legit file with a symlink to the attacker file.
  rmSync(join(fx.root, bundleRel), { force: true });
  symlinkSync(join(fx.root, attackerRel), join(fx.root, bundleRel));
  const bundle = readFileSync(join(fx.root, attackerRel));
  const attestation = readJson(fx.root, fx.attestationPath);
  attestation.unsignedBundle.path = bundleRel;
  attestation.unsignedBundle.sha256 = sha256Bytes(bundle);
  writeJson(fx.root, fx.attestationPath, attestation);
  git(fx.root, "add", ".");
  git(fx.root, "commit", "-qm", "symlink-substituted bundle");
  const activation = git(fx.root, "rev-parse", "HEAD");
  assert.throws(
    () => resolve(fx.root, activation),
    /attestation candidate provenance unverifiable/u,
  );
});
// ---------------------------------------------------------------------------
// Exact-byte digest parity + unsignedBundle/provenance artifact-integrity
// tests (PR #1820 exact-head review blockers).
//
// sha256GitBlob must hash the EXACT git-blob bytes (no .trim()), so a
// newline-terminated policy/evaluator file binds to its newline-inclusive
// digest, matching the authoritative Python file_sha256_at_commit.  The
// pre-fix git() helper returned a .trim()-ed UTF-8 string, so a trailing
// newline was stripped and the gate silently accepted the trimmed digest.
//
// verifyProtectedAttestationProvenance must validate unsignedBundle.path /
// provenance.path against a secure repo-relative resolver and, when the
// respective .sha256 field is present, validate it against the exact
// working-tree file bytes read via O_NOFOLLOW.  Pre-fix the resolver trusted
// those paths and any claimed digest without reading a byte; a tampered,
// traversed, or symlink-substituted artifact sailed through.
//
// The .sha256 verification is conditional on presence (mirrors the gate
// without breaking the 18 ancestry/authority fixtures that omit it); path
// shape is unconditional.  These tests set the .sha256 fields and write the
// backing files to exercise the new contract.
// ---------------------------------------------------------------------------

// Exact-bytes git-blob digest: reads `git show` as a raw Buffer (no text
// decoding, no .trim()), mirroring the post-fix production sha256GitBlob.
// Contrast with the file-scoped sha256GitBlob helper (line 354) which still
// uses git() -> .trim(); that helper reproduces the PRE-FIX trimmed digest.
function sha256ExactGitBlob(root, revision, path) {
  const blob = execFileSync("git", ["-C", root, "show", `${revision}:${path}`]);
  return createHash("sha256").update(blob).digest("hex");
}

function sha256Bytes(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

// Write a bundle + provenance file at the attested paths and set the matching
// exact-byte sha256 fields on the authority fixture's attestation, returning
// the new activation commit.
function attestWithArtifacts(fx, { bundleBytes, provenanceBytes } = {}) {
  const bundleRel = "config/domain-core-promotion-bundles/quota/1.json";
  const provenanceRel = "config/domain-core-promotion-provenance/quota/1.json";
  const bundle = Buffer.from(bundleBytes ?? '{"bundle":"quota-1"}');
  const provenance = Buffer.from(
    provenanceBytes ?? '{"provenance":"quota-1"}',
  );
  mkdirSync(join(fx.root, bundleRel, ".."), { recursive: true });
  mkdirSync(join(fx.root, provenanceRel, ".."), { recursive: true });
  writeFileSync(join(fx.root, bundleRel), bundle);
  writeFileSync(join(fx.root, provenanceRel), provenance);
  git(fx.root, "add", ".");
  git(fx.root, "commit", "-qm", "stage bundle+provenance artifacts");
  const attestation = readJson(fx.root, fx.attestationPath);
  attestation.unsignedBundle.path = bundleRel;
  attestation.unsignedBundle.sha256 = sha256Bytes(bundle);
  attestation.provenance.path = provenanceRel;
  attestation.provenance.sha256 = sha256Bytes(provenance);
  writeJson(fx.root, fx.attestationPath, attestation);
  return recommit(fx.root);
}

// ---------------------------------------------------------------------------
// Exact-byte digest parity for newline-terminated policy/evaluator blobs.
// The authority fixture's evaluator file ends in "\n"; the policy file
// (JSON.stringify, no trailing newline) is the control that both digests
// agree on.  These pin the newline-inclusive contract.
// ---------------------------------------------------------------------------

test("rejects attestation whose evaluator digest is the trimmed (newline-stripped) digest of a newline-terminated evaluator", () => {
  const fx = activationAuthorityFixture();
  // The fixture's evaluator blob ends in "\n".  The pre-fix production
  // sha256GitBlob trimmed it, so the file-scoped test helper (which also
  // trims) yields the PRE-FIX digest.  The post-fix gate hashes the exact
  // bytes and must reject the trimmed digest as a source-digest mismatch.
  const trimmedEvaluator = sha256GitBlob(
    fx.root,
    fx.candidate,
    "scripts/lib/domain-core-deterministic-candidate-bundle.mjs",
  );
  const attestation = readJson(fx.root, fx.attestationPath);
  attestation.provenance.policySha256 = sha256ExactGitBlob(
    fx.root,
    fx.candidate,
    "config/domain-core-promotion-policy.json",
  );
  attestation.provenance.evaluatorSha256 = trimmedEvaluator;
  writeJson(fx.root, fx.attestationPath, attestation);
  const activation = recommit(fx.root);
  // Pre-fix: production also trimmed -> trimmed == trimmed -> ACCEPTS (red).
  // Post-fix: production exact -> trimmed != exact -> rejects (green).
  assert.throws(
    () => resolve(fx.root, activation),
    /attestation source digest mismatch/u,
  );
});

test("accepts attestation whose evaluator digest is the exact (newline-inclusive) digest of a newline-terminated evaluator", () => {
  const fx = activationAuthorityFixture();
  // Exact bytes (Buffer, no trim) of the newline-terminated evaluator.
  const exactEvaluator = sha256ExactGitBlob(
    fx.root,
    fx.candidate,
    "scripts/lib/domain-core-deterministic-candidate-bundle.mjs",
  );
  const attestation = readJson(fx.root, fx.attestationPath);
  attestation.provenance.policySha256 = sha256ExactGitBlob(
    fx.root,
    fx.candidate,
    "config/domain-core-promotion-policy.json",
  );
  attestation.provenance.evaluatorSha256 = exactEvaluator;
  writeJson(fx.root, fx.attestationPath, attestation);
  const activation = recommit(fx.root);
  // Pre-fix: production trimmed -> exact != trimmed -> rejects (red).
  // Post-fix: production exact -> exact == exact -> accepts (green).
  const resolved = resolve(fx.root, activation);
  assert.equal(resolved.active, true);
  assert.equal(resolved.candidateCommit, fx.candidate);
});

test("rejects attestation whose policy digest is the trimmed digest when the policy blob is newline-terminated", () => {
  const fx = activationAuthorityFixture();
  // Rewrite the policy file with a trailing newline so the trimmed vs exact
  // digests diverge, then recommit so the trusted-main bytes carry the
  // newline.  The candidate ancestry (C ancestor of the new trusted-main)
  // still holds because the new commit descends from the candidate.
  const policyRel = "config/domain-core-promotion-policy.json";
  const policyObj = {
    schemaVersion: 3,
    authority: "unsigned-candidate-evaluation",
  };
  writeFileSync(join(fx.root, policyRel), JSON.stringify(policyObj) + "\n");
  git(fx.root, "add", ".");
  git(fx.root, "commit", "-qm", "newline-terminated policy");
  const trustedMain = git(fx.root, "rev-parse", "HEAD");
  const trimmedPolicy = sha256GitBlob(fx.root, trustedMain, policyRel);
  const exactPolicy = sha256ExactGitBlob(fx.root, trustedMain, policyRel);
  // Sanity: the two must diverge or the test has no lever.
  assert.notEqual(trimmedPolicy, exactPolicy);
  const exactEvaluator = sha256ExactGitBlob(
    fx.root,
    trustedMain,
    "scripts/lib/domain-core-deterministic-candidate-bundle.mjs",
  );
  const attestation = readJson(fx.root, fx.attestationPath);
  attestation.candidate.candidateCommit = fx.candidate;
  attestation.provenance.trustedMainCommit = trustedMain;
  attestation.provenance.policySha256 = trimmedPolicy;
  attestation.provenance.evaluatorSha256 = exactEvaluator;
  writeJson(fx.root, fx.attestationPath, attestation);
  const activation = recommit(fx.root);
  assert.throws(
    () => resolve(fx.root, activation),
    /attestation source digest mismatch/u,
  );
});

// ---------------------------------------------------------------------------
// unsignedBundle.sha256 / provenance.sha256 artifact-integrity verification.
// The fix reads the exact working-tree bytes at the secure path and rejects a
// digest or file-byte mismatch.  These prove the gate validates the artifacts
// the resolver later trusts as bundlePath / provenancePath.
// ---------------------------------------------------------------------------

test("accepts attestation with matching unsignedBundle.sha256 and provenance.sha256 over real artifact files", () => {
  const fx = activationAuthorityFixture();
  const activation = attestWithArtifacts(fx);
  // Post-fix: both digests match the exact file bytes -> accepts (green).
  // Pre-fix: the fields are ignored entirely -> also accepts (guard against
  // regressions, paired with the tamper tests below).
  const resolved = resolve(fx.root, activation);
  assert.equal(resolved.active, true);
  assert.equal(resolved.candidateCommit, fx.candidate);
});

test("rejects attestation whose unsignedBundle.sha256 disagrees with the bundle file bytes", () => {
  const fx = activationAuthorityFixture();
  attestWithArtifacts(fx);
  // Tamper only the claimed unsignedBundle.sha256 to a valid-but-wrong
  // 64-hex digest.  Pre-fix: ignored -> accepts (red).  Post-fix: reads the
  // bundle bytes and rejects with the specific mismatch (green).
  const attestation = readJson(fx.root, fx.attestationPath);
  attestation.unsignedBundle.sha256 = "c".repeat(64);
  writeJson(fx.root, fx.attestationPath, attestation);
  const tamperedActivation = recommit(fx.root);
  assert.throws(
    () => resolve(fx.root, tamperedActivation),
    /attestation unsigned bundle digest mismatch/u,
  );
});

test("rejects attestation whose provenance.sha256 disagrees with the provenance file bytes", () => {
  const fx = activationAuthorityFixture();
  attestWithArtifacts(fx);
  const attestation = readJson(fx.root, fx.attestationPath);
  attestation.provenance.sha256 = "d".repeat(64);
  writeJson(fx.root, fx.attestationPath, attestation);
  const tamperedActivation = recommit(fx.root);
  assert.throws(
    () => resolve(fx.root, tamperedActivation),
    /attestation provenance digest mismatch/u,
  );
});

test("rejects attestation whose unsignedBundle.sha256 is not a 64-hex lowercase digest", () => {
  const fx = activationAuthorityFixture();
  attestWithArtifacts(fx);
  const attestation = readJson(fx.root, fx.attestationPath);
  attestation.unsignedBundle.sha256 = "not-a-hex-digest";
  writeJson(fx.root, fx.attestationPath, attestation);
  const activation = recommit(fx.root);
  assert.throws(
    () => resolve(fx.root, activation),
    /attestation candidate provenance unverifiable/u,
  );
});

test("rejects attestation when the bundle file bytes are tampered after the digest was set", () => {
  const fx = activationAuthorityFixture();
  attestWithArtifacts(fx);
  // Mutate the bundle FILE bytes on disk so the committed sha256 no longer
  // matches the file.  This proves the gate reads the actual file bytes
  // rather than trusting the attested digest.
  const bundleRel = "config/domain-core-promotion-bundles/quota/1.json";
  writeFileSync(join(fx.root, bundleRel), '{"bundle":"TAMPERED"}');
  git(fx.root, "add", ".");
  git(fx.root, "commit", "-qm", "tamper bundle bytes");
  const tamperedActivation = git(fx.root, "rev-parse", "HEAD");
  assert.throws(
    () => resolve(fx.root, tamperedActivation),
    /attestation unsigned bundle digest mismatch/u,
  );
});

test("rejects attestation when the provenance file bytes are tampered after the digest was set", () => {
  const fx = activationAuthorityFixture();
  attestWithArtifacts(fx);
  const provenanceRel = "config/domain-core-promotion-provenance/quota/1.json";
  writeFileSync(join(fx.root, provenanceRel), '{"provenance":"TAMPERED"}');
  git(fx.root, "add", ".");
  git(fx.root, "commit", "-qm", "tamper provenance bytes");
  const tamperedActivation = git(fx.root, "rev-parse", "HEAD");
  assert.throws(
    () => resolve(fx.root, tamperedActivation),
    /attestation provenance digest mismatch/u,
  );
});

// ---------------------------------------------------------------------------
// Secure path-resolution: unsignedBundle.path / provenance.path must be
// canonical repo-relative and reject traversal, absolute, backslash, and
// symlink substitution.  Path-shape validation is unconditional (the resolver
// consumes these paths downstream), so these fire with or without .sha256.
// ---------------------------------------------------------------------------

test("rejects attestation whose unsignedBundle.path escapes the repo via traversal", () => {
  const fx = activationAuthorityFixture();
  const attestation = readJson(fx.root, fx.attestationPath);
  attestation.unsignedBundle.path = "../../etc/passwd";
  writeJson(fx.root, fx.attestationPath, attestation);
  const activation = recommit(fx.root);
  assert.throws(
    () => resolve(fx.root, activation),
    /attestation candidate provenance unverifiable/u,
  );
});

test("rejects attestation whose unsignedBundle.path is absolute", () => {
  const fx = activationAuthorityFixture();
  const attestation = readJson(fx.root, fx.attestationPath);
  attestation.unsignedBundle.path = "/etc/passwd";
  writeJson(fx.root, fx.attestationPath, attestation);
  const activation = recommit(fx.root);
  assert.throws(
    () => resolve(fx.root, activation),
    /attestation candidate provenance unverifiable/u,
  );
});

test("rejects attestation whose provenance.path contains a backslash escape", () => {
  const fx = activationAuthorityFixture();
  const attestation = readJson(fx.root, fx.attestationPath);
  attestation.provenance.path =
    "config\\domain-core-promotion-provenance\\quota\\1.json";
  writeJson(fx.root, fx.attestationPath, attestation);
  const activation = recommit(fx.root);
  assert.throws(
    () => resolve(fx.root, activation),
    /attestation candidate provenance unverifiable/u,
  );
});

test("rejects attestation whose provenance.path escapes the repo via traversal", () => {
  const fx = activationAuthorityFixture();
  const attestation = readJson(fx.root, fx.attestationPath);
  attestation.provenance.path = "../../../etc/shadow";
  writeJson(fx.root, fx.attestationPath, attestation);
  const activation = recommit(fx.root);
  assert.throws(
    () => resolve(fx.root, activation),
    /attestation candidate provenance unverifiable/u,
  );
});

test("rejects attestation whose unsignedBundle.path is a symlink substituting for a real file", () => {
  const fx = activationAuthorityFixture();
  // Stage a legitimate bundle, then replace the path target with a symlink
  // pointing at an attacker-controlled file.  O_NOFOLLOW + lstat-identity
  // must reject the symlink component / leaf substitution.
  const bundleRel = "config/domain-core-promotion-bundles/quota/1.json";
  const attackerRel = "config/domain-core-promotion-bundles/quota/attacker.json";
  mkdirSync(join(fx.root, bundleRel, ".."), { recursive: true });
  writeFileSync(join(fx.root, attackerRel), '{"bundle":"attacker"}');
  writeFileSync(join(fx.root, bundleRel), '{"bundle":"legit"}');
  rmSync(join(fx.root, bundleRel), { force: true });
  symlinkSync(join(fx.root, attackerRel), join(fx.root, bundleRel));
  const bundle = readFileSync(join(fx.root, attackerRel));
  const attestation = readJson(fx.root, fx.attestationPath);
  attestation.unsignedBundle.path = bundleRel;
  attestation.unsignedBundle.sha256 = sha256Bytes(bundle);
  writeJson(fx.root, fx.attestationPath, attestation);
  git(fx.root, "add", ".");
  git(fx.root, "commit", "-qm", "symlink-substituted bundle");
  const activation = git(fx.root, "rev-parse", "HEAD");
  assert.throws(
    () => resolve(fx.root, activation),
    /attestation candidate provenance unverifiable/u,
  );
});
