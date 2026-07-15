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
const ACTIVATION_COMMIT = "8".repeat(40);
const ACTIVATION = Object.freeze({
  candidateCommit: CANDIDATE.candidateCommit,
  activationCommit: ACTIVATION_COMMIT,
  coreVersion: CANDIDATE.coreVersion,
  abiVersion: CANDIDATE.abiVersion,
  sourceSha256: CANDIDATE.sourceSha256,
  changedPathsSha256: "9".repeat(64),
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
    activation: ACTIVATION,
    publicProfile: {
      profile: "public-production",
      domain: "quota",
      mode: "rust",
      sha256: "f".repeat(64),
    },
    artifact: {
      fileName: basename(artifact),
      sha256: sha(readFileSync(artifact)),
    },
    release: {
      version: "1.2.3",
      tag: "v1.2.3",
      commit: ACTIVATION_COMMIT,
      publicProfileSha256: "f".repeat(64),
    },
  };
  writeFileSync(predicatePath, `${JSON.stringify(predicate, null, 2)}\n`);
  const manifest = {
    schemaVersion: 2,
    repository: "Imagine-That-Ai/BurnBar",
    tag: "v1.2.3",
    commit: ACTIVATION_COMMIT,
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

function windowsFixture({ artifactOnly = false } = {}) {
  const files = fixture();
  const artifact = join(
    files.directory,
    "OpenBurnBar-1.2.3-windows-release.zip",
  );
  writeFileSync(artifact, "signed-windows-release-bytes");
  const predicate = {
    ...files.predicate,
    consumer: "windows",
    artifactKind: "windows-release-bundle",
    target: "windows-x64-arm64",
    artifact: {
      fileName: basename(artifact),
      sha256: sha(readFileSync(artifact)),
    },
    release: {
      ...files.predicate.release,
      tag: "windows-v1.2.3",
    },
  };
  writeFileSync(files.predicatePath, `${JSON.stringify(predicate, null, 2)}\n`);
  return {
    ...files,
    artifact,
    predicate,
    manifest: {
      ...files.manifest,
      tag: "windows-v1.2.3",
      consumer: "windows",
      signerWorkflow: ".github/workflows/openburnbar-release-windows.yml",
      releaseState: "draft-then-publish",
      nativeArtifactOnly: artifactOnly,
      artifactPath: artifact,
      bundles: artifactOnly
        ? []
        : [
            {
              ...files.manifest.bundles[0],
              assetName:
                "OpenBurnBar-1.2.3-windows-quota-domain-core-attestation.sigstore.json",
            },
          ],
    },
  };
}

class FakeClient {
  constructor(
    predicate,
    { tag = "v1.2.3", draft = false, commit = ACTIVATION_COMMIT } = {},
  ) {
    this.predicate = predicate;
    this.tag = tag;
    this.draft = draft;
    this.commit = commit;
    this.assets = new Map();
    this.calls = [];
    this.uploadHook = undefined;
    this.downloadHook = undefined;
    this.attestationHook = undefined;
    this.attestationInputs = [];
    this.editHook = undefined;
  }

  run(args, { allowFailure = false } = {}) {
    this.calls.push([...args]);
    if (args[0] === "attestation" && args[1] === "verify") {
      this.attestationInputs.push({
        artifactSha256: sha(readFileSync(args[2])),
        bundlePath: args[args.indexOf("--bundle") + 1],
      });
      if (this.attestationHook) {
        const hooked = this.attestationHook(args, this.calls);
        if (hooked) return hooked;
      }
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
          stdout: JSON.stringify({ sha: this.commit }),
          stderr: "",
        };
      }
      return {
        status: 0,
        stdout: JSON.stringify({
          tag_name: this.tag,
          draft: this.draft,
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
    if (args[0] === "release" && args[1] === "edit") {
      if (this.editHook) {
        const hooked = this.editHook(args, this);
        if (hooked) return hooked;
      }
      this.draft = false;
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

function mutations(client) {
  return client.calls.filter(
    (args) => args[0] === "release" && new Set(["upload", "edit"]).has(args[1]),
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

test("publishes an all-legacy Windows artifact only after final byte verification", () => {
  const files = windowsFixture({ artifactOnly: true });
  try {
    const manifest = validateManifest(files.manifest);
    const client = new FakeClient(files.predicate, {
      tag: files.manifest.tag,
      draft: true,
    });
    assert.deepEqual(publishManifest(manifest, { client }), {
      uploaded: [basename(files.artifact)],
    });
    assert.equal(client.draft, false);
    assert.deepEqual(
      mutations(client).map((args) => args[1]),
      ["upload", "edit"],
    );
    const editIndex = client.calls.findIndex(
      (args) => args[0] === "release" && args[1] === "edit",
    );
    const finalDownloadIndex = client.calls.findLastIndex(
      (args) =>
        args[0] === "release" &&
        args[1] === "download" &&
        args[args.indexOf("--pattern") + 1] === basename(files.artifact),
    );
    assert.ok(finalDownloadIndex >= 0);
    assert.ok(editIndex > finalDownloadIndex);
    assert.equal(client.calls[editIndex].includes("--draft=false"), true);
    assert.equal(client.calls[editIndex].includes("--clobber"), false);
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});

test("verifies every Windows evidence asset while draft and publishes last", () => {
  const files = windowsFixture();
  try {
    const manifest = validateManifest(files.manifest);
    const client = new FakeClient(files.predicate, {
      tag: files.manifest.tag,
      draft: true,
    });
    assert.deepEqual(publishManifest(manifest, { client }), {
      uploaded: [files.manifest.bundles[0].assetName, basename(files.artifact)],
    });
    assert.deepEqual(
      mutations(client).map((args) => args[1]),
      ["upload", "upload", "edit"],
    );
    const editIndex = client.calls.findIndex(
      (args) => args[0] === "release" && args[1] === "edit",
    );
    const finalBundleVerificationIndex = client.calls.findLastIndex((args) => {
      if (args[0] !== "attestation" || args[1] !== "verify") return false;
      return args[args.indexOf("--bundle") + 1].includes("/final/");
    });
    assert.ok(finalBundleVerificationIndex >= 0);
    assert.ok(editIndex > finalBundleVerificationIndex);
    assert.equal(client.draft, false);
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});

test("keeps the Windows release draft when collision preflight fails", () => {
  const files = windowsFixture({ artifactOnly: true });
  try {
    const manifest = validateManifest(files.manifest);
    const client = new FakeClient(files.predicate, {
      tag: files.manifest.tag,
      draft: true,
    });
    client.assets.set(basename(files.artifact), Buffer.from("attacker-bytes"));
    assert.throws(
      () => publishManifest(manifest, { client }),
      /refusing to replace non-identical/u,
    );
    assert.equal(client.draft, true);
    assert.deepEqual(mutations(client), []);
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});

test("keeps the Windows release draft when final verification fails", () => {
  const files = windowsFixture({ artifactOnly: true });
  try {
    const manifest = validateManifest(files.manifest);
    const client = new FakeClient(files.predicate, {
      tag: files.manifest.tag,
      draft: true,
    });
    client.downloadHook = (name, contents) =>
      name === basename(files.artifact)
        ? Buffer.from("mutated-after-upload")
        : contents;
    assert.throws(
      () => publishManifest(manifest, { client }),
      /published artifact bytes differ/u,
    );
    assert.equal(client.draft, true);
    assert.deepEqual(
      mutations(client).map((args) => args[1]),
      ["upload"],
    );
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});

test("accepts only an exact concurrent Windows publication after publish-last", () => {
  const files = windowsFixture({ artifactOnly: true });
  try {
    const manifest = validateManifest(files.manifest);
    const client = new FakeClient(files.predicate, {
      tag: files.manifest.tag,
      draft: true,
    });
    client.editHook = (_args, instance) => {
      instance.draft = false;
      return { status: 1, stdout: "", stderr: "concurrent publication" };
    };
    assert.deepEqual(publishManifest(manifest, { client }), {
      uploaded: [basename(files.artifact)],
    });
    assert.equal(client.draft, false);
    assert.equal(mutations(client).at(-1)[1], "edit");

    const nonExact = new FakeClient(files.predicate, {
      tag: files.manifest.tag,
      draft: true,
    });
    nonExact.editHook = () => ({
      status: 1,
      stdout: "",
      stderr: "publication failed",
    });
    assert.throws(
      () => publishManifest(manifest, { client: nonExact }),
      /exact published stable release/u,
    );
    assert.equal(nonExact.draft, true);
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});

test("refuses to repair an incomplete already-published Windows release", () => {
  const files = windowsFixture({ artifactOnly: true });
  try {
    const manifest = validateManifest(files.manifest);
    const client = new FakeClient(files.predicate, {
      tag: files.manifest.tag,
      draft: false,
    });
    assert.throws(
      () => publishManifest(manifest, { client }),
      /published Windows release is incomplete/u,
    );
    assert.deepEqual(mutations(client), []);
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});

test("rejects inconsistent or non-native artifact-only controls", () => {
  const files = windowsFixture({ artifactOnly: true });
  try {
    assert.throws(
      () =>
        validateManifest({
          ...files.manifest,
          nativeArtifactOnly: false,
        }),
      /exactly when no attestation bundles exist/u,
    );
    assert.throws(
      () =>
        validateManifest({
          ...files.manifest,
          consumer: "console",
          tag: "v1.2.3",
          signerWorkflow:
            ".github/workflows/domain-core-console-release-evidence.yml",
          releaseState: "published",
        }),
      /native publication controls/u,
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

test("recovers after a bundle-only partial publication by reusing the semantically identical official bundle", () => {
  const files = fixture();
  try {
    const manifest = validateManifest(files.manifest);
    const client = new FakeClient(files.predicate);
    client.assets.set(
      files.manifest.bundles[0].assetName,
      Buffer.from("different-valid-attestation-encoding"),
    );
    assert.deepEqual(publishManifest(manifest, { client }), {
      uploaded: [basename(files.artifact)],
    });
    assert.deepEqual(
      uploads(client).map((args) => basename(args[3])),
      [basename(files.artifact)],
    );
    const officialBundleVerifications = client.calls.filter((args) => {
      if (args[0] !== "attestation" || args[1] !== "verify") return false;
      const bundlePath = args[args.indexOf("--bundle") + 1];
      return (
        bundlePath.includes("/preflight/") || bundlePath.includes("/final/")
      );
    });
    assert.equal(officialBundleVerifications.length, 2);
    for (const args of officialBundleVerifications) {
      assert.equal(args[args.indexOf("--repo") + 1], "Imagine-That-Ai/BurnBar");
      assert.equal(
        args[args.indexOf("--signer-workflow") + 1],
        "Imagine-That-Ai/BurnBar/.github/workflows/release.yml",
      );
      assert.equal(args[args.indexOf("--source-ref") + 1], "refs/tags/v1.2.3");
      assert.equal(
        args[args.indexOf("--source-digest") + 1],
        ACTIVATION_COMMIT,
      );
      assert.equal(
        args[args.indexOf("--signer-digest") + 1],
        ACTIVATION_COMMIT,
      );
      assert.equal(
        args[args.indexOf("--predicate-type") + 1],
        files.predicate.predicateType,
      );
      assert.equal(
        args[args.indexOf("--cert-oidc-issuer") + 1],
        "https://token.actions.githubusercontent.com",
      );
      assert.equal(args.includes("--deny-self-hosted-runners"), true);
    }
    const officialInputs = client.attestationInputs.filter(
      ({ bundlePath }) =>
        bundlePath.includes("/preflight/") || bundlePath.includes("/final/"),
    );
    assert.deepEqual(
      officialInputs.map(({ artifactSha256 }) => artifactSha256),
      [files.predicate.artifact.sha256, files.predicate.artifact.sha256],
    );
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});

test("rejects adversarial existing bundles before publication mutation", () => {
  const cases = [
    {
      name: "predicate substitution",
      result: (files) => ({
        status: 0,
        stdout: JSON.stringify([
          {
            verificationResult: {
              statement: {
                predicate: {
                  ...files.predicate,
                  artifact: {
                    ...files.predicate.artifact,
                    sha256: "9".repeat(64),
                  },
                },
              },
            },
          },
        ]),
        stderr: "",
      }),
      error: /does not contain its exact predicate/u,
    },
    {
      name: "wrong signer identity",
      result: () => {
        throw new Error("attestation signer workflow does not match");
      },
      error: /signer workflow does not match/u,
    },
    {
      name: "wrong artifact subject",
      result: () => {
        throw new Error("attestation subject digest does not match artifact");
      },
      error: /subject digest does not match artifact/u,
    },
  ];
  for (const scenario of cases) {
    const files = fixture();
    try {
      const manifest = validateManifest(files.manifest);
      const client = new FakeClient(files.predicate);
      client.assets.set(
        files.manifest.bundles[0].assetName,
        Buffer.from(`adversarial-${scenario.name}`),
      );
      client.attestationHook = (args) => {
        const bundlePath = args[args.indexOf("--bundle") + 1];
        if (!bundlePath.includes("/preflight/")) return undefined;
        return scenario.result(files);
      };
      assert.throws(
        () => publishManifest(manifest, { client }),
        scenario.error,
        scenario.name,
      );
      assert.equal(uploads(client).length, 0, scenario.name);
    } finally {
      rmSync(files.directory, { recursive: true, force: true });
    }
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

test("accepts a byte-different concurrent semantically identical attestation bundle", () => {
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
    assert.deepEqual(publishManifest(manifest, { client }), {
      uploaded: [basename(files.artifact)],
    });
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

test("accepts P after C and rejects an activation-commit substitution", () => {
  const files = fixture();
  try {
    assert.doesNotThrow(() => validateManifest(files.manifest));
    const predicate = {
      ...files.predicate,
      release: { ...files.predicate.release, commit: "7".repeat(40) },
    };
    writeFileSync(files.predicatePath, `${JSON.stringify(predicate)}\n`);
    const manifest = { ...files.manifest, commit: "7".repeat(40) };
    assert.throws(() => validateManifest(manifest), /activation commit/u);
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

test("detects semantic final attestation bundle mutation after successful uploads", () => {
  const files = fixture();
  try {
    const manifest = validateManifest(files.manifest);
    const client = new FakeClient(files.predicate);
    client.attestationHook = (args) => {
      const bundlePath = args[args.indexOf("--bundle") + 1];
      if (bundlePath.includes("/final/")) {
        throw new Error("attestation subject digest does not match artifact");
      }
      return undefined;
    };
    assert.throws(
      () => publishManifest(manifest, { client }),
      /subject digest does not match artifact/u,
    );
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});
