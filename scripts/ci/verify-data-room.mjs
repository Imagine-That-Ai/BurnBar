#!/usr/bin/env node

/**
 * Verify the public diligence data-room index.
 *
 * Every evidence cell is either a repository-relative path that exists or an
 * explicitly named, allowlisted check command. Keeping the command vocabulary
 * here prevents a row from claiming evidence through an arbitrary command.
 *
 * Usage: node scripts/ci/verify-data-room.mjs --check
 */

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const INDEX_PATH = path.join(REPO_ROOT, "docs/data-room/INDEX.md");
const EXPECTED_SECTIONS = [
  "Clone / layout",
  "Claims vs ledgers",
  "CI health",
  "Deploy proof",
  "Security harness",
  "Supply chain",
  "Bus factor",
  "Depth",
];
const KNOWN_CHECKS = new Set([
  "bash scripts/ci/check-no-suppressions.sh",
  "bash scripts/ci/check-root-inventory.sh",
  "bash scripts/ops/verify-access-inventory.sh --schema",
  "bash scripts/verify-version-consistency.sh",
  "node scripts/ci/verify-data-room.mjs --check",
  "node scripts/release/render-release-status.mjs --check",
  "node scripts/security/scan-internal-content.mjs",
]);

function fail(message) {
  console.error(`FAIL: data-room index — ${message}`);
  process.exitCode = 1;
}

function stripMarkdown(value) {
  return value.replace(/`/g, "").trim();
}

function splitTableRow(line) {
  let row = line.trim();
  if (!row.startsWith("|")) return null;
  if (row.endsWith("|")) row = row.slice(0, -1);
  row = row.slice(1);
  return row.split("|").map((cell) => cell.trim());
}

function isSeparator(cells) {
  return cells.length > 0 && cells.every((cell) => /^:?-{3,}:?$/.test(cell));
}

function checkEvidence(rawEvidence, section, rowNumber) {
  const evidence = stripMarkdown(rawEvidence);
  if (!evidence) {
    fail(`${section}, row ${rowNumber} has empty evidence`);
    return;
  }

  if (evidence.startsWith("--check")) {
    const command = evidence.slice("--check".length).replace(/^:\s*/, "").trim();
    if (!KNOWN_CHECKS.has(command)) {
      fail(`${section}, row ${rowNumber} uses unknown check command: ${command || "(empty)"}`);
    }
    return;
  }

  if (path.isAbsolute(evidence) || evidence.split("/").includes("..")) {
    fail(`${section}, row ${rowNumber} must use a repository-relative evidence path: ${evidence}`);
    return;
  }
  const absolute = path.resolve(REPO_ROOT, evidence);
  const relative = path.relative(REPO_ROOT, absolute);
  if (relative.startsWith("..") || path.isAbsolute(relative)) {
    fail(`${section}, row ${rowNumber} escapes the repository: ${evidence}`);
    return;
  }
  if (!fs.existsSync(absolute)) {
    fail(`${section}, row ${rowNumber} points to missing evidence: ${evidence}`);
  }
}

function verify() {
  if (!fs.existsSync(INDEX_PATH)) {
    fail(`missing ${path.relative(REPO_ROOT, INDEX_PATH)}`);
    return;
  }

  const lines = fs.readFileSync(INDEX_PATH, "utf8").split(/\r?\n/);
  const headings = [];
  lines.forEach((line, index) => {
    const match = line.match(/^##\s+(.+?)\s*$/);
    if (match) headings.push({ name: match[1], line: index });
  });

  if (headings.length !== EXPECTED_SECTIONS.length) {
    fail(`expected ${EXPECTED_SECTIONS.length} diligence sections, found ${headings.length}`);
  }

  const seen = new Set();
  for (const expected of EXPECTED_SECTIONS) {
    const heading = headings.find((candidate) => candidate.name === expected);
    if (!heading) {
      fail(`missing section: ${expected}`);
      continue;
    }
    if (seen.has(expected)) {
      fail(`duplicate section: ${expected}`);
      continue;
    }
    seen.add(expected);

    const nextHeading = headings.find((candidate) => candidate.line > heading.line);
    const end = nextHeading?.line ?? lines.length;
    const tableRows = [];
    for (let index = heading.line + 1; index < end; index += 1) {
      const cells = splitTableRow(lines[index]);
      if (cells) tableRows.push({ cells, line: index + 1 });
    }

    if (tableRows.length < 2) {
      fail(`${expected} must contain a header and at least one evidence row`);
      continue;
    }
    const header = tableRows.shift();
    if (
      header.cells.length !== 4 ||
      header.cells[0].toLowerCase() !== "claim" ||
      header.cells[1].toLowerCase() !== "evidence path or --check command" ||
      header.cells[2].toLowerCase() !== "last-verified" ||
      header.cells[3].toLowerCase() !== "owner"
    ) {
      fail(`${expected}, line ${header.line} has the wrong four-column header`);
    }

    if (tableRows.length > 0 && isSeparator(tableRows[0].cells)) {
      tableRows.shift();
    }
    if (tableRows.length === 0) {
      fail(`${expected} has no evidence rows`);
      continue;
    }

    for (const row of tableRows) {
      if (row.cells.length !== 4) {
        fail(`${expected}, line ${row.line} must have exactly four pipe-delimited cells`);
        continue;
      }
      const [claim, evidence, lastVerified, owner] = row.cells;
      if (!claim || !owner) fail(`${expected}, line ${row.line} has an empty claim or owner`);
      if (!/^\d{4}-\d{2}-\d{2}$/.test(lastVerified)) {
        fail(`${expected}, line ${row.line} has invalid last-verified date: ${lastVerified || "(empty)"}`);
      }
      checkEvidence(evidence, expected, row.line);
    }
  }

  if (seen.size === EXPECTED_SECTIONS.length && process.exitCode !== 1) {
    console.log(`PASS: data-room index has ${seen.size} diligence sections with valid evidence rows`);
  }
}

if (process.argv.length !== 3 || process.argv[2] !== "--check") {
  console.error("Usage: node scripts/ci/verify-data-room.mjs --check");
  process.exit(2);
}
verify();
