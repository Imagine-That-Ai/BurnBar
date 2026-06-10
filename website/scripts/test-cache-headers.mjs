#!/usr/bin/env node
/**
 * test-cache-headers.mjs — caching-policy gate for the marketing hosting config.
 *
 * Repeat visits used to re-download every byte: the catch-all header block in
 * firebase.json said `no-cache, no-store, must-revalidate`, and Firebase
 * Hosting refuses to answer 304 for no-store resources even when the request
 * carries a matching ETag (verified against the live origin: conditional
 * requests returned 200 full-body for `/` but 304 for the cacheable
 * robots.txt under identical hosting). Keeping `no-cache` means HTML is still
 * revalidated on every navigation — never stale after a deploy — but ETag
 * 304s shrink a revisited page from ~40KB to ~1KB.
 *
 * Invariants this gate keeps locked in:
 *   1. The catch-all `**` rule stays `no-cache` and must NOT regress to
 *      `no-store` (no-store forbids 304 revalidation entirely).
 *   2. /link and /hermes/connect (auth flows) DO stay `no-store`.
 *   3. Unhashed public scripts (the js/mjs glob rule) get a short public
 *      max-age (≤ 3600: they are not content-hashed, so a long TTL risks
 *      pairing fresh HTML with stale JS after a deploy) — and the rule sits
 *      BEFORE the _assets rule. Firebase resolves duplicate header keys as
 *      last-match-wins, so appending the JS glob after the _assets rule would
 *      silently downgrade the hashed immutable bundles to the short TTL.
 *   4. The _assets rule stays `immutable` with a one-year max-age.
 *   5. /data/models.json (the published model catalog, fetched by the mobile
 *      app's AssistantModelCatalog remote refresh) gets a short public
 *      max-age, mirroring /downloads/release-metadata.json.
 */
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import assert from "node:assert/strict";

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");
const firebase = JSON.parse(readFileSync(path.join(REPO_ROOT, "firebase.json"), "utf8"));

const marketing = firebase.hosting.find((site) => site.target === "marketing");
assert.ok(marketing, "firebase.json must define the marketing hosting target");
const rules = marketing.headers;

function cacheControl(source) {
  const rule = rules.find((r) => r.source === source);
  assert.ok(rule, `marketing headers must keep a rule for "${source}"`);
  const header = rule.headers.find((h) => h.key === "Cache-Control");
  assert.ok(header, `"${source}" rule must set Cache-Control`);
  return header.value;
}

// 1. Catch-all: revalidate-always, but 304-capable. no-store would make every
//    repeat page view a full-body 200 again.
const catchAll = cacheControl("**");
assert.ok(/\bno-cache\b/.test(catchAll), `"**" Cache-Control must include no-cache (got "${catchAll}")`);
assert.ok(
  !/\bno-store\b/.test(catchAll),
  `"**" Cache-Control must not include no-store — Firebase Hosting refuses ETag 304s on no-store responses (got "${catchAll}")`
);

// 2. Auth-flow pages stay fully uncached.
for (const source of ["/link", "/hermes/connect"]) {
  const value = cacheControl(source);
  assert.ok(/\bno-store\b/.test(value), `"${source}" must keep no-store (got "${value}")`);
}

// 3. Unhashed public scripts: short public TTL, declared BEFORE the _assets
//    immutable rule (last matching rule wins for duplicate header keys).
const jsValue = cacheControl("**/*.@(js|mjs)");
assert.ok(/\bpublic\b/.test(jsValue), `JS glob must be public (got "${jsValue}")`);
const jsMaxAge = Number((jsValue.match(/max-age=(\d+)/) || [])[1]);
assert.ok(
  Number.isFinite(jsMaxAge) && jsMaxAge > 0 && jsMaxAge <= 3600,
  `JS glob max-age must be 1..3600 — these files are not content-hashed (got "${jsValue}")`
);
const jsIndex = rules.findIndex((r) => r.source === "**/*.@(js|mjs)");
const assetsIndex = rules.findIndex((r) => r.source === "**/_assets/**");
assert.ok(assetsIndex !== -1, 'marketing headers must keep the "**/_assets/**" rule');
assert.ok(
  jsIndex < assetsIndex,
  "the **/*.@(js|mjs) rule must come BEFORE **/_assets/** or it silently downgrades the hashed immutable bundles"
);

// 4. Hashed bundles stay immutable.
const assetsValue = cacheControl("**/_assets/**");
assert.ok(
  /\bimmutable\b/.test(assetsValue) && /max-age=31536000/.test(assetsValue),
  `"**/_assets/**" must stay public, max-age=31536000, immutable (got "${assetsValue}")`
);

// 5. Model catalog: cacheable but fresh within minutes.
const modelsValue = cacheControl("/data/models.json");
assert.ok(/\bpublic\b/.test(modelsValue), `/data/models.json must be public (got "${modelsValue}")`);
const modelsMaxAge = Number((modelsValue.match(/max-age=(\d+)/) || [])[1]);
assert.ok(
  Number.isFinite(modelsMaxAge) && modelsMaxAge > 0 && modelsMaxAge <= 3600,
  `/data/models.json max-age must be 1..3600 (got "${modelsValue}")`
);

console.log("cache-headers: 5 invariant groups passed");
