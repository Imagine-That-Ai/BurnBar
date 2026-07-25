import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import {
  materializeLinuxLifecycleReleaseAssets,
  parseArguments,
} from "./materialize-linux-lifecycle-release-assets.mjs";

const VERSION = "1.2.3";
const HEAD = "a".repeat(40);

function hash(bytes) {
  return crypto.createHash("sha256").update(bytes).digest("hex");
}

function fixture(t) {
  const root = fs.realpathSync(
    fs.mkdtempSync(path.join(os.tmpdir(), "obb-lifecycle-assets-")),
  );
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const release = path.join(root, ".linux-release");
  const artifacts = path.join(release, "artifacts");
  const attestations = path.join(release, "installed-manifests");
  fs.mkdirSync(artifacts, { recursive: true });
  fs.mkdirSync(attestations, { recursive: true });
  const rows = [];
  for (const format of ["arch", "deb", "rpm"]) {
    for (const architecture of ["aarch64", "x86_64"]) {
      const packageBytes = Buffer.from(`${format}:${architecture}:package`);
      const manifestBytes = Buffer.from(
        `${JSON.stringify({
          packageFormat: format,
          packageArchitecture: architecture,
          packageVersion: VERSION,
          gitCommit: HEAD,
        })}\n`,
      );
      const signatureBytes = Buffer.alloc(64, rows.length + 1);
      const packageRelative = `.linux-release/artifacts/${format}-${architecture}.pkg`;
      const manifestRelative = `.linux-release/installed-manifests/${format}-${architecture}.json`;
      const signatureRelative = `${manifestRelative}.sig`;
      fs.writeFileSync(path.join(root, packageRelative), packageBytes);
      fs.writeFileSync(path.join(root, manifestRelative), manifestBytes);
      fs.writeFileSync(path.join(root, signatureRelative), signatureBytes);
      rows.push({
        type: format,
        architecture,
        file: packageRelative,
        sha256: hash(packageBytes),
        size: packageBytes.length,
        installedManifest: {
          file: manifestRelative,
          sha256: hash(manifestBytes),
          size: manifestBytes.length,
        },
        installedManifestSignature: {
          file: signatureRelative,
          sha256: hash(signatureBytes),
          size: signatureBytes.length,
        },
      });
    }
  }
  fs.writeFileSync(
    path.join(release, "package-closure.json"),
    `${JSON.stringify({
      schemaVersion: 3,
      stage: "candidate",
      version: VERSION,
      git: { commit: HEAD },
      artifacts: rows,
    })}\n`,
  );
  return { root, release, rows };
}

test("materializes exact format and architecture lifecycle sidecars", (t) => {
  const value = fixture(t);
  const result = materializeLinuxLifecycleReleaseAssets({
    candidateRoot: value.root,
    outputRoot: value.release,
  });
  assert.equal(result.report.assets.length, 6);
  for (const format of ["arch", "deb", "rpm"]) {
    for (const architecture of ["aarch64", "x86_64"]) {
      const prefix = `openburnbar-${VERSION}-${format}-${architecture}.installed-manifest`;
      assert.equal(fs.statSync(path.join(value.release, `${prefix}.json`)).mode & 0o777, 0o644);
      assert.equal(fs.statSync(path.join(value.release, `${prefix}.ed25519`)).size, 64);
    }
  }
  assert.equal(
    JSON.parse(
      fs.readFileSync(
        path.join(value.release, "linux-lifecycle-release-assets.json"),
      ),
    ).targetHead,
    HEAD,
  );
  const repeated = materializeLinuxLifecycleReleaseAssets({
    candidateRoot: value.root,
    outputRoot: value.release,
  });
  assert.deepEqual(repeated.report, result.report);
});

for (const [name, mutate, pattern] of [
  [
    "missing package row",
    (value) => {
      const closurePath = path.join(value.release, "package-closure.json");
      const closure = JSON.parse(fs.readFileSync(closurePath));
      closure.artifacts.pop();
      fs.writeFileSync(closurePath, `${JSON.stringify(closure)}\n`);
    },
    /exact native package matrix/u,
  ],
  [
    "manifest format substitution",
    (value) => {
      const row = value.rows[0];
      const file = path.join(value.root, row.installedManifest.file);
      const document = JSON.parse(fs.readFileSync(file));
      document.packageFormat = "deb";
      const bytes = Buffer.from(`${JSON.stringify(document)}\n`);
      fs.writeFileSync(file, bytes);
      const closurePath = path.join(value.release, "package-closure.json");
      const closure = JSON.parse(fs.readFileSync(closurePath));
      closure.artifacts[0].installedManifest.sha256 = hash(bytes);
      closure.artifacts[0].installedManifest.size = bytes.length;
      fs.writeFileSync(closurePath, `${JSON.stringify(closure)}\n`);
    },
    /manifest identity is invalid/u,
  ],
  [
    "signature truncation",
    (value) => {
      const row = value.rows[0];
      const file = path.join(value.root, row.installedManifestSignature.file);
      const bytes = Buffer.alloc(63);
      fs.writeFileSync(file, bytes);
      const closurePath = path.join(value.release, "package-closure.json");
      const closure = JSON.parse(fs.readFileSync(closurePath));
      closure.artifacts[0].installedManifestSignature.sha256 = hash(bytes);
      closure.artifacts[0].installedManifestSignature.size = bytes.length;
      fs.writeFileSync(closurePath, `${JSON.stringify(closure)}\n`);
    },
    /must be 64 bytes/u,
  ],
]) {
  test(`rejects ${name}`, (t) => {
    const value = fixture(t);
    mutate(value);
    assert.throws(
      () =>
        materializeLinuxLifecycleReleaseAssets({
          candidateRoot: value.root,
          outputRoot: value.release,
        }),
      pattern,
    );
  });
}

test("rejects output paths outside the candidate release root", (t) => {
  const value = fixture(t);
  assert.throws(
    () =>
      materializeLinuxLifecycleReleaseAssets({
        candidateRoot: value.root,
        outputRoot: value.root,
      }),
    /output root must be/u,
  );
  assert.throws(
    () => parseArguments(["--candidate-root", value.root]),
    /--output-root is required/u,
  );
});
