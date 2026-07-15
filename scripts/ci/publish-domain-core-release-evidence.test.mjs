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

import {
  publishManifest,
  validateManifest,
} from "./publish-domain-core-release-evidence.mjs";

const CANDIDATE = Object.freeze({
  candidateCommit: "a".repeat(40),
  coreVersion: "0.3.0",
  abiVersion: 3,
  sourceSha256: "b".repeat(64),
});

function sha(value) {
  return createHash("sha256").update(value).digest("hex");
}

function fixture() {
  const directory = mkdtempSync(join(tmpdir(), "domain-core-publisher-test-"));
  const artifact = join(directory, "OpenBurnBar-1.2.3-macOS.dmg");
  const predicatePath = join(directory, "quota.predicate.json");
  const bundlePath = join(directory, "quota.sigstore.json");
  writeFileSync(artifact, "signed-release-bytes");
  writeFileSync(bundlePath, "signed-attestation-bundle");
  const predicate = {
    schemaVersion: 2,
    predicateType:
      "https://openburnbar.dev/attestations/domain-core-release-artifact/v2",
    consumer: "apple",
    domain: "quota",
    artifactKind: "macos-dmg",
    target: "macos-arm64",
    candidate: CANDIDATE,
    sourceRun: {
      repository: "Imagine-That-Ai/BurnBar",
      workflowPath: ".github/workflows/domain-core.yml",
      runId: 101,
      runAttempt: 2,
      event: "push",
      ref: "refs/heads/main",
      headSha: CANDIDATE.candidateCommit,
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
      fileName: "domain-core-legacy-rollback.json",
      sha256: "e".repeat(64),
      candidate: CANDIDATE,
    },
    artifact: {
      fileName: basename(artifact),
      sha256: sha(readFileSync(artifact)),
    },
    release: {
      version: "1.2.3",
      tag: "v1.2.3",
      commit: CANDIDATE.candidateCommit,
      publicProfileSha256: "f".repeat(64),
    },
  };
  writeFileSync(predicatePath, `${JSON.stringify(predicate, null, 2)}\n`);
  const manifest = {
    schemaVersion: 2,
    repository: "Imagine-That-Ai/BurnBar",
    tag: "v1.2.3",
    commit: CANDIDATE.candidateCommit,
    consumer: "apple",
    signerWorkflow: ".github/workflows/release.yml",
    artifactPath: artifact,
    bundles: [
      {
        domain: "quota",
        assetName:
          "OpenBurnBar-1.2.3-macOS-quota-domain-core-attestation.sigstore.json",
        bundlePath,
        predicatePath,
      },
    ],
  };
  return {
    directory,
    artifact,
    predicate,
    predicatePath,
    bundlePath,
    manifest,
  };
}

class FakeClient {
  constructor(predicate) {
    this.predicate = predicate;
    this.assets = new Map();
    this.calls = [];
    this.uploadHook = undefined;
    this.downloadHook = undefined;
  }

  run(args, { allowFailure = false } = {}) {
    this.calls.push([...args]);
    if (args[0] === "attestation" && args[1] === "verify") {
      return {
        status: 0,
        stdout: JSON.stringify([
          { verificationResult: { statement: { predicate: this.predicate } } },
        ]),
        stderr: "",
      };
    }
    if (args[0] === "api") {
      if (args[1].includes("/commits/")) {
        return {
          status: 0,
          stdout: JSON.stringify({ sha: CANDIDATE.candidateCommit }),
          stderr: "",
        };
      }
      return {
        status: 0,
        stdout: JSON.stringify({
          tag_name: "v1.2.3",
          draft: false,
          prerelease: false,
        }),
        stderr: "",
      };
    }
    if (args[0] === "release" && args[1] === "view") {
      return {
        status: 0,
        stdout: JSON.stringify({
          assets: [...this.assets.keys()].map((name) => ({ name })),
        }),
        stderr: "",
      };
    }
    if (args[0] === "release" && args[1] === "download") {
      const name = args[args.indexOf("--pattern") + 1];
      const directory = args[args.indexOf("--dir") + 1];
      const current = this.assets.get(name);
      if (!current) throw new Error(`missing fake release asset ${name}`);
      mkdirSync(directory, { recursive: true });
      let contents = current;
      if (this.downloadHook)
        contents = this.downloadHook(name, contents, this.calls) ?? contents;
      writeFileSync(join(directory, name), contents);
      return { status: 0, stdout: "", stderr: "" };
    }
    if (args[0] === "release" && args[1] === "upload") {
      const path = args[3];
      const name = basename(path);
      if (this.uploadHook) {
        const hooked = this.uploadHook(name, path, this);
        if (hooked) return hooked;
      }
      if (this.assets.has(name)) {
        return { status: 1, stdout: "", stderr: "already exists" };
      }
      this.assets.set(name, readFileSync(path));
      return { status: 0, stdout: "", stderr: "" };
    }
    if (allowFailure) return { status: 1, stdout: "", stderr: "unsupported" };
    throw new Error(`unsupported gh call: ${args.join(" ")}`);
  }
}

