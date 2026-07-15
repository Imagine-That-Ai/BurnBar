#!/usr/bin/env node

import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { lstatSync, readFileSync, writeFileSync } from "node:fs";
import { basename, dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const LIBRARY = "libopenburnbar_domain_ffi.so";
export const ANDROID_RELEASE_ABIS = Object.freeze(["arm64-v8a", "x86_64"]);
const SHA256 = /^[0-9a-f]{64}$/u;
const SAFE_ENTRY =
  /^(?!\/)(?!.*(?:^|\/)\.\.?\/?)(?!.*\/\/)[0-9A-Za-z._+-]+(?:\/[0-9A-Za-z._+-]+)*$/u;

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

function regularFile(path, label) {
  const absolute = resolve(path);
  const stat = lstatSync(absolute);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size === 0) {
    throw new Error(`${label} must be a nonempty regular non-symlink file`);
  }
  return absolute;
}

function command(executable, args, encoding = "utf8") {
  const result = spawnSync(executable, args, {
    encoding,
    maxBuffer: 256 * 1024 * 1024,
  });
  if (result.status !== 0) {
    throw new Error(
      `${executable} failed: ${String(result.stderr || result.stdout).trim()}`,
    );
  }
  return result.stdout;
}

function archiveEntries(path) {
  const listing = command("unzip", ["-Z1", path]);
  if (listing.includes("\0")) throw new Error("archive listing contains NUL");
  return listing.split(/\r?\n/u).filter((entry) => entry.length > 0);
}

function archiveBytes(path, entry) {
  return command("unzip", ["-p", path, entry], null);
}

function domainCoreEntries(entries, label) {
  const matches = entries.filter(
    (entry) => entry === LIBRARY || entry.endsWith(`/${LIBRARY}`),
  );
  for (const entry of matches) {
    if (!SAFE_ENTRY.test(entry) || entry.includes("\\")) {
      throw new Error(
        `${label} contains unsafe domain-core library path: ${entry}`,
      );
    }
  }
  const seen = new Set();
  for (const entry of matches) {
    if (seen.has(entry)) {
      throw new Error(`${label} duplicates domain-core library path: ${entry}`);
    }
    seen.add(entry);
  }
  return matches;
}

function exactAabPaths(entries) {
  const actual = domainCoreEntries(entries, "Android AAB");
  const expected = ANDROID_RELEASE_ABIS.map(
    (abi) => `base/lib/${abi}/${LIBRARY}`,
  );
  for (const path of expected) {
    if (!actual.includes(path)) {
      throw new Error(
        `Android AAB is missing required domain-core ABI path: ${path}`,
      );
    }
  }
  for (const path of actual) {
    if (!expected.includes(path)) {
      throw new Error(
        `Android AAB contains unexpected domain-core ABI path: ${path}`,
      );
    }
  }
  return expected;
}

function exactAarPaths(entries) {
  const actual = domainCoreEntries(entries, "candidate Android AAR");
  return ANDROID_RELEASE_ABIS.map((abi) => {
    const path = `jni/${abi}/${LIBRARY}`;
    if (!actual.includes(path)) {
      throw new Error(
        `candidate Android AAR is missing required ABI path: ${path}`,
      );
    }
    return path;
  });
}

function candidateAarDigest(bundle) {
  const artifacts = bundle?.artifacts;
  if (!Array.isArray(artifacts)) {
    throw new Error("protected candidate bundle omits artifact evidence");
  }
  const matches = artifacts.filter((artifact) => artifact?.id === "kotlin-aar");
  if (matches.length !== 1) {
    throw new Error(
      "protected candidate bundle must contain exactly one kotlin-aar artifact",
    );
  }
  const artifact = matches[0];
  if (
    artifact.consumer !== "kotlin" ||
    artifact.jobId !== "android" ||
    !SHA256.test(artifact.artifactSha256)
  ) {
    throw new Error("protected kotlin-aar artifact evidence is invalid");
  }
  return artifact.artifactSha256;
}

