import assert from "node:assert/strict";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { run } from "./create-domain-core-native-release-evidence.mjs";
import { buildPublicationManifest } from "./create-domain-core-native-publication.mjs";
import { publicDomainProfileSha256 } from "../lib/domain-core-native-release.mjs";

const CANDIDATE = {
  candidateCommit: "a".repeat(40),
  coreVersion: "0.3.0",
  abiVersion: 3,
  sourceSha256: "b".repeat(64),
};
const ACTIVATION_COMMIT = "c".repeat(40);

function fixture({ profileName = "public-production", rust = ["quota"] } = {}) {
  const directory = mkdtempSync(join(tmpdir(), "native-release-evidence-"));
  const paths = {
    directory,
    artifact: join(directory, "OpenBurnBar-1.2.3-macOS.dmg"),
    candidate: join(directory, "domain-core-candidate-bundle.json"),
    promotion: join(directory, "promotion.sigstore.jsonl"),
    rollback: join(directory, "domain-core-public-production-rollback.json"),
    profile: join(directory, "profile.json"),
    activation: join(directory, "activation.json"),
    output: join(directory, "evidence"),
    releaseCommit:
      rust.length === 0 ? CANDIDATE.candidateCommit : ACTIVATION_COMMIT,
  };
  writeFileSync(paths.artifact, "signed artifact bytes");
  writeFileSync(paths.promotion, "{}\n");
  writeFileSync(
    paths.candidate,
    `${JSON.stringify({
      schemaVersion: 1,
      bundleKind: "unsigned-domain-core-candidate",
      status: "eligible_for_attestation",
      proofComplete: true,
      eligibleForAttestation: true,
      promotionAuthorized: false,
      candidate: CANDIDATE,
      workflow: {
        repository: "Imagine-That-Ai/BurnBar",
        workflowPath: ".github/workflows/domain-core.yml",
        workflowName: "Shared Rust domain core",
        runId: 101,
        runAttempt: 2,
        event: "push",
        ref: "refs/heads/main",
        headSha: CANDIDATE.candidateCommit,
        jobs: [],
      },
    })}\n`,
  );
  writeFileSync(
    paths.rollback,
    `${JSON.stringify({
      schemaVersion: 1,
      candidateIdentity: CANDIDATE,
      modes: {
        quota: "legacy",
        cloudVault: "legacy",
        cloudVaultRewrap: "legacy",
        cloudVaultSearch: "legacy",
        hermes: "legacy",
        pricing: "legacy",
      },
    })}\n`,
  );
  const domains = [
    "quota",
    "cloudVault",
    "cloudVaultRewrap",
    "cloudVaultSearch",
    "hermes",
    "pricing",
  ];
  const profile = {
    schemaVersion: 1,
    name: profileName,
    artifactAuthority: "signed",
    distribution: "public",
    rolloutChannel: null,
    evidenceEnabled: false,
    modes: Object.fromEntries(
      domains.map((domain) => [
        domain,
        rust.includes(domain) ? "rust" : "legacy",
      ]),
    ),
    candidateIdentity: CANDIDATE,
  };
  writeFileSync(paths.profile, `${JSON.stringify(profile)}\n`);
  writeFileSync(
    paths.activation,
    `${JSON.stringify({
      active: rust.length > 0,
      candidateCommit: CANDIDATE.candidateCommit,
      activationCommit: paths.releaseCommit,
      coreVersion: CANDIDATE.coreVersion,
      abiVersion: CANDIDATE.abiVersion,
      sourceSha256: CANDIDATE.sourceSha256,
      changedPathsSha256:
        rust.length === 0
          ? "4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945"
          : "d".repeat(64),
      domains: rust.map((domain, index) => ({
        domain,
        rowId: `${domain}.row`,
        promotionReceiptPath: `receipts/${domain}.json`,
        attestationPath: `attestations/${domain}.json`,
        bundlePath: `bundles/${domain}.json`,
        provenancePath: `provenance/${domain}.json`,
        signerRunId: 100 + index,
        signerRunAttempt: 1,
        publicProfileSha256: publicDomainProfileSha256(profile, domain),
      })),
    })}\n`,
  );
  return paths;
}

function argumentsFor(paths, profileName = "public-production") {
  return [
    "--consumer",
    "apple",
    "--artifact",
    paths.artifact,
    "--version",
    "1.2.3",
    "--tag",
    "v1.2.3",
    "--commit",
    paths.releaseCommit,
    "--profile-name",
    profileName,
    "--profile",
    paths.profile,
    "--activation",
    paths.activation,
    "--candidate-bundle",
    paths.candidate,
    "--promotion-attestation",
    paths.promotion,
    "--protected-signer-run-id",
    "202",
    "--protected-signer-run-attempt",
    "3",
    "--rollback-artifact",
    paths.rollback,
    "--output-dir",
    paths.output,
  ];
}

function replaceArgument(args, flag, value) {
  const index = args.indexOf(flag);
  assert.notEqual(index, -1, flag);
  args[index + 1] = value;
}

