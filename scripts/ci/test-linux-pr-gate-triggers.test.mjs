#!/usr/bin/env node

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const workflow = readFileSync(".github/workflows/linux-pr-gate.yml", "utf8");
const nightly = readFileSync(".github/workflows/linux-nightly.yml", "utf8");

test("Linux PR Gate keeps path-filtered pull_request + workflow_dispatch", () => {
  assert.match(workflow, /^on:\n  pull_request:\n/mu);
  assert.match(workflow, /^\s+paths:\n/mu);
  assert.match(workflow, /^  workflow_dispatch:\s*$/mu);
});

test("Linux PR Gate is not on merge_group (MQ must not pay for parity)", () => {
  assert.doesNotMatch(
    workflow,
    /^  merge_group:\s*$/mu,
    "linux-pr-gate.yml must not wake on merge_group; soak stays on linux-nightly.yml",
  );
});

test("Linux nightly soak remains schedule + workflow_dispatch", () => {
  assert.match(nightly, /cron:\s*"17 10 \* \* \*"/u);
  assert.match(nightly, /^  workflow_dispatch:\s*$/mu);
});
