#!/usr/bin/env node
// Verifies the local multi-model audit synthesis package before review or release handoff.
//
// This is intentionally narrower than the public-tree confidentiality guard:
// it checks that security-audit/merged is a clean, deterministic deliverable
// set and that the post-audit CLI/agent hardening claims still match source.

import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { basename, dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export const EXPECTED_MERGED_FILES = [
  "00_model_coverage_matrix.md",
  "01_deduped_findings.jsonl",
  "02_skeptic_review.md",
  "03_ranked_findings.md",
  "04_release_blockers.md",
  "FINAL_REPORT.md",
];

export const ALLOWED_STATUSES = new Set([
  "confirmed",
  "likely true positive",
  "needs manual review",
  "likely false positive",
  "false positive",
]);

const DANGEROUS_CLI_FLAGS = [
  "--dangerously-skip-permissions",
  "--dangerously-bypass-approvals-and-sandbox",
];

const DEFAULT_SOURCE_ROOTS = [
  "AgentLens",
  "OpenBurnBarCore",
  "OpenBurnBarDaemon",
  "OpenBurnBarMobile",
  "android",
  "crates",
  "functions/src",
];

const SKIP_DIR_NAMES = new Set([
  ".build",
  ".derived-data",
  ".git",
  ".gradle",
  "build",
  "DerivedData",
  "node_modules",
  "Pods",
]);

const TEXT_EXTENSIONS = new Set([
  ".c",
  ".cc",
  ".cpp",
  ".h",
  ".hpp",
  ".java",
  ".js",
  ".jsx",
  ".json",
  ".kt",
  ".kts",
  ".mjs",
  ".rs",
  ".sh",
  ".swift",
  ".ts",
  ".tsx",
  ".yml",
  ".yaml",
]);

function extname(path) {
  const leaf = basename(path);
  const dot = leaf.lastIndexOf(".");
  return dot === -1 ? "" : leaf.slice(dot);
}

function sortedFiles(root) {
  if (!existsSync(root)) return [];
  return readdirSync(root)
    .filter((name) => statSync(join(root, name)).isFile())
    .sort();
}

function readText(path) {
  return readFileSync(path, "utf8");
}

function validateMergedRoot(root, errors) {
  const actual = sortedFiles(root);
  const expected = [...EXPECTED_MERGED_FILES].sort();
  const actualSet = new Set(actual);
  const expectedSet = new Set(expected);
  for (const file of expected) {
    if (!actualSet.has(file)) errors.push(`missing merged report file: ${file}`);
  }
  for (const file of actual) {
    if (!expectedSet.has(file)) errors.push(`unexpected top-level merged report file: ${file}`);
  }
}

function validateJsonl(root, errors) {
  const path = join(root, "01_deduped_findings.jsonl");
  if (!existsSync(path)) return;
  const ids = new Set();
  let m040 = null;
  const lines = readText(path).split(/\r?\n/).filter((line) => line.trim().length > 0);
  if (lines.length === 0) {
    errors.push("01_deduped_findings.jsonl is empty");
    return;
  }
  lines.forEach((line, index) => {
    let record;
    try {
      record = JSON.parse(line);
    } catch (error) {
      errors.push(`invalid JSONL at line ${index + 1}: ${error.message}`);
      return;
    }
    if (typeof record.id !== "string" || !/^(M-\d{3}|FP-\d{2})$/.test(record.id)) {
      errors.push(`line ${index + 1} has invalid id: ${String(record.id)}`);
      return;
    }
    if (ids.has(record.id)) errors.push(`duplicate finding id: ${record.id}`);
    ids.add(record.id);
    if (!ALLOWED_STATUSES.has(record.status)) {
      errors.push(`${record.id} has unsupported status: ${String(record.status)}`);
    }
    if (typeof record.title !== "string" || record.title.trim() === "") {
      errors.push(`${record.id} is missing a title`);
    }
    if (record.id === "M-040") m040 = record;
  });
  if (!m040) {
    errors.push("M-040 is missing from 01_deduped_findings.jsonl");
  } else {
    if (m040.status !== "confirmed") errors.push("M-040 must remain status=confirmed");
    const evidence = JSON.stringify(m040).toLowerCase();
    for (const needle of ["trusted", "ambient", "shell", "approval"]) {
      if (!evidence.includes(needle)) errors.push(`M-040 evidence is missing '${needle}'`);
    }
  }
}

function validateMarkdown(root, errors) {
  const finalPath = join(root, "FINAL_REPORT.md");
  if (!existsSync(finalPath)) return;
  const final = readText(finalPath);
  for (const section of [
    "## 1. Executive Summary",
    "## 7. Release Blockers",
    "## 8. Regression Test Plan",
    "M-040",
  ]) {
    if (!final.includes(section)) errors.push(`FINAL_REPORT.md is missing required marker: ${section}`);
  }
  if (/confirmed latent/i.test(final)) {
    errors.push("FINAL_REPORT.md contains obsolete status text: confirmed latent");
  }
}

function validateRawEvidenceNotice(repoRoot, errors) {
  const noticePath = join(repoRoot, "security/threat-model/README.md");
  if (!existsSync(noticePath)) return;
  const text = readText(noticePath);
  if (!text.includes("SUPERSEDED BY POST-REMEDIATION SYNTHESIS")) {
    errors.push("security/threat-model/README.md is missing the superseded-evidence warning");
  }
}

function* walkTextFiles(root) {
  if (!existsSync(root)) return;
  const entries = readdirSync(root, { withFileTypes: true });
  for (const entry of entries) {
    const path = join(root, entry.name);
    if (entry.isDirectory()) {
      if (!SKIP_DIR_NAMES.has(entry.name)) yield* walkTextFiles(path);
      continue;
    }
    if (entry.isFile() && TEXT_EXTENSIONS.has(extname(entry.name))) yield path;
  }
}

function validateProductionSourceFlags(repoRoot, sourceRoots, errors) {
  const hits = [];
  for (const sourceRoot of sourceRoots) {
    const absRoot = join(repoRoot, sourceRoot);
    for (const file of walkTextFiles(absRoot)) {
      const text = readText(file);
      for (const flag of DANGEROUS_CLI_FLAGS) {
        if (text.includes(flag)) hits.push(`${relative(repoRoot, file)} contains ${flag}`);
      }
    }
  }
  if (hits.length > 0) {
    errors.push(`dangerous CLI bypass flags remain in production source:\n${hits.map((h) => `  - ${h}`).join("\n")}`);
  }
}

export function validatePackage(options = {}) {
  const repoRoot = resolve(options.repoRoot ?? join(dirname(fileURLToPath(import.meta.url)), "../.."));
  const root = resolve(repoRoot, options.root ?? "security-audit/merged");
  const sourceRoots = options.sourceRoots ?? DEFAULT_SOURCE_ROOTS;
  const errors = [];

  if (!existsSync(root)) {
    errors.push(`merged audit package directory does not exist: ${relative(repoRoot, root)}`);
    return { ok: false, root, repoRoot, errors };
  }

  validateMergedRoot(root, errors);
  validateJsonl(root, errors);
  validateMarkdown(root, errors);
  validateRawEvidenceNotice(repoRoot, errors);
  validateProductionSourceFlags(repoRoot, sourceRoots, errors);

  return { ok: errors.length === 0, root, repoRoot, errors };
}

function main(argv) {
  const args = new Set(argv.slice(2));
  const asJson = args.has("--json");
  const result = validatePackage();
  if (asJson) {
    console.log(JSON.stringify(result, null, 2));
  } else if (result.ok) {
    console.log(`PASS: merged audit package verified at ${relative(result.repoRoot, result.root)}`);
  } else {
    console.error(`FAIL: merged audit package is not ready at ${relative(result.repoRoot, result.root)}`);
    for (const error of result.errors) console.error(`- ${error}`);
  }
  return result.ok ? 0 : 1;
}

const isMain =
  process.argv[1] &&
  resolve(process.argv[1]) === resolve(fileURLToPath(import.meta.url));
if (isMain) process.exit(main(process.argv));

export { main };
