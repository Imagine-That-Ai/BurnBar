import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  chmodSync,
  copyFileSync,
  mkdtempSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import {
  canonicalSha256,
  sha256File,
} from "./create-domain-core-release-evidence.mjs";
import { validateManifest } from "./publish-domain-core-release-evidence.mjs";

const SCRIPT = join(
  dirname(fileURLToPath(import.meta.url)),
  "publish-domain-core-release-evidence.mjs",
);
const COMMIT = "a".repeat(40);

function writeJson(path, value) {
  writeFileSync(path, `${JSON.stringify(value, null, 2)}\n`);
}

function setup({ bundleCount = 2 } = {}) {
  const root = mkdtempSync(join(tmpdir(), "domain-core-publisher-test-"));
  const bin = join(root, "bin");
  const release = join(root, "release");
  mkdirSync(bin);
  mkdirSync(release);
  const log = join(root, "gh.log");
  const state = join(root, "gh.state");
  const artifact = join(root, "OpenBurnBar-1.2.3-macOS.dmg");
  writeFileSync(artifact, "signed artifact bytes\n");
  const artifactSha256 = sha256File(artifact);
  const domains = ["quota", "cloudVault"];
  const bundles = [];
  for (let index = 0; index < bundleCount; index += 1) {
    const domain = domains[index];
    const predicate = {
      schemaVersion: 1,
      consumer: "apple",
      artifactKind: "macos-dmg",
      target: "macos-arm64",
      artifact: {
        fileName: "OpenBurnBar-1.2.3-macOS.dmg",
        sha256: artifactSha256,
      },
      release: {
        version: "1.2.3",
        tag: "v1.2.3",
        commit: COMMIT,
        publicProfileSha256: canonicalSha256({
          artifactAuthority: "signed",
          distribution: "public",
          rolloutChannel: null,
          evidenceEnabled: false,
          domain,
          mode: "rust",
        }),
      },
    };
    const predicatePath = join(root, `predicate-${index}.json`);
    const bundlePath = join(root, `source-bundle-${index}.json`);
    writeJson(predicatePath, predicate);
    writeJson(bundlePath, { valid: true, predicate });
    bundles.push({
      domain,
      assetName: `OpenBurnBar-1.2.3-macOS-${domain}-domain-core-attestation.sigstore.json`,
      bundlePath,
      predicatePath,
    });
  }
  const manifest = join(root, "manifest.json");
  writeJson(manifest, {
    schemaVersion: 1,
    repository: "Imagine-That-Ai/BurnBar",
    tag: "v1.2.3",
    commit: COMMIT,
    consumer: "apple",
    signerWorkflow: ".github/workflows/release.yml",
    releaseAvailability: "published",
    artifactPath: artifact,
    bundles,
  });
  const gh = join(bin, "gh");
  writeFileSync(
    gh,
    `#!/usr/bin/env node
const fs = require("fs");
const path = require("path");
const args = process.argv.slice(2);
fs.appendFileSync(process.env.MOCK_GH_LOG, JSON.stringify(args) + "\\n");
const releaseDir = process.env.MOCK_RELEASE_DIR;
const valueAfter = (name) => args[args.indexOf(name) + 1];
if (args[0] === "attestation" && args[1] === "verify") {
  if (process.env.MOCK_VERIFY_MODE === "invalid-json") {
    process.stdout.write("not json");
    process.exit(0);
  }
  if (process.env.MOCK_VERIFY_MODE === "empty") {
    process.stdout.write("[]");
    process.exit(0);
  }
  const bundle = JSON.parse(fs.readFileSync(valueAfter("--bundle"), "utf8"));
  if (!bundle.valid) process.exit(1);
  if (process.env.MOCK_MUTATE_SOURCE) {
    const marker = process.env.MOCK_MUTATE_SOURCE + ".mutated";
    if (!fs.existsSync(marker)) {
      fs.writeFileSync(process.env.MOCK_MUTATE_SOURCE, "mutated upstream bytes\\n");
      fs.writeFileSync(marker, "1");
    }
  }
  const predicate = process.env.MOCK_VERIFY_MODE === "wrong-predicate"
    ? { wrong: true }
    : bundle.predicate;
  process.stdout.write(JSON.stringify([{ verificationResult: { statement: { predicate } } }]));
  process.exit(0);
}
if (args[0] === "api") {
  let count = 0;
  try { count = Number(fs.readFileSync(process.env.MOCK_GH_STATE, "utf8")); } catch {}
  fs.writeFileSync(process.env.MOCK_GH_STATE, String(count + 1));
  if (process.env.MOCK_RELEASE_MODE === "absent-then-ready" && count === 0) process.exit(1);
  const requestedTag = args[1].split("/").at(-1);
  process.stdout.write(JSON.stringify({
    tag_name: process.env.MOCK_RELEASE_MODE === "wrong-tag" ? "v9.9.9" : requestedTag,
    draft: process.env.MOCK_RELEASE_MODE === "draft",
    prerelease: process.env.MOCK_RELEASE_MODE === "prerelease",
  }));
  process.exit(0);
}
if (args[0] === "release" && args[1] === "view") {
  const assets = fs.readdirSync(releaseDir).sort().map((name) => ({ name }));
  process.stdout.write(JSON.stringify({ assets }));
  process.exit(0);
}
if (args[0] === "release" && args[1] === "download") {
  const name = valueAfter("--pattern");
  const source = path.join(releaseDir, name);
  if (!fs.existsSync(source)) process.exit(1);
  const directory = valueAfter("--dir");
  fs.mkdirSync(directory, { recursive: true });
  fs.copyFileSync(source, path.join(directory, name));
  process.exit(0);
}
if (args[0] === "release" && args[1] === "upload") {
  const source = args[3];
  const name = path.basename(source);
  const destination = path.join(releaseDir, name);
  if (process.env.MOCK_COLLIDE_ASSET === name) {
    fs.copyFileSync(process.env.MOCK_COLLIDE_SOURCE, destination);
    process.exit(1);
  }
  if (fs.existsSync(destination)) process.exit(1);
  fs.copyFileSync(source, destination);
  process.exit(0);
}
process.stderr.write("unsupported fake gh command: " + JSON.stringify(args));
process.exit(2);
`,
  );
  chmodSync(gh, 0o755);
  return {
    root,
    release,
    log,
    state,
    artifact,
    bundles,
    manifest,
    env: {
      ...process.env,
      PATH: `${bin}:${process.env.PATH}`,
      MOCK_GH_LOG: log,
      MOCK_GH_STATE: state,
      MOCK_RELEASE_DIR: release,
    },
    cleanup() {
      rmSync(root, { recursive: true, force: true });
    },
  };
}

