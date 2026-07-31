#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  NATIVE_PACKAGE_TYPES,
  RELEASE_ARCHITECTURES,
  readRegularSnapshot,
  validateRecord,
} from "./lib/product-proof-closure.mjs";

const SEMVER = /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/u;

function requiredString(value, label) {
  if (
    typeof value !== "string" ||
    value.length === 0 ||
    value.trim() !== value
  ) {
    throw new Error(`${label} must be a nonempty canonical string`);
  }
  return value;
}

function parseJson(snapshot, label) {
  try {
    return JSON.parse(snapshot.bytes.toString("utf8"));
  } catch (error) {
    throw new Error(`${label} is not valid JSON: ${error.message}`);
  }
}

function canonicalDirectory(value, label) {
  requiredString(value, label);
  if (!path.isAbsolute(value) || path.normalize(value) !== value) {
    throw new Error(`${label} must be a canonical absolute path`);
  }
  const metadata = fs.lstatSync(value);
  if (!metadata.isDirectory() || metadata.isSymbolicLink()) {
    throw new Error(`${label} must be a non-symlink directory`);
  }
  if (fs.realpathSync(value) !== value) {
    throw new Error(`${label} must not traverse symlinks`);
  }
  return value;
}

function outputName(version, format, architecture, signature = false) {
  return `openburnbar-${version}-${format}-${architecture}.installed-manifest.${
    signature ? "ed25519" : "json"
  }`;
}

function writeExactOutput(outputRoot, name, bytes) {
  const destination = path.join(outputRoot, name);
  if (fs.existsSync(destination)) {
    const observed = readRegularSnapshot(outputRoot, name, `existing ${name}`);
    if (!observed.bytes.equals(bytes)) {
      throw new Error(`existing lifecycle asset drifted: ${name}`);
    }
    return observed;
  }
  const temporary = path.join(
    outputRoot,
    `.${name}.${process.pid}.${Date.now()}.tmp`,
  );
  fs.writeFileSync(temporary, bytes, { mode: 0o600, flag: "wx" });
  fs.renameSync(temporary, destination);
  fs.chmodSync(destination, 0o644);
  return readRegularSnapshot(outputRoot, name, `materialized ${name}`);
}

export function materializeLinuxLifecycleReleaseAssets({
  candidateRoot,
  outputRoot,
}) {
  const root = canonicalDirectory(candidateRoot, "candidate root");
  const expectedOutput = path.join(root, ".linux-release");
  const output = canonicalDirectory(outputRoot, "output root");
  if (output !== expectedOutput) {
    throw new Error("output root must be the candidate .linux-release directory");
  }
  const closureSnapshot = readRegularSnapshot(
    root,
    ".linux-release/package-closure.json",
    "package closure",
  );
  const closure = parseJson(closureSnapshot, "package closure");
  if (
    closure?.schemaVersion !== 3 ||
    closure?.stage !== "candidate" ||
    !SEMVER.test(closure?.version ?? "")
  ) {
    throw new Error(
      "package closure must be a versioned schema-3 candidate closure",
    );
  }
  const expected = new Set(
    NATIVE_PACKAGE_TYPES.flatMap((format) =>
      RELEASE_ARCHITECTURES.map(
        (architecture) => `${format}:${architecture}`,
      ),
    ),
  );
  const rows = [];
  for (const artifact of closure.artifacts ?? []) {
    const key = `${artifact?.type}:${artifact?.architecture}`;
    if (!expected.has(key)) continue;
    if (rows.some((row) => row.key === key)) {
      throw new Error(`duplicate native lifecycle artifact: ${key}`);
    }
    const artifactSnapshot = validateRecord(
      root,
      artifact,
      `${key} package`,
    );
    const manifest = validateRecord(
      root,
      artifact.installedManifest,
      `${key} installed manifest`,
    );
    const signature = validateRecord(
      root,
      artifact.installedManifestSignature,
      `${key} installed manifest signature`,
    );
    const document = parseJson(manifest, `${key} installed manifest`);
    if (
      document.packageFormat !== artifact.type ||
      document.packageArchitecture !== artifact.architecture ||
      document.packageVersion !== closure.version ||
      document.gitCommit !== closure.git?.commit
    ) {
      throw new Error(`${key} installed manifest identity is invalid`);
    }
    if (signature.size !== 64) {
      throw new Error(`${key} installed manifest signature must be 64 bytes`);
    }
    rows.push({
      key,
      format: artifact.type,
      architecture: artifact.architecture,
      package: artifactSnapshot,
      manifest,
      signature,
    });
  }
  const observed = new Set(rows.map((row) => row.key));
  if (
    observed.size !== expected.size ||
    [...expected].some((key) => !observed.has(key))
  ) {
    throw new Error(
      "package closure does not contain the exact native package matrix",
    );
  }
  const assets = [];
  for (const row of rows.sort((left, right) => left.key.localeCompare(right.key))) {
    const manifest = writeExactOutput(
      output,
      outputName(closure.version, row.format, row.architecture),
      row.manifest.bytes,
    );
    const signature = writeExactOutput(
      output,
      outputName(closure.version, row.format, row.architecture, true),
      row.signature.bytes,
    );
    assets.push({
      format: row.format,
      architecture: row.architecture,
      package: {
        path: row.package.path,
        sha256: row.package.sha256,
        size: row.package.size,
      },
      installedManifest: {
        path: manifest.path,
        sha256: manifest.sha256,
        size: manifest.size,
      },
      installedManifestSignature: {
        path: signature.path,
        sha256: signature.sha256,
        size: signature.size,
      },
    });
  }
  const report = {
    schemaVersion: 1,
    id: "openburnbar-linux-lifecycle-release-assets-v1",
    version: closure.version,
    targetHead: closure.git.commit,
    packageClosureSha256: closureSnapshot.sha256,
    assets,
  };
  const reportBytes = Buffer.from(`${JSON.stringify(report, null, 2)}\n`);
  const reportSnapshot = writeExactOutput(
    output,
    "linux-lifecycle-release-assets.json",
    reportBytes,
  );
  return {
    report,
    reportPath: reportSnapshot.absolute,
  };
}

export function parseArguments(argv) {
  const values = new Map();
  const allowed = new Set(["--candidate-root", "--output-root"]);
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (!allowed.has(flag) || value === undefined || values.has(flag)) {
      throw new Error(`invalid argument: ${flag ?? "<missing>"}`);
    }
    values.set(flag, value);
  }
  for (const flag of allowed) {
    if (!values.has(flag)) throw new Error(`${flag} is required`);
  }
  return {
    candidateRoot: values.get("--candidate-root"),
    outputRoot: values.get("--output-root"),
  };
}

if (
  process.argv[1] &&
  path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)
) {
  try {
    const result = materializeLinuxLifecycleReleaseAssets(
      parseArguments(process.argv.slice(2)),
    );
    process.stdout.write(
      `${JSON.stringify(
        {
          passed: true,
          reportPath: result.reportPath,
          assetCount: result.report.assets.length,
        },
        null,
        2,
      )}\n`,
    );
  } catch (error) {
    process.stderr.write(
      `Linux lifecycle asset materialization failed: ${error.message}\n`,
    );
    process.exitCode = 1;
  }
}
