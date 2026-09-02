#!/usr/bin/env node

/**
 * Render the generated release-status ledger and its README block.
 *
 * This intentionally reads only committed repository files. In particular it
 * never asks Git for tags: the release checkout is allowed to be blob-only and
 * tagless. The macOS version comes from project.yml, while parity and
 * operator-owned fields come from committed ledgers/templates.
 *
 * Usage:
 *   node scripts/release/render-release-status.mjs
 *   node scripts/release/render-release-status.mjs --check
 */

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const README_PATH = path.join(REPO_ROOT, "README.md");
const PROJECT_PATH = path.join(REPO_ROOT, "project.yml");
const INPUT_PATH = path.join(REPO_ROOT, "docs/status/release-status.input.json");
const OUTPUT_PATH = path.join(REPO_ROOT, "docs/status/release-status.json");
const SURFACES_PATH = path.join(REPO_ROOT, "docs/status/surfaces.json");
const MOBILE_LEDGER_PATH = path.join(
  REPO_ROOT,
  "docs/mobile-parity/mobile-parity-ledger.json",
);
const WINDOWS_LEDGER_PATH = path.join(
  REPO_ROOT,
  "docs/windows-port/WINDOWS_PARITY_LEDGER.yml",
);
const START_MARKER = "<!-- release-status:start -->";
const END_MARKER = "<!-- release-status:end -->";
const REQUIRED_INPUT_FIELDS = [
  "macAppStoreReviewState",
  "iosReviewState",
  "manualReleaseEnabled",
  "windowsChannelClaim",
];
const REQUIRED_SURFACES = [
  "macos",
  "ios",
  "android",
  "windows",
  "linux",
  "daemon",
  "extension",
  "cli",
];

function readText(filePath) {
  return fs.readFileSync(filePath, "utf8");
}

function readJson(filePath) {
  return JSON.parse(readText(filePath));
}