function uploads(client) {
  return client.calls.filter(
    (args) => args[0] === "release" && args[1] === "upload",
  );
}

test("publishes verified bundles before the immutable artifact and re-downloads all bytes", () => {
  const files = fixture();
  try {
    const manifest = validateManifest(files.manifest);
    const client = new FakeClient(files.predicate);
    const result = publishManifest(manifest, { client });
    assert.deepEqual(result.uploaded, [
      files.manifest.bundles[0].assetName,
      basename(files.artifact),
    ]);
    assert.deepEqual(
      uploads(client).map((args) => basename(args[3])),
      [files.manifest.bundles[0].assetName, basename(files.artifact)],
    );
    const downloads = client.calls.filter(
      (args) => args[0] === "release" && args[1] === "download",
    );
    assert.deepEqual(
      downloads.map((args) => args[args.indexOf("--pattern") + 1]),
      [basename(files.artifact), files.manifest.bundles[0].assetName],
    );
    assert.equal(
      client.calls.some((args) => args.includes("--clobber")),
      false,
    );
    assert.equal(
      client.calls.some(
        (args) =>
          args[0] === "release" &&
          new Set(["create", "edit", "delete"]).has(args[1]),
      ),
      false,
    );
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});

test("preflights every existing collision before any release mutation", () => {
  const files = fixture();
  try {
    const manifest = validateManifest(files.manifest);
    const client = new FakeClient(files.predicate);
    client.assets.set(basename(files.artifact), Buffer.from("different"));
    assert.throws(
      () => publishManifest(manifest, { client }),
      /refusing to replace non-identical/u,
    );
    assert.equal(uploads(client).length, 0);
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});

test("rejects a published release tag moved away from the protected candidate", () => {
  const files = fixture();
  try {
    const manifest = validateManifest(files.manifest);
    const client = new FakeClient(files.predicate);
    const originalRun = client.run.bind(client);
    client.run = (args, options) => {
      if (args[0] === "api" && args[1].includes("/commits/")) {
        client.calls.push([...args]);
        return {
          status: 0,
          stdout: JSON.stringify({ sha: "9".repeat(40) }),
          stderr: "",
        };
      }
      return originalRun(args, options);
    };
    assert.throws(
      () => publishManifest(manifest, { client }),
      /published release tag does not resolve to the exact candidate commit/u,
    );
    assert.equal(uploads(client).length, 0);
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});

test("an all-identical rerun is idempotent", () => {
  const files = fixture();
  try {
    const manifest = validateManifest(files.manifest);
    const client = new FakeClient(files.predicate);
    client.assets.set(basename(files.artifact), readFileSync(files.artifact));
    client.assets.set(
      files.manifest.bundles[0].assetName,
      readFileSync(files.bundlePath),
    );
    assert.deepEqual(publishManifest(manifest, { client }), { uploaded: [] });
    assert.equal(uploads(client).length, 0);
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});

test("rejects a valid but byte-different existing attestation bundle before mutation", () => {
  const files = fixture();
  try {
    const manifest = validateManifest(files.manifest);
    const client = new FakeClient(files.predicate);
    client.assets.set(
      files.manifest.bundles[0].assetName,
      Buffer.from("different-valid-attestation-encoding"),
    );
    assert.throws(
      () => publishManifest(manifest, { client }),
      /refusing non-identical attestation bundle/u,
    );
    assert.equal(uploads(client).length, 0);
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});

test("accepts a byte-identical concurrent bundle upload", () => {
  const files = fixture();
  try {
    const manifest = validateManifest(files.manifest);
    const client = new FakeClient(files.predicate);
    client.uploadHook = (name, path, instance) => {
      if (name === files.manifest.bundles[0].assetName) {
        instance.assets.set(name, readFileSync(path));
        instance.uploadHook = undefined;
        return { status: 1, stdout: "", stderr: "concurrent" };
      }
      return undefined;
    };
    const result = publishManifest(manifest, { client });
    assert.deepEqual(result.uploaded, [basename(files.artifact)]);
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});

test("rejects a byte-different concurrent attestation bundle", () => {
  const files = fixture();
  try {
    const manifest = validateManifest(files.manifest);
    const client = new FakeClient(files.predicate);
    client.uploadHook = (name, _path, instance) => {
      if (name === files.manifest.bundles[0].assetName) {
        instance.assets.set(
          name,
          Buffer.from("different-valid-attestation-encoding"),
        );
        return { status: 1, stdout: "", stderr: "concurrent" };
      }
      return undefined;
    };
    assert.throws(
      () => publishManifest(manifest, { client }),
      /refusing non-identical attestation bundle/u,
    );
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});

test("rejects a non-identical concurrent artifact upload", () => {
  const files = fixture();
  try {
    const manifest = validateManifest(files.manifest);
    const client = new FakeClient(files.predicate);
    client.uploadHook = (name, _path, instance) => {
      if (name === basename(files.artifact)) {
        instance.assets.set(name, Buffer.from("attacker-bytes"));
        return { status: 1, stdout: "", stderr: "concurrent" };
      }
      return undefined;
    };
    assert.throws(
      () => publishManifest(manifest, { client }),
      /concurrent immutable release artifact differs/u,
    );
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});

test("rejects predicate substitution even when gh reports a valid signature", () => {
  const files = fixture();
  try {
    const manifest = validateManifest(files.manifest);
    const client = new FakeClient({
      ...files.predicate,
      candidate: { ...CANDIDATE, candidateCommit: "9".repeat(40) },
    });
    assert.throws(
      () => publishManifest(manifest, { client }),
      /does not contain its exact predicate/u,
    );
    assert.equal(uploads(client).length, 0);
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});

test("rejects a later release commit even with the same version ABI and source digest", () => {
  const files = fixture();
  try {
    const predicate = {
      ...files.predicate,
      release: { ...files.predicate.release, commit: "8".repeat(40) },
    };
    writeFileSync(files.predicatePath, `${JSON.stringify(predicate)}\n`);
    const manifest = { ...files.manifest, commit: "8".repeat(40) };
    assert.throws(
      () => validateManifest(manifest),
      /exact candidate tag commit/u,
    );
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});

test("rejects extra predicate fields and non-positive provenance run IDs", () => {
  const files = fixture();
  try {
    const cases = [
      { ...files.predicate, unexpected: true },
      {
        ...files.predicate,
        sourceRun: { ...files.predicate.sourceRun, runId: 0 },
      },
      {
        ...files.predicate,
        promotionProof: {
          ...files.predicate.promotionProof,
          signerRun: {
            ...files.predicate.promotionProof.signerRun,
            runAttempt: 0,
          },
        },
      },
    ];
    for (const predicate of cases) {
      writeFileSync(files.predicatePath, `${JSON.stringify(predicate)}\n`);
      assert.throws(() => validateManifest(files.manifest));
    }
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});

test("detects final-state mutation after successful create-only uploads", () => {
  const files = fixture();
  try {
    const manifest = validateManifest(files.manifest);
    const client = new FakeClient(files.predicate);
    let artifactDownloads = 0;
    client.downloadHook = (name, contents) => {
      if (name === basename(files.artifact)) {
        artifactDownloads += 1;
        if (artifactDownloads === 1) return Buffer.from("mutated-after-upload");
      }
      return contents;
    };
    assert.throws(
      () => publishManifest(manifest, { client }),
      /published artifact bytes differ/u,
    );
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});

test("detects a release tag moved after create-only uploads", () => {
  const files = fixture();
  try {
    const manifest = validateManifest(files.manifest);
    const client = new FakeClient(files.predicate);
    const originalRun = client.run.bind(client);
    let commitLookups = 0;
    client.run = (args, options) => {
      if (args[0] === "api" && args[1].includes("/commits/")) {
        commitLookups += 1;
        if (commitLookups > 1) {
          client.calls.push([...args]);
          return {
            status: 0,
            stdout: JSON.stringify({ sha: "9".repeat(40) }),
            stderr: "",
          };
        }
      }
      return originalRun(args, options);
    };
    assert.throws(
      () => publishManifest(manifest, { client }),
      /published release tag does not resolve to the exact candidate commit/u,
    );
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});

test("detects final attestation bundle mutation after successful uploads", () => {
  const files = fixture();
  try {
    const manifest = validateManifest(files.manifest);
    const client = new FakeClient(files.predicate);
    client.downloadHook = (name, contents) => {
      if (name === files.manifest.bundles[0].assetName) {
        return Buffer.from("mutated-valid-attestation-encoding");
      }
      return contents;
    };
    assert.throws(
      () => publishManifest(manifest, { client }),
      /refusing non-identical attestation bundle/u,
    );
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});
