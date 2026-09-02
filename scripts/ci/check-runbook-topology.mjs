#!/usr/bin/env node
/**
 * CI guard for the project and endpoint topology used by operational code.
 *
 * Production project identifiers and Cloud Functions hosts must come from the
 * checked-in Firebase configuration or the resolver script. This guard keeps
 * stale pre-BurnBar identifiers out of runbooks, deploy scripts, Functions
 * metadata, and workflows while preserving the deliberately named emulator
 * projects used by tests and local DAST.
 *
 * Usage:
 *   node scripts/ci/check-runbook-topology.mjs
 *   node scripts/ci/check-runbook-topology.mjs --fixture bad-project-id
 *   node scripts/ci/check-runbook-topology.mjs --fixture bad-firebaserc
 *
 * Exit:
 *   0 = clean
 *   1 = stale topology found (or the negative fixture found its violation)
 *   2 = checker error or invalid arguments
 */

import {
  appendFile,
  copyFile,
  mkdtemp,
  readFile,
  readdir,
  rm,
  mkdir,
  stat,
  writeFile,
} from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const REPO_ROOT = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
  "..",
);

// The root Firebase configuration is the topology source of truth the
// resolver reads at runtime, so it is scanned as text AND validated as JSON
// (see validateFirebaseRc) — a retired project id there is the most
// consequential regression this guard exists to catch.
const ROOT_CONFIG_FILES = [".firebaserc", "firebase.json"];

const SCAN_ROOTS = [
  { directory: "docs", extensions: null },
  { directory: "scripts", extensions: new Set([".sh", ".mjs"]) },
  { directory: "functions", extensions: null },
  { directory: ".github/workflows", extensions: new Set([".yml", ".yaml"]) },
];

// These are the only intentionally retained openburnbar-* project IDs. Do not
// widen this set for a new environment without also updating the topology
// source of truth and its operator contract.
export const ALLOWED_PROJECT_IDS = new Set([
  "openburnbar-dev",
  "openburnbar-rules-test",
  "openburnbar-demo",
]);

// Build the retired identifier from parts so this guard does not match its own
// negative-control fixture or pattern source while scanning scripts/.
const STALE_PROJECT_ID = ["open", "burnbar"].join("");
const STALE_PROJECT_PREFIX = `${STALE_PROJECT_ID}-`;

