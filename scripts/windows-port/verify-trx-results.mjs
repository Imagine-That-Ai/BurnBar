#!/usr/bin/env node

import { lstatSync, readdirSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { readRegularFileSync } from "../lib/atomic-regular-file.mjs";

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
const ALLOWED_NOT_EXECUTED_SCHEMA =
  "openburnbar.windows.allowed-not-executed.v1";
const USAGE =
  "usage: --results-directory PATH --minimum-files COUNT --minimum-tests COUNT --maximum-not-executed COUNT [--allowed-not-executed-file PATH]";

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

function xmlAttribute(attributes, name, path) {
  const match = new RegExp(`\\b${name}="([^"]*)"`, "u").exec(attributes);
  if (!match) {
    throw new Error(`TRX result row is missing ${name}: ${path}`);
  }
  return match[1]
    .replaceAll("&quot;", '"')
    .replaceAll("&apos;", "'")
    .replaceAll("&lt;", "<")
    .replaceAll("&gt;", ">")
    .replaceAll("&amp;", "&");
}

function parseCounters(path) {
  const source = readRegularFileSync(path, {
    encoding: "utf8",
    label: "TRX result",
  });
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

  // VSTest's TRX logger records skipped xUnit tests as UnitTestResult
  // outcome="NotExecuted", but some current SDKs still emit
  // Counters notExecuted="0". Count the actual result rows so skipped-test
  // evidence remains fail-closed without rejecting valid hosted-runner TRX.
  const results = [...source.matchAll(/<UnitTestResult\b([^>]*)>/gu)].map(
    (match) => ({
      testName: xmlAttribute(match[1], "testName", path),
      outcome: xmlAttribute(match[1], "outcome", path),
    }),
  );
  if (results.length !== counters.total) {
    throw new Error(
      `TRX total counter does not match test results: ${path} (counter=${counters.total}, results=${results.length})`,
    );
  }

  const outcomeCounts = new Map();
  for (const { outcome } of results) {
    outcomeCounts.set(outcome, (outcomeCounts.get(outcome) ?? 0) + 1);
  }
  for (const [outcome, count] of outcomeCounts) {
    if (!["Passed", "NotExecuted"].includes(outcome)) {
      throw new Error(
        `TRX result has disallowed outcome ${outcome}=${count}: ${path}`,
      );
    }
  }

  const passed = outcomeCounts.get("Passed") ?? 0;
  const notExecuted = outcomeCounts.get("NotExecuted") ?? 0;
  if (passed !== counters.passed || passed !== counters.executed) {
    throw new Error(`TRX executed counters do not match test results: ${path}`);
  }
  if (counters.notExecuted !== 0 && counters.notExecuted !== notExecuted) {
    throw new Error(
      `TRX notExecuted counter does not match test results: ${path}`,
    );
  }
  return {
    ...counters,
    notExecuted,
    notExecutedTests: results
      .filter((result) => result.outcome === "NotExecuted")
      .map((result) => result.testName),
  };
}

export function readAllowedNotExecuted(path) {
  const absolutePath = resolve(path);

  let value;
  try {
    value = JSON.parse(
      readRegularFileSync(absolutePath, {
        encoding: "utf8",
        label: "allowed not-executed file",
      }),
    );
  } catch (error) {
    throw new Error(
      `unable to read allowed not-executed file ${absolutePath}: ${error.message}`,
    );
  }
  if (
    value === null ||
    typeof value !== "object" ||
    Array.isArray(value) ||
    Object.keys(value).sort().join(",") !== "schema,tests" ||
    value.schema !== ALLOWED_NOT_EXECUTED_SCHEMA ||
    !Array.isArray(value.tests)
  ) {
    throw new Error(
      `allowed not-executed file must use ${ALLOWED_NOT_EXECUTED_SCHEMA}`,
    );
  }

  const tests = value.tests.map((testName) => {
    if (typeof testName !== "string" || testName.length === 0) {
      throw new Error(
        "allowed not-executed test names must be non-empty strings",
      );
    }
    return testName;
  });
  if (new Set(tests).size !== tests.length) {
    throw new Error("allowed not-executed test names must be unique");
  }
  if (tests.join("\n") !== [...tests].sort().join("\n")) {
    throw new Error("allowed not-executed test names must be sorted");
  }
  return tests;
}

export function verifyTrxResults(
  resultsDirectory,
  minimumFiles,
  minimumTests,
  maximumNotExecuted,
  allowedNotExecuted = null,
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
  const notExecutedTests = [];
  for (const file of files) {
    const counters = parseCounters(file);
    for (const name of Object.keys(totals)) {
      totals[name] += counters[name];
    }
    notExecutedTests.push(...counters.notExecutedTests);
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
  const sortedNotExecutedTests = notExecutedTests.sort();
  if (allowedNotExecuted !== null) {
    if (!Array.isArray(allowedNotExecuted)) {
      throw new Error("allowed not-executed tests must be an array");
    }
    const allowed = new Set(allowedNotExecuted);
    const unexpected = sortedNotExecutedTests.filter(
      (testName) => !allowed.has(testName),
    );
    if (unexpected.length > 0) {
      throw new Error(
        `TRX evidence contains unreviewed skipped tests: ${[...new Set(unexpected)].join(", ")}`,
      );
    }
  }

  return {
    ok: true,
    resultsDirectory: directory,
    files: files.length,
    ...totals,
    notExecutedTests: sortedNotExecutedTests,
  };
}

function parseArguments(argv) {
  if (![8, 10].includes(argv.length)) {
    throw new Error(USAGE);
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
        "--allowed-not-executed-file",
      ].includes(flag) ||
      values.has(flag)
    ) {
      throw new Error(USAGE);
    }
    values.set(flag, argv[index + 1]);
  }
  for (const required of [
    "--results-directory",
    "--minimum-files",
    "--minimum-tests",
    "--maximum-not-executed",
  ]) {
    if (!values.has(required)) {
      throw new Error(USAGE);
    }
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
    allowedNotExecuted: values.has("--allowed-not-executed-file")
      ? readAllowedNotExecuted(values.get("--allowed-not-executed-file"))
      : null,
  };
}

export function run(argv) {
  const options = parseArguments(argv);
  const summary = verifyTrxResults(
    options.resultsDirectory,
    options.minimumFiles,
    options.minimumTests,
    options.maximumNotExecuted,
    options.allowedNotExecuted,
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
