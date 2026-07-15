import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { run } from "./create-domain-core-native-release-evidence.mjs";

const CANDIDATE = {
  candidateCommit: "a".repeat(40),
  coreVersion: "0.3.0",
  abiVersion: 3,
  sourceSha256: "b".repeat(64),
};

function fixture({ profileName = "public-production", rust = ["quota"] } = {}) {
  const directory = mkdtempSync(join(tmpdir(), "native-release-evidence-"));
  const paths = {
    directory,
    artifact: join(directory, "OpenBurnBar-1.2.3-macOS.dmg"),
    candidate: join(directory, "domain-core-candidate-bundle.json"),
    promotion: join(directory, "promotion.sigstore.jsonl"),
    rollback: join(directory, "domain-core-public-production-rollback.json"),
    profile: join(directory, "profile.json"),
    output: join(directory, "evidence"),
    androidAbiManifest: join(directory, "android-universal-abi-manifest.json"),
  };
  writeFileSync(paths.artifact, "signed artifact bytes");
  writeFileSync(paths.promotion, "{}\n");
  writeFileSync(
    paths.androidAbiManifest,
    `${JSON.stringify({
      schemaVersion: 1,
      target: "android-universal",
      library: "libopenburnbar_domain_ffi.so",
      candidateAar: {
        fileName: "openburnbar-domain-core.aar",
        sha256: "d".repeat(64),
      },
      abis: [
        {
          abi: "arm64-v8a",
          path: "base/lib/arm64-v8a/libopenburnbar_domain_ffi.so",
          sha256: "e".repeat(64),
        },
        {
          abi: "x86_64",
          path: "base/lib/x86_64/libopenburnbar_domain_ffi.so",
          sha256: "f".repeat(64),
        },
      ],
    })}\n`,
  );
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
  writeFileSync(
    paths.profile,
    `${JSON.stringify({
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
    CANDIDATE.candidateCommit,
    "--profile-name",
    profileName,
    "--profile",
    paths.profile,
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
        plan.publicProfileSha256,
      );
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

test("rollback release retains evidence for every native consumer domain", () => {
  const paths = fixture({
    profileName: "public-production-rollback",
    rust: [],
  });
  try {
    const plan = run(argumentsFor(paths, "public-production-rollback"), {
      promotionVerifier: () => [],
    });
    assert.equal(plan.rollback, true);
    assert.deepEqual(
      plan.domains.map((entry) => entry.domain),
      [
        "quota",
        "cloudVault",
        "cloudVaultRewrap",
        "cloudVaultSearch",
        "hermes",
        "pricing",
      ],
    );
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
      if (consumer === "android") {
        args.push("--android-abi-manifest", paths.androidAbiManifest);
      }
      const plan = run(args, { promotionVerifier: () => [] });
      assert.equal(plan.consumer, consumer);
      assert.equal(plan.tag, `v${version}`);
      if (consumer === "android") {
        const predicate = JSON.parse(
          readFileSync(plan.domains[0].predicatePath, "utf8"),
        );
        assert.equal(predicate.androidUniversal.target, "android-universal");
        assert.match(
          predicate.androidUniversal.manifestSha256,
          /^[0-9a-f]{64}$/u,
        );
        assert.equal(predicate.androidUniversal.abis[1].abi, "x86_64");
      }
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
