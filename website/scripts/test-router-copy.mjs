#!/usr/bin/env node
/**
 * @fileoverview Regression tests for the public router copy.
 *
 * The product exposes two runtime router modes:
 * Provider-Family Failover and Exact Model Failover. The daily model board is
 * advisory research, not a third failover mode. These tests keep the website
 * from drifting back to "intelligent router" language as a user-facing mode.
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

const routerPage = await read("src/pages/router.astro");
const modeComparison = await read("src/components/ModeComparison.astro");
const faq = await read("src/data/faq.ts");
const dailyArchive = await read("src/pages/router/daily/index.astro");
const hydrator = await read("public/router-rundown-hydrate.js");
const platformMockups = await read("public/platform-mockups.js");

const publicCopy = [routerPage, modeComparison, faq, dailyArchive].join("\n");

assert.match(publicCopy, /Provider-Family Failover/, "provider-family mode must remain named");
assert.match(publicCopy, /Exact Model Failover/, "exact model failover mode must be present");
assert.match(
  publicCopy,
  /daily model board is advisory research|Benchmark signals are <strong>advisory<\/strong>/,
  "daily model board must be framed as advisory"
);
assert.match(
  modeComparison,
  /only exact canonical identity may cross the gate/,
  "mode comparison must include an exact-model proof-gate visual"
);
assert.match(
  routerPage,
  /gpt-5\.4-mini[\s\S]*gpt-5\.4-pro[\s\S]*gpt-5-family[\s\S]*openai:standard/,
  "router page must name rejected similar-model examples"
);
assert.doesNotMatch(
  publicCopy,
  /Intelligent Model Router|Intelligent Router|intelligent mode|intelligent router/i,
  "public copy must not expose intelligent router as a runtime failover mode"
);
assert.doesNotMatch(
  dailyArchive,
  /Daily Router Rundown/,
  "daily archive title should use model-board language"
);
assert.match(
  hydrator,
  /isLocalPreviewHost/,
  "rundown hydrator should avoid noisy local-preview API 404s"
);
assert.match(
  platformMockups,
  /isLocalPreviewHost/,
  "platform mockups should avoid noisy local-preview API 404s"
);

console.log("router-copy: exact failover copy assertions passed");
