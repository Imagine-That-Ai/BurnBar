#!/usr/bin/env node
/**
 * Validate the committed MiMo probe fixture and adapter parsing against sample payloads.
 */

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { mimoAdapter } from "../lib/providers/mimo.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const fixturePath = join(__dirname, "fixtures", "mimo-api-probe.fixture.json");
const fixture = JSON.parse(readFileSync(fixturePath, "utf8"));

const encoded = JSON.stringify(fixture);
assert.doesNotMatch(encoded, /tp-[A-Za-z0-9]{8,}/, "fixture must not contain Token Plan keys");
assert.doesNotMatch(encoded, /sk-[A-Za-z0-9]{8,}/, "fixture must not contain PAYG keys");
assert.doesNotMatch(encoded, /Bearer\s+/i, "fixture must not contain bearer tokens");

assert.equal(fixture.schemaVersion, 1);
assert.ok(Array.isArray(fixture.probes) && fixture.probes.length >= 3);
assert.ok(fixture.responseSamples?.["sgp.token_plan.remains"]);

const remainsSample = fixture.responseSamples["sgp.token_plan.remains"];
const refresh = await mimoAdapter.fetchQuota("tp-fixture-key", "fixture", {
  region: "sgp",
  tokenPlanTier: "standard",
  tokenPlanBillingCycle: "monthly",
});

// Force vendor parse path by stubbing fetch for remains only.
const realFetch = globalThis.fetch;
globalThis.fetch = async (input) => {
  const url = typeof input === "string" ? input : input.url;
  if (url.includes("/token_plan/remains")) {
    return new Response(JSON.stringify(remainsSample), {
      status: 200,
      headers: { "content-type": "application/json" },
    });
  }
  return new Response(JSON.stringify({ data: [] }), {
    status: 200,
    headers: { "content-type": "application/json" },
  });
};

const vendorRefresh = await mimoAdapter.fetchQuota("tp-fixture-key", "fixture", {
  region: "sgp",
  tokenPlanTier: "standard",
  tokenPlanBillingCycle: "monthly",
});
globalThis.fetch = realFetch;

assert.equal(vendorRefresh.ok, true);
assert.ok(vendorRefresh.snapshot.buckets.length > 0);
assert.equal(vendorRefresh.snapshot.buckets[0].remaining, 900);

assert.equal(refresh.ok, true);
assert.equal(refresh.snapshot.buckets[0].limit, 200_000_000);

console.log("MiMo probe fixture validation passed");
