#!/usr/bin/env node
/**
 * @fileoverview Regression tests for the public two-tier pricing copy.
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

const site = await read("src/data/site.ts");
const pricing = await read("src/pages/pricing.astro");
const pricingPublicText = pricing
  .replace(/---[\s\S]*?---/, "")
  .replace(/<style>[\s\S]*?<\/style>/g, "");
const faq = await read("src/data/faq.ts");
const claims = await read("CLAIMS.md");
const supportMacros = await read("src/data/supportMacros.ts");
const publicPricingCopy = [pricing, faq, claims, supportMacros].join("\n");

assert.match(site, /pricing:\s*{/, "site constants must expose a structured pricing catalog");
assert.doesNotMatch(
  site,
  /iapProductId|iapPriceUSD|iapPeriod/,
  "legacy single-IAP fields must not return"
);

for (const expected of [
  "BurnBar Cloud",
  "BurnBar Cloud Pro",
  "com.openburnbar.pro.monthly",
  "com.openburnbar.pro.annual",
  "com.openburnbar.proMax.monthly",
  "com.openburnbar.proMax.annual",
  "com.openburnbar.agentControl.actions100",
  "com.openburnbar.floo.relay50gb"
]) {
  assert.match(
    site + publicPricingCopy,
    new RegExp(expected.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")),
    `${expected} must be present`
  );
}

assert.match(publicPricingCopy, /\$7\.99/, "Cloud monthly price must be public");
assert.match(publicPricingCopy, /\$79\/year|\$79\/yr/, "Cloud annual price must be public");
assert.match(publicPricingCopy, /\$24\.99/, "Cloud Pro monthly price must be public");
assert.match(publicPricingCopy, /\$249\/year|\$249\/yr/, "Cloud Pro annual price must be public");
assert.match(
  publicPricingCopy,
  /500 hosted Agent Control actions/,
  "Cloud Pro hosted-action allowance must be explicit"
);
assert.match(
  publicPricingCopy,
  /50 relay-accounting GB/,
  "Cloud Pro relay allowance must be explicit"
);
assert.match(publicPricingCopy, /prepaid before use/i, "top-up copy must say prepaid before use");
assert.match(
  publicPricingCopy,
  /grandfathered/i,
  "legacy subscription must be framed as grandfathered"
);
assert.doesNotMatch(
  pricingPublicText,
  /Mercury|Computer Use|protocol|codec|transport/i,
  "pricing page must avoid internal implementation language"
);

const pricingPageFourNinetyNine = pricing.match(/\$4\.99/g) ?? [];
assert.equal(
  pricingPageFourNinetyNine.length,
  1,
  "$4.99 may appear only in top-up copy on pricing page"
);

console.log("pricing-copy: two-tier pricing assertions passed");
