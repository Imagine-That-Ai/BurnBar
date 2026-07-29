#!/usr/bin/env node

import { test } from "node:test";
import assert from "node:assert/strict";

import {
  parseOsvIgnoredVulnerabilities,
  resolveActiveAdvisoryAllowlist,
} from "./export-active-advisory-allowlist.mjs";

const ID = "GHSA-mh99-v99m-4gvg";
const NPM_ALLOWLIST = {
  [ID]: {
    reason: "fixture reason for the time-boxed exception",
    expires: "2026-08-21",
  },
};
const OSV_CONFIG = `
[[IgnoredVulns]]
id = "${ID}"
ignoreUntil = 2026-08-21T00:00:00Z
# reason: fixture
reason = "fixture reason for the time-boxed exception"
`;

test("parses the OSV ignored-vulnerability policy", () => {
  assert.deepEqual(parseOsvIgnoredVulnerabilities(OSV_CONFIG), [
    {
      id: ID,
      ignoreUntil: "2026-08-21T00:00:00Z",
      reason: "fixture reason for the time-boxed exception",
    },
  ]);
});

test("exports an advisory only while both paired policies are active", () => {
  const osvEntries = parseOsvIgnoredVulnerabilities(OSV_CONFIG);
  assert.deepEqual(
    resolveActiveAdvisoryAllowlist({
      npmAllowlist: NPM_ALLOWLIST,
      osvEntries,
      now: new Date("2026-07-29T00:00:00Z"),
    }),
    [ID],
  );
  assert.deepEqual(
    resolveActiveAdvisoryAllowlist({
      npmAllowlist: NPM_ALLOWLIST,
      osvEntries,
      now: new Date("2026-08-21T00:00:00Z"),
    }),
    [],
  );
});

test("fails closed when the npm and OSV advisory sets drift", () => {
  assert.throws(
    () =>
      resolveActiveAdvisoryAllowlist({
        npmAllowlist: NPM_ALLOWLIST,
        osvEntries: [],
      }),
    /out of sync/u,
  );
});

test("fails closed when paired expiries drift", () => {
  const osvEntries = parseOsvIgnoredVulnerabilities(
    OSV_CONFIG.replace("2026-08-21T00:00:00Z", "2026-08-22T00:00:00Z"),
  );
  assert.throws(
    () =>
      resolveActiveAdvisoryAllowlist({
        npmAllowlist: NPM_ALLOWLIST,
        osvEntries,
      }),
    /expiry mismatch/u,
  );
});

test("fails closed on malformed OSV entries", () => {
  assert.throws(
    () =>
      resolveActiveAdvisoryAllowlist({
        npmAllowlist: NPM_ALLOWLIST,
        osvEntries: [
          { id: ID, ignoreUntil: "not-a-date", reason: "fixture reason" },
        ],
      }),
    /Malformed/u,
  );
});
