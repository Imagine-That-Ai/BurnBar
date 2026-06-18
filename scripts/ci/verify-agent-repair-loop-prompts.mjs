#!/usr/bin/env node
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const repoRoot = resolve(new URL("../..", import.meta.url).pathname);

const workflowExpectations = [
  {
    path: ".github/workflows/cursor-nightly-ci-repair.yml",
    required: [
      "Team handoff protocol:",
      "GitHub-mediated teammates",
      "unresolved review threads",
      "Cursor as responsible",
      "Do not hand it to the Codex nightly repair workflow",
      "Cursor Bugbot, another Cursor autofix",
      "active Codex",
      "repair/check run",
      "do not race it",
      "pushed after this workflow trigger, refresh the",
      "head, diff, reviews, and checks before deciding what remains",
      "Cursor Approval Agent output",
      "Cross-agent receipt",
      "saw, reaction, status, next owner",
      "review/comment/thread ids and commit SHAs",
    ],
  },
  {
    path: ".github/workflows/codex-nightly-ci-repair.yml",
    required: [
      "Team handoff protocol:",
      "GitHub-mediated teammates",
      "unresolved review threads",
      "Cursor Bugbot feedback exists",
      "Cursor Bugbot Autofix",
      "do not race it",
      "pushed after this workflow trigger, refresh the",
      "head, diff, reviews, and checks before deciding what remains",
      "compact loop ledger",
      "Cursor Approval Agent output",
      "Cross-agent receipt",
      "saw, reaction, status, next owner",
      "review/comment/thread ids and commit SHAs",
    ],
  },
];

const failures = [];

for (const workflow of workflowExpectations) {
  const content = readFileSync(resolve(repoRoot, workflow.path), "utf8");
  for (const needle of workflow.required) {
    if (!content.includes(needle)) {
      failures.push(`${workflow.path}: missing ${JSON.stringify(needle)}`);
    }
  }
}

if (failures.length > 0) {
  console.error("Agent repair loop prompt verification failed:");
  for (const failure of failures) {
    console.error(`- ${failure}`);
  }
  process.exit(1);
}

console.log("PASS: Codex and Cursor repair workflows include team loop handoff prompts.");