export function buildAndroidUniversalManifest({
  aabEntries,
  aarEntries,
  readAabEntry,
  readAarEntry,
  aarSha256,
  protectedAarSha256,
}) {
  if (!SHA256.test(aarSha256) || aarSha256 !== protectedAarSha256) {
    throw new Error(
      "candidate Android AAR does not match protected kotlin-aar evidence",
    );
  }
  const aabPaths = exactAabPaths(aabEntries);
  const aarPaths = exactAarPaths(aarEntries);
  const abis = ANDROID_RELEASE_ABIS.map((abi, index) => {
    const aabBytes = readAabEntry(aabPaths[index]);
    const aarBytes = readAarEntry(aarPaths[index]);
    if (!Buffer.isBuffer(aabBytes) || aabBytes.length === 0) {
      throw new Error(`Android AAB ${abi} domain-core library is empty`);
    }
    if (!Buffer.isBuffer(aarBytes) || aarBytes.length === 0) {
      throw new Error(
        `candidate Android AAR ${abi} domain-core library is empty`,
      );
    }
    if (!aabBytes.equals(aarBytes)) {
      throw new Error(
        `Android AAB ${abi} domain-core library differs from the protected candidate AAR`,
      );
    }
    return Object.freeze({
      abi,
      path: aabPaths[index],
      sha256: sha256(aabBytes),
    });
  });
  return Object.freeze({
    schemaVersion: 1,
    target: "android-universal",
    library: LIBRARY,
    candidateAar: Object.freeze({
      fileName: "openburnbar-domain-core.aar",
      sha256: aarSha256,
    }),
    abis: Object.freeze(abis),
  });
}

export function validateAndroidUniversalManifest(value) {
  const expectedRoot = [
    "schemaVersion",
    "target",
    "library",
    "candidateAar",
    "abis",
  ];
  if (
    !value ||
    typeof value !== "object" ||
    Array.isArray(value) ||
    Object.keys(value).sort().join("\0") !== expectedRoot.sort().join("\0") ||
    value.schemaVersion !== 1 ||
    value.target !== "android-universal" ||
    value.library !== LIBRARY
  ) {
    throw new Error(
      "Android universal ABI manifest has an invalid root contract",
    );
  }
  if (
    !value.candidateAar ||
    Object.keys(value.candidateAar).sort().join("\0") !== "fileName\0sha256" ||
    value.candidateAar.fileName !== "openburnbar-domain-core.aar" ||
    !SHA256.test(value.candidateAar.sha256)
  ) {
    throw new Error(
      "Android universal ABI manifest has invalid candidate AAR identity",
    );
  }
  if (
    !Array.isArray(value.abis) ||
    value.abis.length !== ANDROID_RELEASE_ABIS.length
  ) {
    throw new Error("Android universal ABI manifest has an invalid ABI count");
  }
  for (const [index, abi] of ANDROID_RELEASE_ABIS.entries()) {
    const entry = value.abis[index];
    const expectedPath = `base/lib/${abi}/${LIBRARY}`;
    if (
      !entry ||
      Object.keys(entry).sort().join("\0") !== "abi\0path\0sha256" ||
      entry.abi !== abi ||
      entry.path !== expectedPath ||
      !SHA256.test(entry.sha256)
    ) {
      throw new Error(
        `Android universal ABI manifest has invalid ${abi} identity`,
      );
    }
  }
  return structuredClone(value);
}

export function run(argv) {
  const values = new Map();
  const required = new Set([
    "--aab",
    "--candidate-aar",
    "--candidate-bundle",
    "--output",
  ]);
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (!required.has(flag))
      throw new Error(`unknown argument: ${String(flag)}`);
    if (!value || value.startsWith("--"))
      throw new Error(`${flag} requires a value`);
    if (values.has(flag)) throw new Error(`duplicate argument: ${flag}`);
    values.set(flag, value);
  }
  for (const flag of required) {
    if (!values.has(flag)) throw new Error(`${flag} is required`);
  }
  const aab = regularFile(values.get("--aab"), "Android AAB");
  const aar = regularFile(
    values.get("--candidate-aar"),
    "candidate Android AAR",
  );
  const candidateBundle = regularFile(
    values.get("--candidate-bundle"),
    "protected candidate bundle",
  );
  const output = resolve(values.get("--output"));
  const bundle = JSON.parse(readFileSync(candidateBundle, "utf8"));
  const aarBytes = readFileSync(aar);
  const manifest = buildAndroidUniversalManifest({
    aabEntries: archiveEntries(aab),
    aarEntries: archiveEntries(aar),
    readAabEntry: (entry) => archiveBytes(aab, entry),
    readAarEntry: (entry) => archiveBytes(aar, entry),
    aarSha256: sha256(aarBytes),
    protectedAarSha256: candidateAarDigest(bundle),
  });
  if (basename(dirname(aar)) !== "Vendor") {
    throw new Error(
      "candidate Android AAR must be the canonical Vendor artifact",
    );
  }
  const contents = `${JSON.stringify(manifest, null, 2)}\n`;
  writeFileSync(output, contents, {
    encoding: "utf8",
    flag: "wx",
    mode: 0o600,
  });
  process.stdout.write(
    `${JSON.stringify({ ok: true, output, manifestSha256: sha256(contents), ...manifest })}\n`,
  );
  return manifest;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    run(process.argv.slice(2));
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
