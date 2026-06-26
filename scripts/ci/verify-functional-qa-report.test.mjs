import { strict as assert } from "node:assert";
import test from "node:test";
import { findFunctionalQaFailures, splitMarkdownTableRow, verifyFunctionalQaReport } from "./verify-functional-qa-report.mjs";

const passingReport = `## QA Report

| # | Test Case | App | Persona | Result | Notes |
|---|-----------|-----|---------|--------|-------|
| 1 | Extension mission parity | extension | operator | :white_check_mark: PASS | ok |
`;

test("accepts a passing QA table", () => {
  assert.deepEqual(findFunctionalQaFailures(passingReport), []);
  assert.equal(verifyFunctionalQaReport(passingReport).ok, true);
});

test("parses escaped pipes before the result column", () => {
  const cells = splitMarkdownTableRow("| 1 | Case with escaped \\| pipe | app | operator | :x: FAIL | bad |");
  assert.equal(cells[1], "Case with escaped | pipe");
  assert.equal(cells[4], ":x: FAIL");

  const report = `## QA Report

| # | Test Case | App | Persona | Result | Notes |
|---|-----------|-----|---------|--------|-------|
| 1 | Case with escaped \\| pipe | app | operator | :x: FAIL | bad |
`;
  assert.equal(verifyFunctionalQaReport(report).ok, false);
});

test("catches indented table rows", () => {
  const report = `## QA Report

  | # | Test Case | App | Persona | Result | Notes |
  |---|-----------|-----|---------|--------|-------|
  | 1 | Missing secret | qa | operator | :no_entry: BLOCKED | no credential |
`;
  assert.equal(verifyFunctionalQaReport(report).ok, false);
});

test("catches non-table failure markers outside fenced logs", () => {
  const report = `## QA Report

:no_entry: BLOCKED -- QA report missing before artifact finalization.
`;
  assert.equal(verifyFunctionalQaReport(report).ok, false);
});

test("ignores failure-looking text inside fenced evidence logs", () => {
  const report = `${passingReport}

\`\`\`text
:x: FAIL from a historical log line
\`\`\`
`;
  assert.equal(verifyFunctionalQaReport(report).ok, true);
});