function oneLine(value, label) {
  if (typeof value !== "string" || !value.trim()) {
    throw new Error(`${label} must be a non-empty string`);
  }
  if (/[\r\n`]/.test(value)) {
    throw new Error(`${label} must be a single line without backticks`);
  }
  return value.trim().replace(/\s+/g, " ");
}

function readMarketingVersion() {
  const match = readText(PROJECT_PATH).match(
    /^\s+MARKETING_VERSION:\s*["']?([0-9]+\.[0-9]+\.[0-9]+)["']?\s*$/m,
  );
  if (!match) throw new Error("project.yml has no X.Y.Z MARKETING_VERSION");
  return match[1];
}

function readWindowsLedgerSchemaVersion() {
  const match = readText(WINDOWS_LEDGER_PATH).match(
    /^version:\s*([0-9]+)\s*$/m,
  );
  if (!match) throw new Error("Windows parity ledger has no schema version");
  return Number(match[1]);
}

function validateInput(input) {
  if (input.schemaVersion !== 1) throw new Error("release-status.input.json schemaVersion must be 1");
  const lastConfirmed = oneLine(input.lastConfirmed, "lastConfirmed");
  if (!/^\d{4}-\d{2}-\d{2}$/.test(lastConfirmed)) {
    throw new Error("lastConfirmed must be YYYY-MM-DD");
  }
  const storeFacing = {};
  for (const field of REQUIRED_INPUT_FIELDS) {
    storeFacing[field] = oneLine(input[field], field);
  }
  return { lastConfirmed, storeFacing };
}

function validateSurfaces(document) {
  if (!Array.isArray(document)) {
    throw new Error("surfaces.json must be an array");
  }
  if (document.length !== REQUIRED_SURFACES.length) {
    throw new Error(`surfaces.json must contain exactly ${REQUIRED_SURFACES.length} surfaces`);
  }
  const ids = document.map((surface) => surface?.id);
  if (
    ids.some((id) => !REQUIRED_SURFACES.includes(id)) ||
    new Set(ids).size !== REQUIRED_SURFACES.length
  ) {
    throw new Error(`surfaces.json ids must be exactly ${REQUIRED_SURFACES.join(", ")}`);
  }
  for (const surface of document) {
    const tier = oneLine(surface.tier, `${surface.id}.tier`);
    const evidence = oneLine(surface.evidence, `${surface.id}.evidence`);
    if (path.isAbsolute(evidence) || evidence.split("/").includes("..")) {
      throw new Error(`${surface.id}.evidence must be repository-relative`);
    }
    const evidencePath = path.resolve(REPO_ROOT, evidence);
    if (!fs.existsSync(evidencePath)) {
      throw new Error(`${surface.id}.evidence is missing: ${evidence}`);
    }
    surface.tier = tier;
    surface.evidence = evidence;
  }
  return document;
}

function buildReleaseStatus() {
  const version = readMarketingVersion();
  const input = validateInput(readJson(INPUT_PATH));
  const surfaces = validateSurfaces(readJson(SURFACES_PATH));
  const mobileLedger = readJson(MOBILE_LEDGER_PATH);
  const productParityClaim = mobileLedger.semantics?.productParityClaim;
  if (typeof productParityClaim !== "boolean") {
    throw new Error("mobile parity ledger semantics.productParityClaim must be boolean");
  }
  const programStatus = oneLine(
    mobileLedger.semantics?.programStatus,
    "mobile parity ledger semantics.programStatus",
  );
  const windowsSchemaVersion = readWindowsLedgerSchemaVersion();

  const storeFacing = Object.fromEntries(
    REQUIRED_INPUT_FIELDS.map((field) => [
      field,
      {
        value: input.storeFacing[field],
        claim: `operator-asserted (last confirmed ${input.lastConfirmed})`,
      },
    ]),
  );

  return {
    schemaVersion: 1,
    generatedFrom: [
      "project.yml",
      "docs/status/release-status.input.json",
      "docs/status/surfaces.json",
      "docs/mobile-parity/mobile-parity-ledger.json",
      "docs/windows-port/WINDOWS_PARITY_LEDGER.yml",
    ],
    macOS: {
      marketingVersion: version,
      evidence: "project.yml",
    },
    windows: {
      ledgerSchemaVersion: windowsSchemaVersion,
      evidence: "docs/windows-port/WINDOWS_PARITY_LEDGER.yml",
    },
    mobileParity: {
      productParityClaim,
      programStatus,
      evidence: "docs/mobile-parity/mobile-parity-ledger.json",
    },
    storeFacing,
    surfaces,
  };
}

function renderBlock(status) {
  const asserted = (field) =>
    `${status.storeFacing[field].claim} — ${status.storeFacing[field].value}`;
  return [
    START_MARKER,
    `**Status:** Commercial launch candidate — macOS \`${status.macOS.marketingVersion}\` is the committed product version; mobile parity claim is \`${status.mobileParity.productParityClaim}\` (${status.mobileParity.programStatus}); Mac App Store review: ${asserted("macAppStoreReviewState")}; iOS review: ${asserted("iosReviewState")}; manual release: ${asserted("manualReleaseEnabled")}; Windows channel: ${asserted("windowsChannelClaim")}.`,
    END_MARKER,
  ].join("\n");
}

function expectedReadme(readme, block) {
  const markerPattern = new RegExp(
    `${START_MARKER.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}[\\s\\S]*?${END_MARKER.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}`,
    "g",
  );
  const matches = readme.match(markerPattern) ?? [];
  if (matches.length !== 1) {
    throw new Error("README.md must contain exactly one release-status marker block");
  }
  return readme.replace(markerPattern, block);
}

function main() {
  const check = process.argv.includes("--check");
  if (process.argv.length !== (check ? 3 : 2) || (check && process.argv[2] !== "--check")) {
    console.error("Usage: node scripts/release/render-release-status.mjs [--check]");
    process.exit(2);
  }

  const status = buildReleaseStatus();
  const generatedJson = `${JSON.stringify(status, null, 2)}\n`;
  const renderedBlock = renderBlock(status);
  const currentJson = fs.existsSync(OUTPUT_PATH) ? readText(OUTPUT_PATH) : "";
  const currentReadme = readText(README_PATH);
  const renderedReadme = expectedReadme(currentReadme, renderedBlock);

  if (check) {
    let failed = false;
    if (currentJson !== generatedJson) {
      console.error("FAIL: docs/status/release-status.json is stale; run the renderer without --check.");
      failed = true;
    }
    if (currentReadme !== renderedReadme) {
      console.error("FAIL: README.md release-status block is stale; run the renderer without --check.");
      failed = true;
    }
    if (failed) process.exit(1);
    console.log("PASS: generated release status and README block are current");
    return;
  }

  fs.writeFileSync(OUTPUT_PATH, generatedJson, "utf8");
  fs.writeFileSync(README_PATH, renderedReadme, "utf8");
  console.log("Wrote docs/status/release-status.json and README.md release-status block");
}

main();
