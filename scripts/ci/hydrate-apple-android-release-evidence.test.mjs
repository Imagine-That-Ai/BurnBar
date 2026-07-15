import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import test from "node:test";

import { hydrateExistingEvidence } from "./hydrate-apple-android-release-evidence.mjs";

const COMMIT = "a".repeat(40);
const CANDIDATE = {
  candidateCommit: COMMIT,
  coreVersion: "0.3.0",
  abiVersion: 3,
  sourceSha256: "b".repeat(64),
};

function sha(path) {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

function fixture() {
  const directory = mkdtempSync(join(tmpdir(), "hydrate-native-evidence-"));
  const makePlan = ({
    consumer,
    domain,
    artifactName,
    artifactKind,
    target,
  }) => {
    const artifactPath = join(directory, artifactName);
    const predicatePath = join(
      directory,
      `${consumer}-${domain}.predicate.json`,
    );
    writeFileSync(artifactPath, `${consumer} artifact`);
    const predicate = {
      schemaVersion: 2,
      predicateType:
        "https://openburnbar.dev/attestations/domain-core-release-artifact/v2",
      consumer,
      domain,
      artifactKind,
      target,
      candidate: CANDIDATE,
      sourceRun: {
        repository: "Imagine-That-Ai/BurnBar",
        workflowPath: ".github/workflows/domain-core.yml",
        runId: 101,
        runAttempt: 2,
        event: "push",
        ref: "refs/heads/main",
        headSha: COMMIT,
      },
      promotionProof: {
        signerWorkflow: ".github/workflows/domain-core-promotion-proof.yml",
        predicateType: "https://slsa.dev/provenance/v1",
        signerRun: { runId: 202, runAttempt: 3 },
        attestationSubject: {
          fileName: "domain-core-candidate-bundle.json",
          sha256: "c".repeat(64),
        },
        attestationBundleSha256: "d".repeat(64),
      },
      rollbackArtifact: {
        fileName: "domain-core-public-production-rollback.json",
        sha256: "e".repeat(64),
        candidate: CANDIDATE,
      },
      artifact: {
        fileName: basename(artifactPath),
        sha256: sha(artifactPath),
      },
      release: {
        version: "1.2.3",
        tag: "v1.2.3",
        commit: COMMIT,
        publicProfileSha256: "f".repeat(64),
      },
    };
    writeFileSync(predicatePath, `${JSON.stringify(predicate)}\n`);
    return {
      schemaVersion: 2,
      consumer,
      tag: "v1.2.3",
      commit: COMMIT,
      artifactPath,
      signerWorkflow: ".github/workflows/release.yml",
      domains: [
        {
          domain,
          predicatePath,
          bundleAssetName: `OpenBurnBar-1.2.3-${consumer}-${domain}-domain-core.sigstore.json`,
        },
      ],
      predicate,
    };
  };
  return {
    directory,
    output: join(directory, "hydrated"),
    apple: makePlan({
      consumer: "apple",
      domain: "quota",
      artifactName: "OpenBurnBar-1.2.3-macOS.dmg",
      artifactKind: "macos-dmg",
      target: "macos-arm64",
    }),
    android: makePlan({
      consumer: "android",
      domain: "cloudVault",
      artifactName: "OpenBurnBar-1.2.3-Android.aab",
      artifactKind: "android-aab",
      target: "android-universal",
    }),
  };
}

class FakeClient {
  constructor(
    files,
    { draft = true, assets = new Map(), commit = COMMIT } = {},
  ) {
    this.files = files;
    this.draft = draft;
    this.assets = assets;
    this.commit = commit;
    this.calls = [];
    this.invalidAttestation = false;
    this.releaseStates = [];
  }

  run(args) {
    this.calls.push(args);
    if (args[0] === "api" && args[1].includes("/commits/")) {
      return {
        status: 0,
        stdout: JSON.stringify({ sha: this.commit }),
        stderr: "",
      };
    }
    if (args[0] === "api" && args[1].includes("/releases/tags/")) {
      const draft =
        this.releaseStates.length > 0 ? this.releaseStates.shift() : this.draft;
      return {
        status: 0,
        stdout: JSON.stringify({
          tag_name: "v1.2.3",
          target_commitish: COMMIT,
          draft,
          assets: [...this.assets.keys()].map((name) => ({ name })),
        }),
        stderr: "",
      };
    }
    if (args[0] === "release" && args[1] === "download") {
      const name = args[args.indexOf("--pattern") + 1];
      const destination = args[args.indexOf("--dir") + 1];
      mkdirSync(destination, { recursive: true });
      writeFileSync(join(destination, name), this.assets.get(name));
      return { status: 0, stdout: "", stderr: "" };
    }
    if (args[0] === "attestation" && args[1] === "verify") {
      const artifact = args[2];
      const predicate = artifact.endsWith(".dmg")
        ? this.files.apple.predicate
        : this.files.android.predicate;
      return {
        status: 0,
        stdout: JSON.stringify([
          {
            verificationResult: {
              statement: {
                predicate: this.invalidAttestation
                  ? { ...predicate, target: "substituted" }
                  : predicate,
              },
            },
          },
        ]),
        stderr: "",
      };
    }
    throw new Error(`unsupported fake gh call: ${args.join(" ")}`);
  }
}

test("draft retry hydrates and verifies only existing evidence", () => {
  const files = fixture();
  const appleName = files.apple.domains[0].bundleAssetName;
  const client = new FakeClient(files, {
    assets: new Map([[appleName, "existing apple bundle"]]),
  });
  try {
    const outputs = hydrateExistingEvidence(
      [files.apple, files.android],
      files.output,
      client,
    );
    assert.equal(outputs.release_published, "false");
    assert.equal(outputs.apple_quota_existing, "true");
    assert.equal(outputs.android_cloud_vault_existing, "false");
    assert.equal(
      readFileSync(join(files.output, appleName), "utf8"),
      "existing apple bundle",
    );
    assert.equal(
      client.calls.some(
        (args) => args[0] === "release" && args[1] === "upload",
      ),
      false,
    );
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});

test("published retry reports missing evidence without mutating the release", () => {
  const files = fixture();
  const client = new FakeClient(files, { draft: false });
  try {
    const outputs = hydrateExistingEvidence(
      [files.apple, files.android],
      files.output,
      client,
    );
    assert.equal(outputs.release_published, "true");
    assert.equal(outputs.apple_quota_existing, "false");
    assert.equal(outputs.android_cloud_vault_existing, "false");
    assert.equal(
      client.calls.some((args) => args[0] === "release"),
      false,
    );
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});

test("rejects substituted evidence, moved tags, and inconsistent release state", () => {
  const files = fixture();
  const appleName = files.apple.domains[0].bundleAssetName;
  try {
    const substituted = new FakeClient(files, {
      assets: new Map([[appleName, "bundle"]]),
    });
    substituted.invalidAttestation = true;
    assert.throws(
      () =>
        hydrateExistingEvidence(
          [files.apple, files.android],
          files.output,
          substituted,
        ),
      /does not contain its exact predicate/u,
    );

    const moved = new FakeClient(files, { commit: "9".repeat(40) });
    assert.throws(
      () =>
        hydrateExistingEvidence(
          [files.apple, files.android],
          files.output,
          moved,
        ),
      /tag moved away/u,
    );

    const inconsistent = new FakeClient(files);
    inconsistent.releaseStates = [true, false];
    assert.throws(
      () =>
        hydrateExistingEvidence(
          [files.apple, files.android],
          files.output,
          inconsistent,
        ),
      /inconsistent release state/u,
    );

    files.apple.domains[0].bundleAssetName = "../outside.sigstore.json";
    assert.throws(
      () =>
        hydrateExistingEvidence(
          [files.apple, files.android],
          files.output,
          new FakeClient(files),
        ),
      /safe release asset basename/u,
    );
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});
