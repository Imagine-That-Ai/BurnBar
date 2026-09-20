import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import {
  mkdtempSync,
  mkdirSync,
  readFileSync,
  writeFileSync,
  rmSync,
  symlinkSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  activationChangedPaths,
  annullableActivationChangedPaths,
  domainCoreActivationReceiptClosure,
  resolveActiveDomainCoreActivation,
  validateDomainCoreAnnullableActivation,
  validateDomainCoreActivation,
  validateDomainCoreReleaseActivation,
} from "./domain-core-activation.mjs";

function git(root, ...args) {
  return execFileSync("git", ["-C", root, ...args], {
    encoding: "utf8",
  }).trim();
}

function fixture({
  interveningMainChange = false,
  interveningSourceChange = false,
  interveningArtifactChange = false,
  mixedInterveningMainChange = false,
  evidenceBeforeMainChange = false,
} = {}) {
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
  writeFileSync(
    join(root, "config/domain-core-control-plane-manifest.json"),
    "candidate control plane\n",
  );
  git(root, "init", "-q");
  git(root, "config", "user.email", "test@openburnbar.invalid");
  git(root, "config", "user.name", "OpenBurnBar Test");
  git(root, "add", ".");
  git(root, "commit", "-qm", "candidate C");
  const candidate = git(root, "rev-parse", "HEAD");
  if (evidenceBeforeMainChange) {
    mkdirSync(
      join(
        root,
        "config/domain-core-legacy-deletion-receipts/quota.codex_usage/2",
      ),
      { recursive: true },
    );
    writeFileSync(
      join(
        root,
        "config/domain-core-legacy-deletion-receipts/quota.codex_usage/2/promotion.json",
      ),
      "{}\n",
    );
    git(root, "add", ".");
    git(root, "commit", "-qm", "activation evidence before main advance");
  }
  if (interveningMainChange) {
    mkdirSync(join(root, "functions"), { recursive: true });
    writeFileSync(
      join(root, "functions/.env.burnbar.production"),
      "MIN_INSTANCES=1\n",
    );
    git(root, "add", ".");
    git(root, "commit", "-qm", "unrelated protected main advance");
  }
  if (interveningSourceChange) {
    mkdirSync(join(root, "crates/openburnbar-domain-core/domain-core/src"), {
      recursive: true,
    });
    writeFileSync(
      join(root, "crates/openburnbar-domain-core/domain-core/src/lib.rs"),
      "pub fn changed() {}\n",
    );
    git(root, "add", ".");
    git(root, "commit", "-qm", "intervening source drift");
  }
  if (interveningArtifactChange) {
    mkdirSync(join(root, "functions/vendor/openburnbar/domain-core-wasm"), {
      recursive: true,
    });
    writeFileSync(
      join(
        root,
        "functions/vendor/openburnbar/domain-core-wasm/openburnbar_domain_core_bg.wasm",
      ),
      "swapped wasm bytes\n",
    );
    git(root, "add", ".");
    git(root, "commit", "-qm", "intervening deployed artifact swap");
  }
  if (mixedInterveningMainChange) {
    mkdirSync(join(root, "functions"), { recursive: true });
    writeFileSync(
      join(root, "functions/.env.burnbar.production"),
      "MIN_INSTANCES=1\n",
    );
    writeFileSync(
      join(root, "config/domain-core-legacy-deletion.json"),
      "smuggled authority change\n",
    );
    git(root, "add", ".");
    git(root, "commit", "-qm", "mixed protected main advance");
  }
  writeFileSync(join(root, "config/domain-core-build-profiles.json"), "rust\n");
  writeFileSync(
    join(root, "config/domain-core-legacy-deletion.json"),
    "promotion receipt\n",
  );
  writeFileSync(
    join(root, "config/domain-core-control-plane-manifest.json"),
    "activation control plane\n",
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

test("activation handles an unrelated protected-main advance without relaxing the final activation commit", () => {
  const value = fixture({ interveningMainChange: true });
  const proof = validateDomainCoreActivation({
    repoRoot: value.root,
    candidateCommit: value.candidate,
    activationCommit: value.activation,
  });
  assert.equal(proof.candidateCommit, value.candidate);
  assert.equal(proof.activationCommit, value.activation);
  assert.ok(
    !activationChangedPaths(
      value.root,
      value.candidate,
      value.activation,
    ).includes("functions/.env.burnbar.production"),
  );
});

test("activation rejects an intervening protected-main commit that changes attested Rust source", () => {
  const value = fixture({ interveningSourceChange: true });
  assert.throws(
    () =>
      validateDomainCoreActivation({
        repoRoot: value.root,
        candidateCommit: value.candidate,
        activationCommit: value.activation,
      }),
    /activation incidental protected-main commit .* must not change attested Rust source/u,
  );
});

test("activation rejects an intervening protected-main commit that swaps deployed domain-core artifacts", () => {
  // Promotion sidecars pin the Rust source fingerprint, not the deployed
  // artifact bytes, so an incidental commit swapping a vendored artifact
  // between C and P would ship unattested code and must fail closed.
  const value = fixture({ interveningArtifactChange: true });
  assert.throws(
    () =>
      validateDomainCoreActivation({
        repoRoot: value.root,
        candidateCommit: value.candidate,
        activationCommit: value.activation,
      }),
    /activation incidental protected-main commit .* must not change deployed domain-core artifacts/u,
  );
});

test("release activation resolves activation P when protected main advances before the release is cut", () => {
  // The ca605df1 shape: after activation P, protected main lands a commit
  // that mixes an unrelated path with a trusted control-plane manifest
  // refresh. The release commit R at HEAD is not the activation commit; the
  // resolver must re-derive P from the authority files and accept R.
  const value = fixture({ interveningMainChange: true });
  writeFileSync(
    join(value.root, "functions/.env.burnbar.production"),
    "MIN_INSTANCES=2\n",
  );
  writeFileSync(
    join(value.root, "config/domain-core-control-plane-manifest.json"),
    "release control plane\n",
  );
  git(value.root, "add", ".");
  git(value.root, "commit", "-qm", "post-activation mixed main advance");
  const release = git(value.root, "rev-parse", "HEAD");
  const proof = validateDomainCoreReleaseActivation({
    repoRoot: value.root,
    candidateCommit: value.candidate,
    releaseCommit: release,
  });
  assert.equal(proof.active, true);
  assert.equal(proof.candidateCommit, value.candidate);
  assert.equal(proof.activationCommit, value.activation);
  assert.equal(proof.releaseCommit, release);
  const direct = validateDomainCoreActivation({
    repoRoot: value.root,
    candidateCommit: value.candidate,
    activationCommit: value.activation,
    requireHead: false,
  });
  assert.equal(proof.changedPathsSha256, direct.changedPathsSha256);
});

test("release activation requires the release commit to equal the checkout HEAD", () => {
  const value = fixture({ interveningMainChange: true });
  writeFileSync(
    join(value.root, "functions/.env.burnbar.production"),
    "MIN_INSTANCES=2\n",
  );
  git(value.root, "add", ".");
  git(value.root, "commit", "-qm", "post-activation main advance");
  assert.throws(
    () =>
      validateDomainCoreReleaseActivation({
        repoRoot: value.root,
        candidateCommit: value.candidate,
        releaseCommit: value.activation,
      }),
    /release commit must equal the exact release checkout HEAD/u,
  );
});

test("release activation rejects post-activation drift of a single authority file", () => {
  const value = fixture();
  writeFileSync(
    join(value.root, "config/domain-core-build-profiles.json"),
    "rust drifted\n",
  );
  git(value.root, "add", ".");
  git(value.root, "commit", "-qm", "post-activation authority drift");
  assert.throws(
    () =>
      validateDomainCoreReleaseActivation({
        repoRoot: value.root,
        candidateCommit: value.candidate,
        releaseCommit: git(value.root, "rev-parse", "HEAD"),
      }),
    /activation authority files must resolve to the same first-parent commit/u,
  );
});

test("release activation rejects post-activation drift of deployed domain-core artifacts", () => {
  const value = fixture();
  mkdirSync(join(value.root, "functions/vendor/openburnbar/domain-core-wasm"), {
    recursive: true,
  });
  writeFileSync(
    join(
      value.root,
      "functions/vendor/openburnbar/domain-core-wasm/openburnbar_domain_core_bg.wasm",
    ),
    "swapped wasm bytes\n",
  );
  git(value.root, "add", ".");
  git(value.root, "commit", "-qm", "post-activation artifact swap");
  assert.throws(
    () =>
      validateDomainCoreReleaseActivation({
        repoRoot: value.root,
        candidateCommit: value.candidate,
        releaseCommit: git(value.root, "rev-parse", "HEAD"),
      }),
    /domain-core activation authority drift after activation/u,
  );
});

test("release activation rejects post-activation drift of activation evidence", () => {
  const value = fixture({ evidenceBeforeMainChange: true });
  writeFileSync(
    join(
      value.root,
      "config/domain-core-legacy-deletion-receipts/quota.codex_usage/2/promotion.json",
    ),
    '{"tampered":true}\n',
  );
  git(value.root, "add", ".");
  git(value.root, "commit", "-qm", "post-activation evidence tamper");
  assert.throws(
    () =>
      validateDomainCoreReleaseActivation({
        repoRoot: value.root,
        candidateCommit: value.candidate,
        releaseCommit: git(value.root, "rev-parse", "HEAD"),
      }),
    /domain-core activation authority drift after activation/u,
  );
});

test("annullable activation rejects forbidden drift after the activation suffix", () => {
  const value = fixture({ interveningMainChange: true });
  writeFileSync(
    join(value.root, "crates/openburnbar-domain-core/new.rs"),
    "fn changed() {}\n",
  );
  git(value.root, "add", ".");
  git(value.root, "commit", "-qm", "forbidden source drift");
  assert.throws(
    () =>
      validateDomainCoreAnnullableActivation({
        repoRoot: value.root,
        candidateCommit: value.candidate,
        activationCommit: git(value.root, "rev-parse", "HEAD"),
      }),
    /final diff contains forbidden paths/u,
  );
});

test("retains allowed evidence committed before a later unrelated protected-main advance", () => {
  // Evidence written in an allowed commit after candidate C must stay in the
  // closure even when an unrelated protected-main commit lands afterwards;
  // only the incidental commit's own paths are excluded.
  const value = fixture({
    evidenceBeforeMainChange: true,
    interveningMainChange: true,
  });
  const paths = annullableActivationChangedPaths(
    value.root,
    value.candidate,
    value.activation,
  );
  assert.ok(
    paths.includes(
      "config/domain-core-legacy-deletion-receipts/quota.codex_usage/2/promotion.json",
    ),
  );
  assert.ok(!paths.includes("functions/.env.burnbar.production"));
  const proof = validateDomainCoreAnnullableActivation({
    repoRoot: value.root,
    candidateCommit: value.candidate,
    activationCommit: value.activation,
  });
  assert.equal(proof.active, true);
});

test("rejects an intervening protected-main commit that mixes unrelated and activation paths", () => {
  // A mixed commit must not be treated as incidental: advancing the base past
  // it would drop its authority-ledger change from the validated diff.
  const value = fixture({ mixedInterveningMainChange: true });
  assert.throws(
    () =>
      validateDomainCoreActivation({
        repoRoot: value.root,
        candidateCommit: value.candidate,
        activationCommit: value.activation,
      }),
    /activation incidental protected-main commit .* must not change activation authority paths/u,
  );
  assert.throws(
    () =>
      validateDomainCoreAnnullableActivation({
        repoRoot: value.root,
        candidateCommit: value.candidate,
        activationCommit: value.activation,
      }),
    /annullable activation incidental protected-main commit .* must not change activation authority paths/u,
  );
});

test("normalizes an active activation proof to the signed receipt closure", () => {
  const value = fixture();
  const proof = validateDomainCoreActivation({
    repoRoot: value.root,
    candidateCommit: value.candidate,
    activationCommit: value.activation,
  });
  assert.deepEqual(domainCoreActivationReceiptClosure(proof), {
    candidateCommit: proof.candidateCommit,
    activationCommit: proof.activationCommit,
    coreVersion: proof.coreVersion,
    abiVersion: proof.abiVersion,
    sourceSha256: proof.sourceSha256,
    changedPathsSha256: proof.changedPathsSha256,
  });
  assert.throws(
    () => domainCoreActivationReceiptClosure({ ...proof, active: false }),
    /closure is not active/u,
  );
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
      .update(execFileSync("git", ["-C", root, "show", `${revision}:${path}`]))
      .digest("hex");
  const attest = (domain, generation, candidate) => {
    const scope =
      {
        cloudVault: "cloudvault",
        cloudVaultRewrap: "cloudvault-rewrap",
        cloudVaultSearch: "cloudvault-search",
      }[domain] ?? domain;
    const manifest = JSON.parse(
      git(
        root,
        "show",
        `${candidate}:crates/openburnbar-domain-core/union-abi-manifest.json`,
      ),
    );
    const bundlePath = `config/domain-core-promotion-bundles/${scope}/${generation}.json`;
    const provenancePath = `config/domain-core-promotion-provenance/${scope}/${generation}.json`;
    mkdirSync(join(root, bundlePath, ".."), { recursive: true });
    mkdirSync(join(root, provenancePath, ".."), { recursive: true });
    writeFileSync(
      join(root, bundlePath),
      JSON.stringify({ domain, generation }),
    );
    writeFileSync(
      join(root, provenancePath),
      JSON.stringify({ domain, generation, kind: "sigstore-fixture" }),
    );
    const generatedAt = `2026-01-${String(generation + 1).padStart(2, "0")}T00:00:00Z`;
    const attestationPath = `config/domain-core-promotion-attestations/${scope}/${generation}.json`;
    mkdirSync(join(root, attestationPath, ".."), { recursive: true });
    writeFileSync(
      join(root, attestationPath),
      JSON.stringify({
        schemaVersion: 2,
        authorityScope: scope,
        authorityGeneration: generation,
        candidate: {
          candidateCommit: candidate,
          coreVersion: manifest.coreVersion,
          abiVersion: manifest.abiVersion,
          sourceSha256: manifest.sourceSha256,
        },
        unsignedBundle: {
          path: bundlePath,
          sha256: createHash("sha256")
            .update(readFileSync(join(root, bundlePath)))
            .digest("hex"),
          sourceRunId: generation,
          sourceRunAttempt: 1,
        },
        provenance: {
          path: provenancePath,
          sha256: createHash("sha256")
            .update(readFileSync(join(root, provenancePath)))
            .digest("hex"),
          signerWorkflow: SIGNER_WORKFLOW,
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
        status: "attested",
        generatedAt,
        evidenceUri: `https://github.com/Imagine-That-Ai/BurnBar/attestations/${generation}`,
      }),
    );
    const attestationSha256 = createHash("sha256")
      .update(readFileSync(join(root, attestationPath)))
      .digest("hex");
    for (const id of rowIds[domain]) {
      const row = ledger.rows.find((item) => item.id === id);
      row.authorityGeneration = generation;
      let supersedes = null;
      if (generation > 1) {
        const previousPath = `config/domain-core-legacy-deletion-receipts/${id}/${generation - 1}/stable_release.json`;
        mkdirSync(join(root, previousPath, ".."), { recursive: true });
        writeFileSync(
          join(root, previousPath),
          JSON.stringify({
            schemaVersion: 2,
            rowId: id,
            authorityGeneration: generation - 1,
            transition: "stable_release",
            status: "active",
            approvedAt: `2026-01-${String(generation).padStart(2, "0")}T00:00:00Z`,
          }),
        );
        supersedes = {
          transition: "stable_release",
          path: previousPath,
          sha256: createHash("sha256")
            .update(readFileSync(join(root, previousPath)))
            .digest("hex"),
        };
      }
      const receiptPath = `config/domain-core-legacy-deletion-receipts/${id}/${generation}/promotion.json`;
      mkdirSync(join(root, receiptPath, ".."), { recursive: true });
      writeFileSync(
        join(root, receiptPath),
        JSON.stringify({
          schemaVersion: 2,
          rowId: id,
          authorityGeneration: generation,
          transition: "promotion",
          status: "active",
          evidence: [
            `https://github.com/Imagine-That-Ai/BurnBar/actions/runs/${generation}`,
          ],
          approvedBy: "@openburnbar-release",
          approvedAt: generatedAt,
          commit: candidate,
          promotionAttestation: {
            path: attestationPath,
            sha256: attestationSha256,
            supersedes,
          },
        }),
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
    JSON.stringify({
      schemaVersion: 3,
      authority: "unsigned-candidate-evaluation",
    }),
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
    verifyArtifactIdentity: false,
  });
  assert.equal(resolved.candidateCommit, candidateTwo);
  assert.deepEqual(
    resolved.domains.map(({ domain }) => domain),
    ["quota", "cloudVault"],
  );
});

test("release resolver recognizes only the fail-closed activation-annulment supersession contract", () => {
  const source = readFileSync(
    new URL("./domain-core-activation.mjs", import.meta.url),
    "utf8",
  );
  for (const marker of [
    'annulment: "annulment.json"',
    '"promotionReceiptSha256"',
    '"advancedMainCommit"',
    '"release_train_advanced_before_stable_receipt"',
    '"replacementCandidateRequired"',
    "validateDomainCoreAnnullableActivation",
    "domainCoreActivationReceiptClosure(expectedActivation)",
    "previous activation annulment closure is invalid",
    "previous activation annulment main advance is invalid",
    "promotion after annulment must attest a fresh replacement candidate",
    "promotion after annulment must descend from the advanced main commit",
  ]) {
    assert.match(
      source,
      new RegExp(marker.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&"), "u"),
    );
  }
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
    .update(execFileSync("git", ["-C", root, "show", `${revision}:${path}`]))
    .digest("hex");
}

function sha256TrimmedGitBlob(root, revision, path) {
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
  const attestationPath =
    "config/domain-core-promotion-attestations/quota/1.json";
  function buildValidAttestation(commit) {
    const bundlePath = "config/domain-core-promotion-bundles/quota/1.json";
    const provenancePath =
      "config/domain-core-promotion-provenance/quota/1.json";
    mkdirSync(join(root, bundlePath, ".."), { recursive: true });
    mkdirSync(join(root, provenancePath, ".."), { recursive: true });
    writeFileSync(join(root, bundlePath), '{"bundle":"authority-fixture"}');
    writeFileSync(
      join(root, provenancePath),
      '{"provenance":"authority-fixture"}',
    );
    return {
      schemaVersion: 2,
      authorityScope: "quota",
      authorityGeneration: 1,
      candidate: {
        candidateCommit: commit,
        coreVersion: manifest.coreVersion,
        abiVersion: manifest.abiVersion,
        sourceSha256: manifest.sourceSha256,
      },
      unsignedBundle: {
        path: bundlePath,
        sha256: sha256Bytes(readFileSync(join(root, bundlePath))),
        sourceRunId: 1,
        sourceRunAttempt: 1,
      },
      provenance: {
        path: provenancePath,
        sha256: sha256Bytes(readFileSync(join(root, provenancePath))),
        signerWorkflow: SIGNER_WORKFLOW,
        signerRunId: 1,
        signerRunAttempt: 1,
        trustedMainCommit: commit,
        policySha256,
        evaluatorSha256,
      },
      status: "attested",
      generatedAt: "2026-01-02T00:00:00Z",
      evidenceUri: "https://github.com/Imagine-That-Ai/BurnBar/attestations/1",
    };
  }
  function writeAttestation(attestation) {
    mkdirSync(join(root, attestationPath, ".."), { recursive: true });
    writeFileSync(join(root, attestationPath), JSON.stringify(attestation));
    const attestationSha256 = sha256Bytes(
      readFileSync(join(root, attestationPath)),
    );
    for (const id of rowIds) {
      const row = ledger.rows.find((item) => item.id === id);
      row.authorityGeneration = 1;
      const receiptPath = `config/domain-core-legacy-deletion-receipts/${id}/1/promotion.json`;
      mkdirSync(join(root, receiptPath, ".."), { recursive: true });
      writeFileSync(
        join(root, receiptPath),
        JSON.stringify({
          schemaVersion: 2,
          rowId: id,
          authorityGeneration: 1,
          transition: "promotion",
          status: "active",
          evidence: [
            "https://github.com/Imagine-That-Ai/BurnBar/actions/runs/1",
          ],
          approvedBy: "@openburnbar-release",
          approvedAt: attestation.generatedAt,
          commit: attestation.candidate.candidateCommit,
          promotionAttestation: {
            path: attestationPath,
            sha256: attestationSha256,
            supersedes: null,
          },
        }),
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

function recommit(
  root,
  { refreshAttestationDigest = true, refreshActivationAuthority = true } = {},
) {
  let ledger;
  if (refreshAttestationDigest) {
    ledger = readJson(root, "config/domain-core-legacy-deletion.json");
    for (const row of ledger.rows) {
      const receiptPath = row?.receipts?.promotion;
      if (typeof receiptPath !== "string") continue;
      const receipt = readJson(root, receiptPath);
      const attestationPath = receipt?.promotionAttestation?.path;
      if (typeof attestationPath !== "string") continue;
      receipt.promotionAttestation.sha256 = sha256Bytes(
        readFileSync(join(root, attestationPath)),
      );
      writeJson(root, receiptPath, receipt);
    }
  }
  if (refreshActivationAuthority) {
    const profilesPath = join(root, "config/domain-core-build-profiles.json");
    const ledgerPath = join(root, "config/domain-core-legacy-deletion.json");
    const profiles = readJson(root, "config/domain-core-build-profiles.json");
    ledger ??= readJson(root, "config/domain-core-legacy-deletion.json");
    const profilesPretty = `${JSON.stringify(profiles, null, 2)}\n`;
    const ledgerPretty = `${JSON.stringify(ledger, null, 2)}\n`;
    writeFileSync(
      profilesPath,
      readFileSync(profilesPath, "utf8") === profilesPretty
        ? JSON.stringify(profiles)
        : profilesPretty,
    );
    writeFileSync(
      ledgerPath,
      readFileSync(ledgerPath, "utf8") === ledgerPretty
        ? JSON.stringify(ledger)
        : ledgerPretty,
    );
  }
  git(root, "add", ".");
  git(root, "commit", "--allow-empty", "-qm", "tampered attestation material");
  return git(root, "rev-parse", "HEAD");
}

function resolve(root, activation, options = {}) {
  return resolveActiveDomainCoreActivation({
    repoRoot: root,
    activationCommit: activation,
    verifyArtifactIdentity: false,
    ...options,
  });
}

test("release resolver accepts an unrelated commit after the protected activation", () => {
  const fx = activationAuthorityFixture();
  mkdirSync(join(fx.root, "website/src"), { recursive: true });
  writeFileSync(
    join(fx.root, "website/src/pricing-copy.txt"),
    "annual billing copy\n",
  );
  git(fx.root, "add", ".");
  git(fx.root, "commit", "-qm", "unrelated website release");
  const release = git(fx.root, "rev-parse", "HEAD");

  const resolved = resolve(fx.root, release);

  assert.equal(resolved.candidateCommit, fx.candidate);
  assert.equal(resolved.activationCommit, fx.activation);
});

test("release resolver rejects promotion-attestation drift after activation", () => {
  const fx = activationAuthorityFixture();
  const attestation = readJson(fx.root, fx.attestationPath);
  attestation.generatedAt = "2026-01-03T00:00:00Z";
  writeJson(fx.root, fx.attestationPath, attestation);
  const release = recommit(fx.root, {
    refreshActivationAuthority: false,
  });

  assert.throws(
    () => resolve(fx.root, release),
    /domain-core activation authority drift after activation/u,
  );
});

test("release resolver rejects digest-consistent bundle drift after activation", () => {
  const fx = activationAuthorityFixture();
  const attestation = readJson(fx.root, fx.attestationPath);
  const bundlePath = attestation.unsignedBundle.path;
  writeFileSync(
    join(fx.root, bundlePath),
    '{"bundle":"tampered-after-activation"}',
  );
  attestation.unsignedBundle.sha256 = sha256Bytes(
    readFileSync(join(fx.root, bundlePath)),
  );
  writeJson(fx.root, fx.attestationPath, attestation);
  const release = recommit(fx.root, {
    refreshActivationAuthority: false,
  });

  assert.throws(
    () => resolve(fx.root, release),
    /domain-core activation authority drift after activation/u,
  );
});

test("release resolver requires both activation authority files to identify one commit", () => {
  const fx = activationAuthorityFixture();
  const ledger = readJson(fx.root, "config/domain-core-legacy-deletion.json");
  writeFileSync(
    join(fx.root, "config/domain-core-legacy-deletion.json"),
    `${JSON.stringify(ledger, null, 2)}\n`,
  );
  git(fx.root, "add", ".");
  git(fx.root, "commit", "-qm", "rewrite only one activation authority file");
  const release = git(fx.root, "rev-parse", "HEAD");

  assert.throws(
    () => resolve(fx.root, release),
    /activation authority files must resolve to the same first-parent commit/u,
  );
});

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
  assert.throws(() => resolve(fx.root, activation), /attestation signer run/u);
});

test("rejects attestation with a non-integer signer run attempt", () => {
  const fx = activationAuthorityFixture();
  const attestation = readJson(fx.root, fx.attestationPath);
  attestation.provenance.signerRunAttempt = "1";
  writeJson(fx.root, fx.attestationPath, attestation);
  const activation = recommit(fx.root);
  assert.throws(() => resolve(fx.root, activation), /attestation signer run/u);
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
// ---------------------------------------------------------------------------
// Candidate / trusted-main ancestry-direction contract.
//
// verifyProtectedAttestationProvenance binds the attestation to a git ancestry
// claim: the candidate commit C must be a real ancestor of the trusted-main
// evaluator commit M (forward direction C -> M), matching the authoritative
// Python deletion gate. The pre-fix code (d7c9348b3) had the merge-base
// arguments reversed -- it required the trusted-main to be an ancestor of the
// candidate -- so it accepted the insecure reverse direction and rejected the
// legitimate forward direction. The existing authority fixture sets
// trustedMainCommit equal to the candidate commit, which satisfies either
// argument order (a commit is its own ancestor) and therefore does not pin the
// direction. These two tests pin it explicitly against a real descendant and a
// real ancestor.
// ---------------------------------------------------------------------------

test("accepts attestation when candidate C is an ancestor of trusted-main descendant M with matching digests", () => {
  // Forward direction: candidate C is a true ancestor of the trusted-main
  // evaluator commit M. The pre-fix reversed check (--is-ancestor M C) would
  // reject this legitimate topology because M is not an ancestor of C; the
  // current check (--is-ancestor C M) accepts it. All other fields are valid:
  // the identity tuple matches the manifest at C, and the policy/evaluator
  // digests are re-derived from M's committed bytes.
  const fx = activationAuthorityFixture();
  // Build a real descendant trusted-main commit M on top of candidate C. The
  // policy/evaluator/manifest bytes are unchanged from C, so the digests at M
  // match C's and the candidate identity tuple still resolves at C.
  git(fx.root, "commit", "--allow-empty", "-qm", "trusted-main descendant M");
  const trustedMain = git(fx.root, "rev-parse", "HEAD");
  const policySha256 = sha256GitBlob(
    fx.root,
    trustedMain,
    "config/domain-core-promotion-policy.json",
  );
  const evaluatorSha256 = sha256GitBlob(
    fx.root,
    trustedMain,
    "scripts/lib/domain-core-deterministic-candidate-bundle.mjs",
  );
  const attestation = readJson(fx.root, fx.attestationPath);
  attestation.candidate.candidateCommit = fx.candidate;
  attestation.provenance.trustedMainCommit = trustedMain;
  attestation.provenance.policySha256 = policySha256;
  attestation.provenance.evaluatorSha256 = evaluatorSha256;
  writeJson(fx.root, fx.attestationPath, attestation);
  const activation = recommit(fx.root);
  // Must not throw: C is an ancestor of M and every other field is valid.
  const resolved = resolve(fx.root, activation);
  assert.equal(resolved.active, true);
  assert.equal(resolved.candidateCommit, fx.candidate);
});

test("rejects attestation when trusted-main T is an ancestor of candidate C even if digests match T", () => {
  // Reverse direction: trusted-main T is an ancestor of candidate C. The
  // pre-fix reversed check (--is-ancestor T C) accepted this -- T really is an
  // ancestor of C -- so an attacker could anchor policy/evaluator digests to a
  // stale trusted-main that predates the candidate, bypassing the requirement
  // that the evaluated policy/evaluator bytes came after the candidate. The
  // current check (--is-ancestor C T) fails closed because C is not an ancestor
  // of T. Every other attestation field is valid: the identity tuple matches
  // the manifest at C, and the policy/evaluator digests are the real bytes at
  // T. Only the ancestry direction is wrong, so this isolates the contract.
  const root = mkdtempSync(join(tmpdir(), "domain-core-attest-ancestry-rev-"));
  mkdirSync(join(root, "crates/openburnbar-domain-core"), { recursive: true });
  mkdirSync(join(root, "config"), { recursive: true });
  mkdirSync(join(root, "scripts/lib"), { recursive: true });
  mkdirSync(join(root, "config/domain-core-promotion-attestations/quota"), {
    recursive: true,
  });
  const rowIds = [
    "quota.claude_statusline",
    "quota.codex_usage",
    "quota.cursor_usage",
    "quota.anthropic_headers",
  ];
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
        modes: { quota: "legacy" },
      },
    },
  };
  const ledger = {
    rows: rowIds.map((id) => ({ id, authorityGeneration: 0, receipts: {} })),
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
  git(root, "commit", "-qm", "trusted-main T");
  const trustedMain = git(root, "rev-parse", "HEAD");
  // Candidate C is a real descendant of T. The manifest is unchanged so the
  // identity tuple at C matches the attestation claim; only the ancestry
  // direction between C and T is inverted.
  git(root, "commit", "--allow-empty", "-qm", "candidate C descendant of T");
  const candidate = git(root, "rev-parse", "HEAD");
  const policySha256 = sha256GitBlob(
    root,
    trustedMain,
    "config/domain-core-promotion-policy.json",
  );
  const evaluatorSha256 = sha256GitBlob(
    root,
    trustedMain,
    "scripts/lib/domain-core-deterministic-candidate-bundle.mjs",
  );
  const attestationPath =
    "config/domain-core-promotion-attestations/quota/1.json";
  const attestation = {
    candidate: {
      candidateCommit: candidate,
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
      trustedMainCommit: trustedMain,
      policySha256,
      evaluatorSha256,
    },
  };
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
  profile.profiles["public-production"].modes.quota = "rust";
  writeState();
  git(root, "add", ".");
  git(root, "commit", "-qm", "activation P");
  const activation = git(root, "rev-parse", "HEAD");
  // Must throw: digests match T and the identity tuple matches C, but T is an
  // ancestor of C -- the wrong direction -- so the candidate cannot be proven
  // to descend from the bytes that evaluated it.
  assert.throws(
    () => resolve(root, activation),
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
  const provenance = Buffer.from(provenanceBytes ?? '{"provenance":"quota-1"}');
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
  const trimmedEvaluator = sha256TrimmedGitBlob(
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
  const trimmedPolicy = sha256TrimmedGitBlob(fx.root, trustedMain, policyRel);
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
    /domain-core activation authority drift after activation/u,
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
    /domain-core activation authority drift after activation/u,
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
  const attackerRel =
    "config/domain-core-promotion-bundles/quota/attacker.json";
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
  const activation = recommit(fx.root);
  assert.throws(
    () => resolve(fx.root, activation),
    /attestation unsigned bundle digest mismatch/u,
  );
});

test("resolveActiveDomainCoreActivation supports requireClean: false on dirty worktree", () => {
  const fx = activationAuthorityFixture();
  const activation = recommit(fx.root);
  writeFileSync(join(fx.root, "untracked-dirty.tmp"), "dirty");
  assert.throws(
    () => resolve(fx.root, activation, { requireClean: true }),
    /signed domain-core activation checkout must be clean/u,
  );
  const result = resolve(fx.root, activation, { requireClean: false });
  assert.equal(result.active, true);
});
