#!/usr/bin/env node

import { lstatSync, readFileSync, readdirSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

const REQUIRED_COUNTERS = [
  "aborted",
  "disconnected",
  "error",
  "executed",
  "failed",
  "inconclusive",
  "inProgress",
  "notExecuted",
  "notRunnable",
  "passed",
  "passedButRunAborted",
  "pending",
  "timeout",
  "total",
  "warning",
];
const FAILURE_COUNTERS = REQUIRED_COUNTERS.filter(
  (name) => !["executed", "notExecuted", "passed", "total"].includes(name),
);

function positiveInteger(value, label) {
  if (!/^[1-9][0-9]*$/u.test(value)) {
    throw new Error(`${label} must be a positive integer`);
  }
  return Number.parseInt(value, 10);
}

function nonnegativeInteger(value, label) {
  if (!/^(?:0|[1-9][0-9]*)$/u.test(value)) {
    throw new Error(`${label} must be a nonnegative integer`);
  }
  return Number.parseInt(value, 10);
}

function collectTrxFiles(directory) {
  const files = [];
  function visit(path) {
    const metadata = lstatSync(path);
    if (metadata.isSymbolicLink()) {
      throw new Error(`TRX evidence must not contain symlinks: ${path}`);
    }
    if (metadata.isDirectory()) {
      for (const entry of readdirSync(path, { withFileTypes: true }).sort(
        (left, right) => left.name.localeCompare(right.name),
      )) {
        visit(resolve(path, entry.name));
      }
      return;
    }
    if (metadata.isFile() && path.toLowerCase().endsWith(".trx")) {
      files.push(path);
    }
  }

  const rootMetadata = lstatSync(directory);
  if (!rootMetadata.isDirectory() || rootMetadata.isSymbolicLink()) {
    throw new Error(
      `TRX results directory must be a real directory: ${directory}`,
    );
  }
  visit(directory);
  return files.sort();
}

function parseCounters(path) {
  const source = readFileSync(path, "utf8");
  const summaryMatches = [
    ...source.matchAll(/<ResultSummary\b[^>]*\boutcome="([^"]+)"[^>]*>/gu),
  ];
  if (summaryMatches.length !== 1 || summaryMatches[0][1] !== "Completed") {
    throw new Error(
      `TRX result must contain one completed ResultSummary: ${path}`,
    );
  }

  const counterMatches = [...source.matchAll(/<Counters\b([^>]*)\/>/gu)];
  if (counterMatches.length !== 1) {
    throw new Error(
      `TRX result must contain exactly one Counters element: ${path}`,
    );
  }

  const counters = {};
  for (const attribute of counterMatches[0][1].matchAll(
    /\b([A-Za-z][A-Za-z0-9]*)="([0-9]+)"/gu,
  )) {
    counters[attribute[1]] = Number.parseInt(attribute[2], 10);
  }
  for (const name of REQUIRED_COUNTERS) {
    if (!Number.isSafeInteger(counters[name]) || counters[name] < 0) {
      throw new Error(`TRX result is missing a valid ${name} counter: ${path}`);
    }
  }
  for (const name of FAILURE_COUNTERS) {
    if (counters[name] !== 0) {
      throw new Error(`TRX result has ${name}=${counters[name]}: ${path}`);
    }
  }
  if (counters.executed !== counters.passed + counters.failed) {
    throw new Error(`TRX executed counter is inconsistent: ${path}`);
  }
  if (counters.total !== counters.executed + counters.notExecuted) {
    throw new Error(`TRX total counter is inconsistent: ${path}`);
  }
  return counters;
}

export function verifyTrxResults(
  resultsDirectory,
  minimumFiles,
  minimumTests,
  maximumNotExecuted,
) {
  const directory = resolve(resultsDirectory);
  const files = collectTrxFiles(directory);
  if (files.length < minimumFiles) {
    throw new Error(
      `TRX evidence is incomplete: expected at least ${minimumFiles} files, found ${files.length}`,
    );
  }

  const totals = {
    total: 0,
    executed: 0,
    passed: 0,
    failed: 0,
    notExecuted: 0,
  };
  for (const file of files) {
    const counters = parseCounters(file);
    for (const name of Object.keys(totals)) {
      totals[name] += counters[name];
    }
  }
  if (totals.total < minimumTests) {
    throw new Error(
      `TRX evidence is incomplete: expected at least ${minimumTests} tests, found ${totals.total}`,
    );
  }
  if (totals.notExecuted > maximumNotExecuted) {
    throw new Error(
      `TRX evidence skipped too many tests: allowed at most ${maximumNotExecuted}, found ${totals.notExecuted}`,
    );
  }

  return {
    ok: true,
    resultsDirectory: directory,
    files: files.length,
    ...totals,
  };
}

function parseArguments(argv) {
  if (argv.length !== 8) {
    throw new Error(
      "usage: --results-directory PATH --minimum-files COUNT --minimum-tests COUNT --maximum-not-executed COUNT",
    );
  }
  const values = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    if (
      ![
        "--results-directory",
        "--minimum-files",
        "--minimum-tests",
        "--maximum-not-executed",
      ].includes(flag) ||
      values.has(flag)
    ) {
      throw new Error(
        "usage: --results-directory PATH --minimum-files COUNT --minimum-tests COUNT --maximum-not-executed COUNT",
      );
    }
    values.set(flag, argv[index + 1]);
  }
  return {
    resultsDirectory: values.get("--results-directory"),
    minimumFiles: positiveInteger(
      values.get("--minimum-files"),
      "--minimum-files",
    ),
    minimumTests: positiveInteger(
      values.get("--minimum-tests"),
      "--minimum-tests",
    ),
    maximumNotExecuted: nonnegativeInteger(
      values.get("--maximum-not-executed"),
      "--maximum-not-executed",
    ),
  };
}

export function run(argv) {
  const options = parseArguments(argv);
  const summary = verifyTrxResults(
    options.resultsDirectory,
    options.minimumFiles,
    options.minimumTests,
    options.maximumNotExecuted,
  );
  process.stdout.write(`${JSON.stringify(summary)}\n`);
  return summary;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    run(process.argv.slice(2));
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
