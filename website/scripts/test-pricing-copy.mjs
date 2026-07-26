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
const wandModule = await read("src/components/WandPricingModule.astro");
const stripAstro = (src) =>
  src.replace(/---[\s\S]*?---/, "").replace(/<style>[\s\S]*?<\/style>/g, "");
const pricingPublicText = stripAstro(pricing) + "\n" + stripAstro(plans) + "\n" + stripAstro(wandModule);
const faq = await read("src/data/faq.ts");
const claims = await read("CLAIMS.md");
const supportMacros = await read("src/data/supportMacros.ts");
const publicPricingCopy = [pricing, plans, wandModule, faq, claims, supportMacros].join("\n");

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
assert.match(
  publicPricingCopy,
  /100 knowledge sources/,
  "Ultra source limit must be public"
);
// CLAIMS.md may reference internal source naming; the rendered surfaces may not.
assert.doesNotMatch(
  [pricing, plans, wandModule, faq, supportMacros].join("\n"),
  /Pensieve/,
  "Internal codename 'Pensieve' must not appear in rendered pricing copy"
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
for (const [tier, cap] of [
  ["Local", 1],
  ["Cloud", 3],
  ["Cloud Pro", 8],
  ["Ultra", 16]
]) {
  assert.match(site, new RegExp(`wandParallelMax:\\s*${cap}`), `${tier} Wand cap must be in site data`);
}
assert.match(publicPricingCopy, /Free opens 1/i, "Free Wand cap must be public");
assert.match(publicPricingCopy, /Cloud opens 3/i, "Cloud Wand cap must be public");
assert.match(publicPricingCopy, /Cloud Pro opens 8/i, "Cloud Pro Wand cap must be public");
assert.match(publicPricingCopy, /Ultra opens 16/i, "Ultra Wand cap must be public");
assert.match(
  publicPricingCopy,
  /Headmaster/i,
  "Headmaster's Wand must be named in public copy"
);
assert.match(
  publicPricingCopy,
  /Pareto/i,
  "Pareto Wand must be named in public copy"
);
assert.match(
  publicPricingCopy,
  /Highest capability/i,
  "Headmaster's tagline must be present"
);
assert.match(
  publicPricingCopy,
  /Best quality per quota/i,
  "Pareto tagline must be present"
);
assert.match(
  publicPricingCopy,
  /Go wider/i,
  "Upgrade persuasion copy must be present"
);
assert.match(
  publicPricingCopy,
  /model tokens still come from/i,
  "Wand module must state provider-token honesty"
);
assert.match(
  publicPricingCopy,
  /Cast.*Work lands|Cast once/i,
  "Wand module must use the Cast to Work lands metaphor"
);
assert.match(
  publicPricingCopy,
  /provider subscriptions or keys/i,
  "Wand copy must say model tokens come from the user's own providers"
);
assert.match(publicPricingCopy, /prepaid before use/i, "top-up copy must say prepaid before use");
assert.doesNotMatch(publicPricingCopy, /14-day|free trial/i, "unsupported trial claims must not be public");
assert.doesNotMatch(
  publicPricingCopy,
  /available on (?:the )?web, App Store, and Google Play/i,
  "Google Play must not be presented as a currently available purchase surface"
);
assert.match(
  publicPricingCopy,
  /Play Store (?:launch is pending|listing|opens)/i,
  "Android purchase copy must disclose that the public Play listing is pending"
);
for (const tier of ["cloud", "cloud_pro", "ultra"]) {
  assert.match(
    plans,
    new RegExp(`href="/subscribe\\?tier=${tier}&(?:amp;)?cadence=monthly"`),
    `${tier} CTA must enter the web subscription flow`
  );
  assert.match(
    plans,
    new RegExp(`data-subscribe-tier="${tier}"`),
    `${tier} CTA must expose its cadence-update contract`
  );
}
assert.match(
  plans,
  /updateSubscriptionLinks\(annual \? "annual" : "monthly"\)/,
  "billing toggle must update paid subscription CTAs to annual cadence"
);
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
