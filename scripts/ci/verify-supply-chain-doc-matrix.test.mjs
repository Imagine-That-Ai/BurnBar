import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const ACTION =
  "actions/attest-build-provenance@96278af6caaf10aea03fd8d33a09a777ca52d62f";
const SLSA = "https://slsa.dev/provenance/v1";
const LEGACY_SUNSET = "v1.0.40+repair.37";

const matrix = readFileSync(
  new URL("../../docs/security/SUPPLY_CHAIN_PROVENANCE.md", import.meta.url),
  "utf8",
);
const mac = readFileSync(
  new URL("../../.github/workflows/release.yml", import.meta.url),
  "utf8",
);
const linux = readFileSync(
  new URL("../../.github/workflows/linux-release.yml", import.meta.url),
  "utf8",
);
const windows = readFileSync(
  new URL("../../.github/workflows/openburnbar-release-windows.yml", import.meta.url),
  "utf8",
);
const fastFeedback = readFileSync(
  new URL("../../.github/workflows/fast-feedback.yml", import.meta.url),
  "utf8",
);
const verifier = readFileSync(
  new URL("./verify-release-attestations.sh", import.meta.url),
  "utf8",
);

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&");
}

function workflowJob(source, name) {
  const start = source.indexOf(`  ${name}:\n`);
  assert.notEqual(start, -1, `missing workflow job ${name}`);
  const remainder = source.slice(start + 2);
  const next = remainder.search(/^  [A-Za-z0-9_-]+:\n/mu);
  return next === -1
    ? source.slice(start)
    : source.slice(start, start + 2 + next);
}

test("documentation declares the three release attestation rows", () => {
  assert.match(matrix, /^## Artifact × attestation × verifier matrix$/mu);
  for (const marker of [
    "macOS DMG, ZIP, and `checksums-v*.txt`",
    "Linux AppImage, daemon binary, Arch `.pkg.tar.zst`, Debian `.deb`, RPM `.rpm`",
    "Windows direct-download ZIP/MSIX, Store MSIX, and `checksums-windows-v*.txt`",
    "SPDX SBOM and OpenVEX sidecars on each release lane",
  ]) {
    assert.match(matrix, new RegExp(`^\\| ${escapeRegExp(marker)}`, "mu"), marker);
  }
  assert.match(matrix, new RegExp(escapeRegExp(ACTION), "gu"));
  assert.match(matrix, new RegExp(escapeRegExp(SLSA), "gu"));
  assert.match(matrix, /`gh attestation verify`/u);
  assert.match(matrix, /`cosign verify-blob-attestation`/u);
  assert.match(matrix, /`scripts\/ci\/verify-release-attestations\.sh <tag>`/u);
});

test("macOS workflow grants and uses the pinned GitHub provenance action", () => {
  const job = workflowJob(mac, "build-and-release");
  assert.match(job, /^    permissions:\n      attestations: write\n      contents: read\n      id-token: write$/mu);
  assert.equal(
    [...job.matchAll(new RegExp(escapeRegExp(ACTION), "gu"))].length,
    1,
  );
  assert.match(
    job,
    /subject-path:\s*\|\s*\n\s+\$\{\{ steps\.dmg\.outputs\.dmg_path \}\}\s*\n\s+\$\{\{ steps\.zip\.outputs\.zip_path \}\}\s*\n\s+\$\{\{ steps\.checksums\.outputs\.checksums_path \}\}/u,
  );
  assert.match(job, /export PREDICATE_TYPE="https:\/\/slsa\.dev\/provenance\/v1"/u);
});

test("Linux workflow attests every native package format and checksums", () => {
  const job = workflowJob(linux, "assemble-release");
  assert.match(job, /^    permissions:\n      attestations: write\n      contents: read\n      id-token: write$/mu);
  assert.match(job, new RegExp(escapeRegExp(ACTION), "u"));
  for (const suffix of [
    "artifacts/\\*\\.AppImage",
    "artifacts/\\*\\.pkg\\.tar\\.zst",
    "artifacts/\\*\\.deb",
    "artifacts/\\*\\.rpm",
    "artifacts/openburnbar-daemon-\\*",
    "sidecars/OpenBurnBar-.*-linux-checksums\\.txt",
  ]) {
    assert.match(job, new RegExp(suffix, "u"), suffix);
  }
});

test("Windows workflow attests ZIP, MSIX, and checksums subjects", () => {
  const job = workflowJob(windows, "build-sign");
  assert.match(job, /^    permissions:\n      attestations: write\n      contents: read\n      id-token: write/mu);
  assert.match(job, new RegExp(escapeRegExp(ACTION), "u"));
  for (const suffix of [
    "artifacts/\\*\\.zip",
    "artifacts/\\*\\.msix",
    "artifacts/store/\\*\\.msix",
    "artifacts/checksums-windows-v.*\\.txt",
  ]) {
    assert.match(job, new RegExp(suffix, "u"), suffix);
  }
});

test("legacy compatibility is documented and fail-closed at the verifier", () => {
  assert.match(matrix, new RegExp(escapeRegExp(LEGACY_SUNSET), "u"));
  assert.match(verifier, new RegExp(`LEGACY_PREDICATE_ACCEPTED_UNTIL_TAG="${escapeRegExp(LEGACY_SUNSET)}"`, "u"));
  assert.match(verifier, /SLSA_PREDICATE_TYPE="https:\/\/slsa\.dev\/provenance\/v1"/u);
  assert.match(verifier, /LEGACY_PREDICATE_TYPE="https:\/\/openburnbar\.dev\/attestations\/release-artifact\/v1"/u);
  assert.match(verifier, /unknown|unsupported release predicate identity/u);
  assert.match(verifier, /signed statement predicateType mismatch/u);
});

test("Fast Feedback runs the matrix test alongside the vendor checksum gate", () => {
  assert.match(
    fastFeedback,
    /run: node --test scripts\/ci\/verify-supply-chain-doc-matrix\.test\.mjs/u,
  );
  assert.match(
    fastFeedback,
    /vendor-checksums:[\s\S]*Verify supply-chain provenance documentation matrix/u,
  );
});
