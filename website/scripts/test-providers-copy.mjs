#!/usr/bin/env node
/**
 * @fileoverview Regression tests for the public providers matrix copy (E20a / P25).
 *
 * Pins every factual claim on website/src/pages/providers.astro to its code source:
 * provider counts, names, categories, routing model preservation, and confidence vocabulary.
 */

import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, "..");

async function read(relativePath) {
  return readFile(path.join(ROOT, relativePath), "utf8");
}

const providersPage = await read("src/pages/providers.astro");
const providersData = await read("src/data/providers.ts");

// 1. Dynamic count binding: page must bind primaryCount to PROVIDERS_PRIMARY.length
assert.match(
  providersPage,
  /const primaryCount = PROVIDERS_PRIMARY\.length;/,
  "providers.astro must derive primaryCount dynamically from PROVIDERS_PRIMARY.length"
);
assert.match(
  providersPage,
  /\{primaryCount\}\s+providers ship with live data\./,
  "Headline must reflect dynamic primaryCount"
);

// 2. Confidence vocabulary pinned to the 3-state enum
for (const key of ["exact", "estimated", "unavailable"]) {
  assert.match(
    providersData,
    new RegExp(`export type Confidence = [^;]*"${key}"`),
    `providers.ts Confidence type must declare "${key}"`
  );
  assert.match(
    providersPage,
    new RegExp(`"${key}"`),
    `providers.astro must include confidence key "${key}"`
  );
}

// 3. Core primary providers pinned
const requiredProviders = [
  "claude-code",
  "codex",
  "openai",
  "copilot",
  "cursor",
  "cursor-agent",
  "factory",
  "minimax",
  "warp"
];

for (const pid of requiredProviders) {
  assert.match(
    providersData,
    new RegExp(`id:\\s*"${pid}"`),
    `providers.ts must define provider "${pid}"`
  );
}

// 4. Exact Model Failover & Account Routing Invariants on providers.astro
assert.match(
  providersPage,
  /Routing is per-account, not per-provider\./,
  "providers.astro must state that routing is per-account, not per-provider"
);
assert.match(
  providersPage,
  /Failover only picks accounts that carry your exact model\./,
  "providers.astro must assert model identity preservation during failover"
);
assert.match(
  providersPage,
  /structured 503/,
  "providers.astro must assert structured 503 fallback when no row proves model ID"
);
assert.match(
  providersPage,
  /Accounts have their own clocks and quotas\./,
  "providers.astro must document independent account clocks and quotas"
);

// 5. Detection-only section
assert.match(
  providersPage,
  /Vendors that don't expose data\./,
  "providers.astro must document detection-only vendors"
);

console.log("providers-copy: all provider matrix facts and routing claims verified");