function runHelper(fixture, extraEnv = {}, extraArgs = []) {
  return spawnSync(
    process.execPath,
    [
      SCRIPT,
      "--manifest",
      fixture.manifest,
      "--release-timeout-seconds",
      "0",
      "--poll-seconds",
      "0",
      ...extraArgs,
    ],
    {
      encoding: "utf8",
      env: { ...fixture.env, ...extraEnv },
    },
  );
}

function commands(fixture) {
  if (!readFileSync(fixture.log, "utf8").trim()) return [];
  return readFileSync(fixture.log, "utf8")
    .trim()
    .split("\n")
    .map((line) => JSON.parse(line));
}

function copyPublishedFixture(fixture) {
  copyFileSync(
    fixture.artifact,
    join(fixture.release, basename(fixture.artifact)),
  );
  for (const bundle of fixture.bundles) {
    copyFileSync(bundle.bundlePath, join(fixture.release, bundle.assetName));
  }
}

test("new publication uploads every verified bundle before the artifact", () => {
  const fixture = setup();
  try {
    const result = runHelper(fixture);
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(readdirSync(fixture.release).sort(), [
      "OpenBurnBar-1.2.3-macOS-cloudVault-domain-core-attestation.sigstore.json",
      "OpenBurnBar-1.2.3-macOS-quota-domain-core-attestation.sigstore.json",
      "OpenBurnBar-1.2.3-macOS.dmg",
    ]);
    const all = commands(fixture);
    const uploads = all
      .filter((args) => args[0] === "release" && args[1] === "upload")
      .map((args) => basename(args[3]));
    assert.deepEqual(uploads, [
      "OpenBurnBar-1.2.3-macOS-quota-domain-core-attestation.sigstore.json",
      "OpenBurnBar-1.2.3-macOS-cloudVault-domain-core-attestation.sigstore.json",
      "OpenBurnBar-1.2.3-macOS.dmg",
    ]);
    assert.equal(
      all.some((args) => args.includes("--clobber")),
      false,
    );
    assert.equal(
      all.some((args) => args[0] === "release" && args[1] === "create"),
      false,
    );
    assert.equal(
      all.some((args) => args[0] === "release" && args[1] === "edit"),
      false,
    );
    const verify = all.find((args) => args[0] === "attestation");
    assert.equal(valueAfterForTest(verify, "--source-ref"), "refs/tags/v1.2.3");
    assert.equal(valueAfterForTest(verify, "--source-digest"), COMMIT);
    assert.equal(valueAfterForTest(verify, "--signer-digest"), COMMIT);
  } finally {
    fixture.cleanup();
  }
});

