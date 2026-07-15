import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  buildAppleAndroidPublication,
  run,
} from "./create-apple-android-release-publication.mjs";

const COMMIT = "a".repeat(40);

function fixture({ version = "1.2.3" } = {}) {
  const directory = mkdtempSync(join(tmpdir(), "apple-android-manifest-"));
  const tag = `v${version}`;
  const appleArtifact = join(directory, `OpenBurnBar-${version}-macOS.dmg`);
  const androidArtifact = join(directory, `OpenBurnBar-${version}-Android.aab`);
  const notes = join(directory, "release-notes.md");
  const checksum = join(directory, "SHA256SUMS");
  const output = join(directory, "publication.json");
  for (const [path, contents] of [
    [appleArtifact, "apple"],
    [androidArtifact, "android"],
    [notes, "release notes\n"],
    [checksum, "checksums\n"],
  ]) {
    writeFileSync(path, contents);
  }
  const manifest = (consumer, artifactPath) => ({
    schemaVersion: 2,
    repository: "Imagine-That-Ai/BurnBar",
    tag,
    commit: COMMIT,
    consumer,
    signerWorkflow: ".github/workflows/release.yml",
    releaseState: "draft-then-publish",
    nativeArtifactOnly: true,
    artifactPath,
    bundles: [],
  });
  const apple = manifest("apple", appleArtifact);
  const android = manifest("android", androidArtifact);
  const applePath = join(directory, "apple.json");
  const androidPath = join(directory, "android.json");
  writeFileSync(applePath, JSON.stringify(apple));
  writeFileSync(androidPath, JSON.stringify(android));
  return {
    directory,
    version,
    tag,
    apple,
    android,
    applePath,
    androidPath,
    notes,
    checksum,
    output,
  };
}

function argumentsFor(files, { promote = "false" } = {}) {
  return [
    "--apple",
    files.applePath,
    "--android",
    files.androidPath,
    "--notes",
    files.notes,
    "--tag",
    files.tag,
    "--commit",
    COMMIT,
    "--promote",
    promote,
    "--asset",
    files.checksum,
    "--output",
    files.output,
  ];
}

test("creates an immutable combined manifest containing only general assets", () => {
  const files = fixture();
  try {
    const publication = run(argumentsFor(files));
    assert.deepEqual(
      publication.assets.map((asset) => asset.name),
      [
        `OpenBurnBar-${files.version}-macOS.dmg`,
        `OpenBurnBar-${files.version}-Android.aab`,
        "SHA256SUMS",
      ],
    );
    const serialized = JSON.parse(readFileSync(files.output, "utf8"));
    assert.deepEqual(serialized.assets, [{ path: files.checksum }]);
    assert.equal(serialized.apple.nativeArtifactOnly, true);
    assert.equal(serialized.android.nativeArtifactOnly, true);
    run(argumentsFor(files));
    writeFileSync(files.output, "{}\n");
    assert.throws(
      () => run(argumentsFor(files)),
      /refusing to replace non-identical publication manifest/u,
    );
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});

test("accepts prereleases but prevents prerelease promotion", () => {
  const files = fixture({ version: "1.2.3-rc.1" });
  try {
    const publication = buildAppleAndroidPublication({
      apple: files.apple,
      android: files.android,
      notesPath: files.notes,
      tag: files.tag,
      commit: COMMIT,
      promote: false,
      assets: [files.checksum],
    });
    assert.equal(publication.prerelease, true);
    assert.throws(
      () => run(argumentsFor(files, { promote: "true" })),
      /prerelease cannot become latest/u,
    );
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});

test("rejects general assets that collide with native artifacts", () => {
  const files = fixture();
  try {
    assert.throws(
      () =>
        buildAppleAndroidPublication({
          apple: files.apple,
          android: files.android,
          notesPath: files.notes,
          tag: files.tag,
          commit: COMMIT,
          promote: false,
          assets: [files.apple.artifactPath],
        }),
      /globally unique/u,
    );
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});
