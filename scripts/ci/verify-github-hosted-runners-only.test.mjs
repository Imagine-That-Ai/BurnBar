#!/usr/bin/env node
/**
 * Contract tests for scripts/ci/verify-github-hosted-runners-only.mjs.
 *
 * CI runs only on free GitHub-hosted runners. These fixtures pin every
 * failure mode of that gate (self-hosted labels, retired fleet/paid labels,
 * the retired pool toggle, the deleted turbo dispatcher, and the consent
 * requirements on the two physical-hardware exception jobs) so a regression
 * cannot silently route jobs back to local or paid runners.
 */

import assert from "node:assert/strict";
import test from "node:test";

import {
  ALLOWED_SELF_HOSTED,
  CONSENT_INPUT,
  RETIRED_DISPATCHER,
  scanWorkflowText,
} from "./verify-github-hosted-runners-only.mjs";

const CLEAN = `name: Example
on: [push]
jobs:
  build:
    runs-on: macos-26
    steps:
      - run: echo hi
`;

const SELF_HOSTED = `name: Example
on: [push]
jobs:
  build:
    runs-on: [self-hosted, macos]
    steps:
      - run: echo hi
`;

const TURBO_GROUP = `name: Example
on: [push]
jobs:
  build:
    runs-on:
      group: burnbar-turbo-ephemeral
    steps:
      - run: echo hi
`;

const PAID_GROUP = `name: Example
on: [push]
jobs:
  build:
    runs-on: \${{ vars.MACOS_GATE_POOL == 'paid' && fromJSON('{"group":"burnbar-ci-paid"}') || 'macos-26' }}
    steps:
      - run: echo hi
`;

const FLEET_LABEL = `name: Example
on: [push]
jobs:
  build:
    runs-on: \${{ fromJSON('["self-hosted","macOS","burnbar-swift"]') }}
    steps:
      - run: echo hi
`;

function exceptionFile({ jobIf = ` && inputs.${CONSENT_INPUT}`, inputDefault = "false" } = {}) {
  return `name: Linux parity
on:
  workflow_dispatch:
    inputs:
      confirm_local_runners:
        required: false
        default: ${inputDefault}
        type: boolean
jobs:
  p16-ipad-producer:
    if: inputs.requirement == 'P-16'${jobIf}
    runs-on:
      - self-hosted
      - macos
  validate:
    if: always()${jobIf}
    runs-on:
      - self-hosted
      - linux
`;
}

test("accepts GitHub-hosted runners", () => {
  assert.deepEqual(scanWorkflowText("example.yml", CLEAN), []);
});

test("rejects self-hosted labels outside the exception", () => {
  const failures = scanWorkflowText("example.yml", SELF_HOSTED);
  assert.equal(failures.length, 1);
  assert.match(failures[0], /self-hosted label in job build/u);
});

test("rejects the retired turbo runner group", () => {
  const failures = scanWorkflowText("example.yml", TURBO_GROUP);
  assert.ok(failures.length >= 1);
  assert.match(failures.join("\n"), /retired local\/paid runner label/u);
});

test("rejects the retired paid group and pool toggle", () => {
  const failures = scanWorkflowText("example.yml", PAID_GROUP);
  assert.match(failures.join("\n"), /retired MACOS_GATE_POOL toggle/u);
  assert.match(failures.join("\n"), /retired local\/paid runner label/u);
});

test("rejects the retired fleet label", () => {
  const failures = scanWorkflowText("example.yml", FLEET_LABEL);
  assert.match(failures.join("\n"), /self-hosted label/u);
  assert.match(failures.join("\n"), /retired local\/paid runner label/u);
});

test("ignores the fleet label inside script paths", () => {
  const fixture = `name: Example
on: [push]
jobs:
  build:
    runs-on: macos-26
    steps:
      - run: ./scripts/test-openburnbar-swift.sh
`;
  assert.deepEqual(scanWorkflowText("example.yml", fixture), []);
});

test("accepts the consent-gated physical-hardware exception", () => {
  assert.deepEqual(
    scanWorkflowText("linux-product-parity.yml", exceptionFile()),
    [],
  );
});

test("rejects the exception when a job loses its consent gate", () => {
  const fixture = exceptionFile().replace(
    "if: always() && inputs.confirm_local_runners",
    "if: always()",
  );
  const failures = scanWorkflowText("linux-product-parity.yml", fixture);
  assert.match(
    failures.join("\n"),
    /allowlisted job validate lost its confirm_local_runners gate/u,
  );
});

test("rejects the exception when consent defaults on", () => {
  const failures = scanWorkflowText(
    "linux-product-parity.yml",
    exceptionFile({ inputDefault: "true" }),
  );
  assert.match(failures.join("\n"), /must default to false/u);
});

test("pins the retired dispatcher name and the exception allowlist", () => {
  assert.equal(RETIRED_DISPATCHER, "burnbar-turbo.yml");
  assert.deepEqual(
    [...ALLOWED_SELF_HOSTED["linux-product-parity.yml"]].sort(),
    ["p16-ipad-producer", "validate"],
  );
  assert.equal(CONSENT_INPUT, "confirm_local_runners");
});