function valueAfterForTest(args, name) {
  return args[args.indexOf(name) + 1];
}

test("an identical rerun verifies existing assets without uploading", () => {
  const fixture = setup();
  try {
    copyPublishedFixture(fixture);
    const result = runHelper(fixture);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(
      commands(fixture).some(
        (args) => args[0] === "release" && args[1] === "upload",
      ),
      false,
    );
  } finally {
    fixture.cleanup();
  }
});

test("publication waits for an initially absent release", () => {
  const fixture = setup({ bundleCount: 1 });
  try {
    const result = runHelper(
      fixture,
      { MOCK_RELEASE_MODE: "absent-then-ready" },
      ["--release-timeout-seconds", "2"],
    );
    assert.equal(result.status, 0, result.stderr);
    const lookups = commands(fixture).filter((args) => args[0] === "api");
    assert.equal(lookups.length, 2);
  } finally {
    fixture.cleanup();
  }
});

test("partial publication verifies existing assets before adding missing assets", () => {
  const fixture = setup();
  try {
    copyFileSync(
      fixture.bundles[0].bundlePath,
      join(fixture.release, fixture.bundles[0].assetName),
    );
    const result = runHelper(fixture);
    assert.equal(result.status, 0, result.stderr);
    const uploads = commands(fixture)
      .filter((args) => args[0] === "release" && args[1] === "upload")
      .map((args) => basename(args[3]));
    assert.deepEqual(uploads, [
      fixture.bundles[1].assetName,
      basename(fixture.artifact),
    ]);
  } finally {
    fixture.cleanup();
  }
});

test("publication uses one staged artifact snapshot for verification and upload", () => {
  const fixture = setup({ bundleCount: 1 });
  try {
    const original = readFileSync(fixture.artifact, "utf8");
    const result = runHelper(fixture, { MOCK_MUTATE_SOURCE: fixture.artifact });
    assert.equal(result.status, 0, result.stderr);
    assert.notEqual(readFileSync(fixture.artifact, "utf8"), original);
    assert.equal(
      readFileSync(join(fixture.release, basename(fixture.artifact)), "utf8"),
      original,
    );
  } finally {
    fixture.cleanup();
  }
});

test("preexisting mismatched artifact fails before any upload", () => {
  const fixture = setup();
  try {
    writeFileSync(
      join(fixture.release, basename(fixture.artifact)),
      "different\n",
    );
    const result = runHelper(fixture);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /refusing to replace non-identical/);
    assert.equal(
      commands(fixture).some(
        (args) => args[0] === "release" && args[1] === "upload",
      ),
      false,
    );
  } finally {
    fixture.cleanup();
  }
});

test("preexisting invalid bundle fails before any upload", () => {
  const fixture = setup();
  try {
    copyFileSync(
      fixture.artifact,
      join(fixture.release, basename(fixture.artifact)),
    );
    writeJson(join(fixture.release, fixture.bundles[0].assetName), {
      valid: false,
      predicate: { wrong: true },
    });
    const result = runHelper(fixture);
    assert.equal(result.status, 1);
    assert.equal(
      commands(fixture).some(
        (args) => args[0] === "release" && args[1] === "upload",
      ),
      false,
    );
  } finally {
    fixture.cleanup();
  }
});

test("matching bundle upload collision is verified and publication continues", () => {
  const fixture = setup({ bundleCount: 1 });
  try {
    const bundle = fixture.bundles[0];
    const result = runHelper(fixture, {
      MOCK_COLLIDE_ASSET: bundle.assetName,
      MOCK_COLLIDE_SOURCE: bundle.bundlePath,
    });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(
      readFileSync(join(fixture.release, bundle.assetName), "utf8"),
      readFileSync(bundle.bundlePath, "utf8"),
    );
  } finally {
    fixture.cleanup();
  }
});

