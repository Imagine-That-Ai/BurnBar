#!/usr/bin/env node

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

import {
  MEMORY_BOOST_STRIPE_PACKS,
  assertPriceMatches,
  envFileForMode,
  upsertEnvVars,
} from "./prepare-memory-boost-prices.mjs";

assert.deepEqual(
  MEMORY_BOOST_STRIPE_PACKS.map((pack) => [pack.packId, pack.lookupKey, pack.unitAmount, pack.envKey]),
  [
    ["text_1m", "memory_boost_text_1m", 299, "STRIPE_MEMORY_BOOST_TEXT_1M_PRICE_ID"],
    ["text_5m", "memory_boost_text_5m", 999, "STRIPE_MEMORY_BOOST_TEXT_5M_PRICE_ID"],
    ["vision_1m", "memory_boost_vision_1m", 699, "STRIPE_MEMORY_BOOST_VISION_1M_PRICE_ID"],
  ],
);

const catalog = readFileSync(new URL("../../functions/src/usageCuration/catalog.ts", import.meta.url), "utf8");
for (const pack of MEMORY_BOOST_STRIPE_PACKS) {
  assert.match(catalog, new RegExp(`stripeLookupKey: "${pack.lookupKey}"`));
  assert.match(catalog, new RegExp(`listPriceMinor: ${pack.unitAmount}`));
}

assertPriceMatches(
  {
    id: "price_test",
    lookup_key: "memory_boost_text_1m",
    currency: "usd",
    type: "one_time",
    unit_amount: 299,
    active: true,
  },
  MEMORY_BOOST_STRIPE_PACKS[0],
);

assert.throws(
  () =>
    assertPriceMatches(
      {
        id: "price_test",
        lookup_key: "memory_boost_text_1m",
        currency: "usd",
        type: "one_time",
        unit_amount: 1,
        active: true,
      },
      MEMORY_BOOST_STRIPE_PACKS[0],
    ),
  /unit_amount 1 != 299/,
);

const updated = upsertEnvVars(
  "STRIPE_ELDER_WAND_SEARCHES_500_PRICE_ID=price_old\n",
  {
    STRIPE_ELDER_WAND_SEARCHES_500_PRICE_ID: "price_old",
    STRIPE_MEMORY_BOOST_TEXT_1M_PRICE_ID: "price_new",
  },
);
assert.match(updated, /STRIPE_ELDER_WAND_SEARCHES_500_PRICE_ID=price_old/);
assert.match(updated, /STRIPE_MEMORY_BOOST_TEXT_1M_PRICE_ID=price_new/);

assert.ok(envFileForMode(true).endsWith("functions/.env.burnbar.production"));
assert.ok(envFileForMode(false).endsWith("functions/.env.burnbar-staging"));

console.log("Stripe Memory Boost price prep tests passed");
