#!/usr/bin/env node
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const FAILURE_MARKER_RE = /:x:\s*FAIL\b|:no_entry:\s*BLOCKED\b/iu;
const RESULT_FAILURE_RE = /(?:^|\s)(?::x:\s*)?FAIL\b|(?:^|\s)(?::no_entry:\s*)?BLOCKED\b/iu;

export function splitMarkdownTableRow(line) {
  const cells = [];
  let current = "";
  let escaped = false;
  for (const char of line.trim()) {
    if (escaped) {
      current += char;
      escaped = false;
      continue;
    }
    if (char === "\\") {
      escaped = true;
      current += char;
      continue;
    }
    if (char === "|") {
      cells.push(current);
      current = "";
      continue;
    }
    current += char;
  }
  cells.push(current);
  if (cells[0]?.trim() === "") cells.shift();
  if (cells.at(-1)?.trim() === "") cells.pop();
  return cells.map((cell) => cell.replace(/\\\|/gu, "|").trim());
}

function isSeparatorRow(cells) {
  return cells.length > 0 && cells.every((cell) => /^:?-{3,}:?$/u.test(cell.trim()));
}

function isFailureResult(text) {
  return RESULT_FAILURE_RE.test(text);
}

export function findFunctionalQaFailures(report) {
  const failures = [];
  let inFence = false;
  let resultColumn = null;
  const lines = report.split(/\r?\n/u);

  lines.forEach((line, index) => {
    const trimmed = line.trim();
    if (trimmed.startsWith("```")) {
      inFence = !inFence;
      return;
    }
    if (inFence || trimmed.length === 0) return;

    if (trimmed.startsWith("|")) {
      const cells = splitMarkdownTableRow(trimmed);
      const headerIndex = cells.findIndex((cell) => cell.toLowerCase() === "result");
      if (headerIndex >= 0) {
        resultColumn = headerIndex;
        return;
      }
      if (isSeparatorRow(cells)) return;

      const result = resultColumn === null ? undefined : cells[resultColumn];
      if ((result !== undefined && isFailureResult(result)) || FAILURE_MARKER_RE.test(trimmed)) {
        failures.push({ line: index + 1, text: line });
      }
      return;
    }

    if (FAILURE_MARKER_RE.test(trimmed)) {
      failures.push({ line: index + 1, text: line });
    }
  });

  return failures;
}

export function verifyFunctionalQaReport(report) {
  const failures = findFunctionalQaFailures(report);
  return { ok: failures.length === 0, failures };
}

function main() {
  const reportPath = process.argv[2] ?? "qa-results/report.md";
  const report = readFileSync(reportPath, "utf8");
  const result = verifyFunctionalQaReport(report);
  if (result.ok) return;

  console.error("::error::Functional QA report contains BLOCKED/FAIL result rows. See the PR comment.");
  for (const failure of result.failures) {
    console.error(`${failure.line}: ${failure.text}`);
  }
  process.exit(1);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main();
}