const LEGACY_HOST_RE = new RegExp(
  `\\b[a-z0-9][a-z0-9-]*-${STALE_PROJECT_ID}\\.cloudfunctions\\.net\\b`,
  "gi",
);
const PROJECT_CONTEXT_RE =
  /(?:--project(?:=|\s+)|firebase\s+use\s+)(["'`]?)([a-z][a-z0-9-]*)\1(?![a-z0-9-])/gi;
const PROJECT_RESOURCE_RE = /projects\/([a-z][a-z0-9-]*)\//gi;

function isRetiredProjectID(projectID) {
  const normalizedProjectID = projectID.toLowerCase();
  return (
    normalizedProjectID === STALE_PROJECT_ID ||
    (normalizedProjectID.startsWith(STALE_PROJECT_PREFIX) &&
      !ALLOWED_PROJECT_IDS.has(normalizedProjectID))
  );
}

function shouldSkip(relativePath) {
  const parts = relativePath.split(path.sep);
  const basename = parts.at(-1) ?? "";
  return (
    parts.includes("__tests__") ||
    basename.includes(".test.") ||
    parts.includes("node_modules")
  );
}

async function walk(directory, extensions, root, files = []) {
  let entries;
  try {
    entries = await readdir(directory, { withFileTypes: true });
  } catch {
    return files;
  }

  for (const entry of entries) {
    const fullPath = path.join(directory, entry.name);
    const relativePath = path.relative(root, fullPath);
    if (shouldSkip(relativePath)) continue;
    if (entry.isDirectory()) {
      await walk(fullPath, extensions, root, files);
      continue;
    }
    if (!entry.isFile()) continue;
    if (extensions && !extensions.has(path.extname(entry.name).toLowerCase())) {
      continue;
    }
    files.push(fullPath);
  }
  return files;
}

async function filesToScan(root) {
  const files = [];
  for (const name of ROOT_CONFIG_FILES) {
    const fullPath = path.join(root, name);
    try {
      if ((await stat(fullPath)).isFile()) files.push(fullPath);
    } catch {
      // Absent in fixtures and partial checkouts; the JSON validation below
      // reports a missing .firebaserc explicitly.
    }
  }
  for (const { directory, extensions } of SCAN_ROOTS) {
    const scanRoot = path.join(root, directory);
    files.push(...(await walk(scanRoot, extensions, scanRoot)));
  }
  return files;
}

// Every project id named by .firebaserc (aliases and hosting/function targets)
// must be a live id, not the retired one or an unlisted retired-prefixed one.
async function validateFirebaseRc(root, violations) {
  const file = path.join(root, ".firebaserc");
  let raw;
  try {
    raw = await readFile(file, "utf8");
  } catch {
    if (root === REPO_ROOT) {
      addViolation(violations, root, file, 0, "missing firebaserc", "(absent)");
    }
    return;
  }
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (error) {
    addViolation(violations, root, file, 0, "unparseable firebaserc", error.message);
    return;
  }
  const projectIDs = [];
  for (const [alias, projectID] of Object.entries(parsed.projects ?? {})) {
    projectIDs.push([`projects.${alias}`, projectID]);
  }
  for (const projectID of Object.keys(parsed.targets ?? {})) {
    projectIDs.push(["targets", projectID]);
  }
  for (const [where, projectID] of projectIDs) {
    if (typeof projectID !== "string" || isRetiredProjectID(projectID)) {
      addViolation(
        violations,
        root,
        file,
        0,
        "retired firebaserc project",
        `${where}: ${String(projectID)}`,
      );
    }
  }
}

function addViolation(violations, root, file, line, rule, text) {
  violations.push({
    file: path.relative(root, file).split(path.sep).join("/"),
    line,
    rule,
    text: text.trim(),
  });
}

function scanLine(violations, root, file, lineNumber, line) {
  LEGACY_HOST_RE.lastIndex = 0;
  if (LEGACY_HOST_RE.test(line)) {
    addViolation(
      violations,
      root,
      file,
      lineNumber,
      "legacy Cloud Functions host",
      line,
    );
  }

  PROJECT_CONTEXT_RE.lastIndex = 0;
  let match;
  while ((match = PROJECT_CONTEXT_RE.exec(line)) !== null) {
    const projectID = match[2];
    if (isRetiredProjectID(projectID)) {
      addViolation(
        violations,
        root,
        file,
        lineNumber,
        `retired project id '${projectID}'`,
        line,
      );
    }
  }

  PROJECT_RESOURCE_RE.lastIndex = 0;
  while ((match = PROJECT_RESOURCE_RE.exec(line)) !== null) {
    const projectID = match[1];
    if (isRetiredProjectID(projectID)) {
      addViolation(
        violations,
        root,
        file,
        lineNumber,
        `retired project resource '${projectID}'`,
        line,
      );
    }
  }
}

export async function scanRoot(root = REPO_ROOT) {
  const violations = [];
  await validateFirebaseRc(root, violations);
  const files = await filesToScan(root);
  for (const file of files) {
    let text;
    try {
      text = await readFile(file, "utf8");
    } catch {
      continue;
    }
    text.split(/\r?\n/u).forEach((line, index) => {
      scanLine(violations, root, file, index + 1, line);
    });
  }
  return violations;
}

function printViolations(violations) {
  for (const violation of violations) {
    console.error(
      `${violation.file}:${violation.line}: ${violation.rule}: ${violation.text}`,
    );
  }
}

const FIXTURES = new Set(["bad-project-id", "bad-firebaserc"]);

async function runFixture(fixtureName) {
  if (!FIXTURES.has(fixtureName)) {
    console.error(`Unknown fixture: ${fixtureName}`);
    return 2;
  }

  const fixtureRoot = await mkdtemp(
    path.join(os.tmpdir(), "openburnbar-runbook-topology-"),
  );
  try {
    await mkdir(path.join(fixtureRoot, "docs"), { recursive: true });
    if (fixtureName === "bad-project-id") {
      const badProjectFlag = ["--project", STALE_PROJECT_ID].join(" ");
      const fixturePath = path.join(fixtureRoot, "docs", "fixture.md");
      await copyFile(path.join(REPO_ROOT, "docs", "api", "openapi.yaml"), fixturePath);
      await appendFile(fixturePath, `\nfixture negative control: ${badProjectFlag}\n`, "utf8");
    } else {
      // A .firebaserc pointing the default alias back at the retired project.
      await writeFile(
        path.join(fixtureRoot, ".firebaserc"),
        `${JSON.stringify({ projects: { default: STALE_PROJECT_ID } }, null, 2)}\n`,
        "utf8",
      );
    }
    const violations = await scanRoot(fixtureRoot);
    if (violations.length === 0) {
      console.error(`FAIL: ${fixtureName} fixture was not detected.`);
      return 2;
    }
    console.error(`PASS: ${fixtureName} fixture was rejected as expected.`);
    printViolations(violations);
    return 1;
  } finally {
    await rm(fixtureRoot, { recursive: true, force: true });
  }
}

async function main(argv = process.argv.slice(2)) {
  if (argv.length === 0) {
    const violations = await scanRoot();
    if (violations.length > 0) {
      console.error("FAIL: stale runbook topology literals found.");
      printViolations(violations);
      return 1;
    }
    console.log("PASS: runbook topology has no stale project or endpoint literals.");
    return 0;
  }

  if (argv[0] === "--fixture" && argv.length === 2) {
    return runFixture(argv[1]);
  }

  if (argv[0] === "--help" || argv[0] === "-h") {
    console.log(
      "Usage: node scripts/ci/check-runbook-topology.mjs [--fixture bad-project-id|bad-firebaserc]",
    );
    return 0;
  }

  console.error(`Unknown arguments: ${argv.join(" ")}`);
  return 2;
}

const isMain =
  process.argv[1] &&
  path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url));

if (isMain) {
  try {
    process.exitCode = await main();
  } catch (error) {
    console.error(`check-runbook-topology failed: ${error.message}`);
    process.exitCode = 2;
  }
}