test("different artifact upload collision fails closed", () => {
  const fixture = setup({ bundleCount: 1 });
  try {
    const collision = join(fixture.root, "collision-artifact");
    writeFileSync(collision, "different concurrent bytes\n");
    const result = runHelper(fixture, {
      MOCK_COLLIDE_ASSET: basename(fixture.artifact),
      MOCK_COLLIDE_SOURCE: collision,
    });
    assert.equal(result.status, 1);
    assert.match(
      result.stderr,
      /concurrent immutable release artifact differs/,
    );
  } finally {
    fixture.cleanup();
  }
});

test("wrong predicate and empty verification results fail before mutation", () => {
  for (const mode of ["wrong-predicate", "empty", "invalid-json"]) {
    const fixture = setup({ bundleCount: 1 });
    try {
      const result = runHelper(fixture, { MOCK_VERIFY_MODE: mode });
      assert.equal(result.status, 1, `${mode}: ${result.stderr}`);
      assert.equal(readdirSync(fixture.release).length, 0);
    } finally {
      fixture.cleanup();
    }
  }
});

test("release lifecycle rejects draft, prerelease, and wrong-tag releases", () => {
  for (const mode of ["draft", "prerelease", "wrong-tag"]) {
    const fixture = setup({ bundleCount: 1 });
    try {
      const result = runHelper(fixture, { MOCK_RELEASE_MODE: mode });
      assert.equal(result.status, 1, `${mode}: ${result.stderr}`);
      assert.equal(readdirSync(fixture.release).length, 0);
    } finally {
      fixture.cleanup();
    }
  }
});

test("native publication may populate its exact draft release", () => {
  const fixture = setup({ bundleCount: 1 });
  try {
    const manifest = JSON.parse(readFileSync(fixture.manifest, "utf8"));
    writeJson(fixture.manifest, {
      ...manifest,
      releaseAvailability: "draft-or-published",
    });
    const result = runHelper(fixture, { MOCK_RELEASE_MODE: "draft" });
    assert.equal(result.status, 0, result.stderr);
  } finally {
    fixture.cleanup();
  }
});

test("manifest validation rejects unsafe identity and asset substitution", () => {
  const fixture = setup({ bundleCount: 1 });
  try {
    const raw = JSON.parse(readFileSync(fixture.manifest, "utf8"));
    assert.throws(
      () => validateManifest({ ...raw, repository: "example/other" }),
      /repository/,
    );
    assert.throws(
      () => validateManifest({ ...raw, tag: "v1.2.3-beta.1" }),
      /stable release tag/,
    );
    assert.throws(
      () =>
        validateManifest({
          ...raw,
          signerWorkflow: ".github/workflows/untrusted.yml",
        }),
      /allowlisted/,
    );
    assert.throws(
      () =>
        validateManifest({
          ...raw,
          tag: "windows-v1.2.3",
        }),
      /tag train/,
    );
    assert.throws(
      () => validateManifest({ ...raw, consumer: "functions" }),
      /consumer does not match/,
    );
    assert.throws(
      () =>
        validateManifest({
          ...raw,
          releaseAvailability: "unsafe",
        }),
      /releaseAvailability/,
    );
    assert.throws(
      () =>
        validateManifest({
          ...raw,
          bundles: [
            {
              ...raw.bundles[0],
              domain: "cloudVault",
              assetName:
                "OpenBurnBar-1.2.3-macOS-cloudVault-domain-core-attestation.sigstore.json",
            },
          ],
        }),
      /predicate does not bind/,
    );
    assert.throws(
      () =>
        validateManifest({
          ...raw,
          bundles: [{ ...raw.bundles[0], assetName: "../escape.json" }],
        }),
      /safe release asset basename/,
    );
    assert.throws(
      () =>
        validateManifest({
          ...raw,
          bundles: [raw.bundles[0], { ...raw.bundles[0] }],
        }),
      /duplicate release asset name/,
    );
    assert.throws(
      () =>
        validateManifest({
          ...raw,
          bundles: [
            raw.bundles[0],
            {
              ...raw.bundles[0],
              assetName: "OpenBurnBar-1.2.3-second-quota.sigstore.json",
            },
          ],
        }),
      /duplicate apple domain/,
    );
  } finally {
    fixture.cleanup();
  }
});
