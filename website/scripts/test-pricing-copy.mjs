#!/usr/bin/env node
/**
 * @fileoverview Regression tests for the public pricing copy.
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
// The plan cards now render via the shared <PricingPlans /> component, so the
// public copy that used to live inline in pricing.astro lives there too.
const plans = await read("src/components/PricingPlans.astro");
const stripAstro = (src) =>
  src.replace(/---[\s\S]*?---/, "").replace(/<style>[\s\S]*?<\/style>/g, "");
const pricingPublicText = stripAstro(pricing) + "\n" + stripAstro(plans);
const faq = await read("src/data/faq.ts");
const claims = await read("CLAIMS.md");
const supportMacros = await read("src/data/supportMacros.ts");
const publicPricingCopy = [pricing, plans, faq, claims, supportMacros].join("\n");
const cloudTier = site.match(/id: "cloud",[\s\S]*?id: "cloud_pro"/)?.[0] ?? "";
const cloudProTier = site.match(/id: "cloud_pro",[\s\S]*?id: "ultra"/)?.[0] ?? "";
const cloudFaq = faq.match(/id: "burnbar-cloud",[\s\S]*?id: "burnbar-cloud-pro"/)?.[0] ?? "";
const cloudProFaq =
  faq.match(/id: "burnbar-cloud-pro",[\s\S]*?id: "cloud-pro-allowance"/)?.[0] ?? "";

assert.match(site, /pricing:\s*{/, "site constants must expose a structured pricing catalog");
assert.doesNotMatch(
  site,
  /iapProductId|iapPriceUSD|iapPeriod/,
  "legacy single-IAP fields must not return"
);

for (const expected of [
  "OpenBurnBar Local",
  "BurnBar Cloud",
  "BurnBar Cloud Pro",
  "BurnBar Ultra",
  "com.openburnbar.pro.monthly",
  "com.openburnbar.pro.annual",
  "com.openburnbar.proMax.v2.monthly",
  "com.openburnbar.proMax.annual",
  "com.openburnbar.ultra.monthly",
  "com.openburnbar.ultra.annual.v2",
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
assert.match(publicPricingCopy, /\$59\.99/, "Ultra monthly price must be public");
assert.match(publicPricingCopy, /\$599\/year|\$599\/yr/, "Ultra annual price must be public");
assert.doesNotMatch(
  cloudTier + cloudFaq,
  /synced agent memory|Data Vault agent memory, Floo|plus Data Vault agent memory/i,
  "base Cloud must not claim the Cloud Pro Data Vault agent-memory feature"
);
assert.match(
  cloudFaq,
  /Data Vault agent memory starts at Cloud Pro/,
  "base Cloud FAQ must explicitly point agent memory to Cloud Pro"
);
assert.match(
  cloudProTier + cloudProFaq,
  /Data Vault agent memory/,
  "Cloud Pro copy must include the Data Vault agent-memory feature"
);
assert.match(
  cloudProFaq,
  /10 knowledge sources, 50,000 memory chunks, and 1 GB/,
  "Cloud Pro agent-memory limits must be public"
);
assert.match(
  publicPricingCopy,
  /100 Pensieve knowledge sources|100 knowledge sources/,
  "Ultra source limit must be public"
);
assert.match(
  publicPricingCopy,
  /500,000 encrypted memory chunks|500,000 memory chunks/,
  "Ultra chunk limit must be public"
);
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

console.log("pricing-copy: cloud pricing assertions passed");