test("creates v2 predicates only for Rust-authoritative public domains", () => {
  const paths = fixture({ rust: ["quota", "pricing"] });
  try {
    const plan = run(argumentsFor(paths), { promotionVerifier: () => [] });
    assert.deepEqual(
      plan.domains.map((entry) => entry.domain),
      ["quota", "pricing"],
    );
    assert.equal(plan.rollback, false);
    for (const entry of plan.domains) {
      const predicate = JSON.parse(readFileSync(entry.predicatePath, "utf8"));
      assert.equal(predicate.schemaVersion, 2);
      assert.equal(
        predicate.candidate.candidateCommit,
        CANDIDATE.candidateCommit,
      );
      assert.equal(
        predicate.release.publicProfileSha256,
        publicDomainProfileSha256(
          JSON.parse(readFileSync(paths.profile, "utf8")),
          entry.domain,
        ),
      );
      assert.deepEqual(predicate.publicProfile, {
        profile: "public-production",
        domain: entry.domain,
        mode: "rust",
        sha256: predicate.release.publicProfileSha256,
      });
      assert.equal(
        predicate.activation.candidateCommit,
        CANDIDATE.candidateCommit,
      );
      assert.equal(predicate.activation.activationCommit, ACTIVATION_COMMIT);
    }
  } finally {
    rmSync(paths.directory, { recursive: true, force: true });
  }
});

test("all-legacy public release produces no misleading Rust evidence", () => {
  const paths = fixture({ rust: [] });
  try {
    const plan = run(argumentsFor(paths), { promotionVerifier: () => [] });
    assert.deepEqual(plan.domains, []);
  } finally {
    rmSync(paths.directory, { recursive: true, force: true });
  }
});

test("rollback release cannot create or publish Rust domain attestations", () => {
  const paths = fixture({
    profileName: "public-production-rollback",
    rust: [],
  });
  try {
    const plan = run(argumentsFor(paths, "public-production-rollback"), {
      promotionVerifier: () => [],
    });
    assert.equal(plan.rollback, true);
    assert.deepEqual(plan.domains, []);
    assert.deepEqual(
      readdirSync(paths.output).filter((name) =>
        name.endsWith(".predicate.json"),
      ),
      [],
    );
    const bundles = join(paths.directory, "bundles");
    mkdirSync(bundles);
    const publication = buildPublicationManifest(plan, bundles);
    assert.equal(publication.nativeArtifactOnly, true);
    assert.deepEqual(publication.bundles, []);
  } finally {
    rmSync(paths.directory, { recursive: true, force: true });
  }
});

test("rejects profile, candidate, and artifact substitution", () => {
  const paths = fixture();
  try {
    const profile = JSON.parse(readFileSync(paths.profile, "utf8"));
    profile.candidateIdentity.sourceSha256 = "c".repeat(64);
    writeFileSync(paths.profile, `${JSON.stringify(profile)}\n`);
    assert.throws(
      () => run(argumentsFor(paths), { promotionVerifier: () => [] }),
      /exact candidate-bound/,
    );
  } finally {
    rmSync(paths.directory, { recursive: true, force: true });
  }
});

test("accepts Apple and Android prereleases but keeps Windows stable-only", () => {
  for (const consumer of ["apple", "android"]) {
    const paths = fixture({
      rust: [consumer === "apple" ? "quota" : "cloudVault"],
    });
    try {
      const version = "1.2.3-rc.1";
      const artifact = join(
        paths.directory,
        consumer === "apple"
          ? `OpenBurnBar-${version}-macOS.dmg`
          : `OpenBurnBar-${version}-Android.aab`,
      );
      writeFileSync(artifact, `${consumer} prerelease artifact`);
      const args = argumentsFor(paths);
      replaceArgument(args, "--consumer", consumer);
      replaceArgument(args, "--artifact", artifact);
      replaceArgument(args, "--version", version);
      replaceArgument(args, "--tag", `v${version}`);
      const plan = run(args, { promotionVerifier: () => [] });
      assert.equal(plan.consumer, consumer);
      assert.equal(plan.tag, `v${version}`);
    } finally {
      rmSync(paths.directory, { recursive: true, force: true });
    }
  }

  const windows = fixture();
  try {
    const version = "1.2.3-rc.1";
    const artifact = join(
      windows.directory,
      `OpenBurnBar-${version}-windows-release.zip`,
    );
    writeFileSync(artifact, "windows prerelease artifact");
    const args = argumentsFor(windows);
    replaceArgument(args, "--consumer", "windows");
    replaceArgument(args, "--artifact", artifact);
    replaceArgument(args, "--version", version);
    replaceArgument(args, "--tag", `windows-v${version}`);
    assert.throws(
      () => run(args, { promotionVerifier: () => [] }),
      /native release version is invalid/u,
    );
  } finally {
    rmSync(windows.directory, { recursive: true, force: true });
  }
});
