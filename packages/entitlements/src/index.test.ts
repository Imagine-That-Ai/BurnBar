import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import test from "node:test";

import {
  APPLE_PRODUCT_IDS,
  BURNBAR_CLOUD_PRO_PRODUCT_ALIASES,
  COMPUTER_USE_PRODUCT_IDS,
  DEFAULT_ENTITLEMENT_CATALOG,
  ENTITLEMENT_DOC_IDS,
  EntitlementCache,
  FIRESTORE_RULES_PRODUCT_ID_ALLOWLISTS,
  GOOGLE_PLAY_PRODUCT_IDS,
  LEGACY_PRODUCT_IDS,
  MEDIA_PRODUCT_IDS,
  PRO_MAX_BUNDLE_MONTHLY_PRODUCT_ID,
  entitlementExpiryMillis,
  evaluateEntitlement,
  isActiveEntitlement,
  productIDsForFeature,
} from "./index.js";

interface CatalogFixture {
  apple: Record<string, string>;
  googlePlay: Record<string, string>;
  media: Record<string, string>;
  computerUse: Record<string, string>;
  legacy: Record<string, string>;
  cloudProAliases: string[];
  firestoreRulesAllowlists: Record<"premium" | "media" | "computerUse", string[]>;
  entitlementDocIds: Record<string, string>;
}

// The fixture lives at <package>/fixtures/product-id-catalog.json. The compiled test
// runs from lib/, so resolve relative to this module then walk up to the package root.
const fixtureUrl = new URL("../fixtures/product-id-catalog.json", import.meta.url);
const fixture = JSON.parse(readFileSync(fileURLToPath(fixtureUrl), "utf8")) as CatalogFixture;

const FAR_FUTURE = "2999-01-01T00:00:00.000Z";
const NOW = Date.parse("2026-06-12T00:00:00.000Z");

test("Apple product-ID catalog matches the canonical fixture", () => {
  assert.deepEqual({ ...APPLE_PRODUCT_IDS }, fixture.apple);
});

test("Google Play product-ID catalog matches the canonical fixture", () => {
  assert.deepEqual({ ...GOOGLE_PLAY_PRODUCT_IDS }, fixture.googlePlay);
});

test("Cloud Pro product-ID aliases match the canonical fixture", () => {
  assert.deepEqual([...BURNBAR_CLOUD_PRO_PRODUCT_ALIASES], fixture.cloudProAliases);
});

test("media / computer-use / legacy product-ID catalogs match the canonical fixture", () => {
  assert.deepEqual({ ...MEDIA_PRODUCT_IDS }, fixture.media);
  assert.deepEqual({ ...COMPUTER_USE_PRODUCT_IDS }, fixture.computerUse);
  assert.deepEqual({ ...LEGACY_PRODUCT_IDS }, fixture.legacy);
});

test("firestore.rules allowlists match the canonical fixture (order included)", () => {
  assert.deepEqual(
    {
      premium: [...FIRESTORE_RULES_PRODUCT_ID_ALLOWLISTS.premium],
      media: [...FIRESTORE_RULES_PRODUCT_ID_ALLOWLISTS.media],
      computerUse: [...FIRESTORE_RULES_PRODUCT_ID_ALLOWLISTS.computerUse],
    },
    fixture.firestoreRulesAllowlists,
  );
});

test("firestore.rules allowlists are composed from the canonical constants", () => {
  const { premium, media, computerUse } = FIRESTORE_RULES_PRODUCT_ID_ALLOWLISTS;
  assert.equal(premium[0], APPLE_PRODUCT_IDS.hostedQuota);
  assert.equal(premium[1], LEGACY_PRODUCT_IDS.hostedQuotaOriginalMonthly);
  assert.equal(media[0], MEDIA_PRODUCT_IDS.hostedMediaSyncMonthly);
  assert.equal(computerUse[0], COMPUTER_USE_PRODUCT_IDS.computerUseMonthly);
  assert.equal(computerUse[1], COMPUTER_USE_PRODUCT_IDS.hostedComputerUseSyncMonthly);
  // Every list carries the shared proMax/Ultra tail (bundle alias included).
  for (const list of [premium, media, computerUse]) {
    for (const id of [
      PRO_MAX_BUNDLE_MONTHLY_PRODUCT_ID,
      APPLE_PRODUCT_IDS.proMaxMonthly,
      APPLE_PRODUCT_IDS.proMaxAnnual,
      APPLE_PRODUCT_IDS.ultraMonthly,
      GOOGLE_PLAY_PRODUCT_IDS.ultraAnnual,
      APPLE_PRODUCT_IDS.ultraAnnual,
    ]) {
      assert.equal((list as readonly string[]).includes(id), true, `allowlist should carry ${id}`);
    }
  }
});

test("entitlement document IDs match the canonical fixture", () => {
  assert.deepEqual({ ...ENTITLEMENT_DOC_IDS }, fixture.entitlementDocIds);
});

test("default catalog is assembled from the canonical product-ID constants", () => {
  assert.equal(DEFAULT_ENTITLEMENT_CATALOG.hostedQuotaProductID, APPLE_PRODUCT_IDS.hostedQuota);
  assert.equal(DEFAULT_ENTITLEMENT_CATALOG.burnBarProProductID, APPLE_PRODUCT_IDS.proMonthly);
  assert.equal(DEFAULT_ENTITLEMENT_CATALOG.burnBarProMaxProductID, APPLE_PRODUCT_IDS.proMaxMonthly);
  assert.equal(DEFAULT_ENTITLEMENT_CATALOG.burnBarUltraProductID, APPLE_PRODUCT_IDS.ultraMonthly);
  assert.equal(DEFAULT_ENTITLEMENT_CATALOG.googlePlayCloudProMonthlyProductID, GOOGLE_PLAY_PRODUCT_IDS.cloudProMonthly);
  assert.equal(DEFAULT_ENTITLEMENT_CATALOG.googlePlayUltraMonthlyProductID, GOOGLE_PLAY_PRODUCT_IDS.ultraMonthly);
});

test("hostedQuota feature accepts only the hosted-quota SKU", () => {
  const ids = productIDsForFeature("hostedQuota");
  assert.equal(ids.has(APPLE_PRODUCT_IDS.hostedQuota), true);
  assert.equal(ids.has(APPLE_PRODUCT_IDS.proMonthly), false);
});

test("premium feature accepts every paid SKU including aliases", () => {
  const ids = productIDsForFeature("premium");
  for (const id of [
    APPLE_PRODUCT_IDS.hostedQuota,
    APPLE_PRODUCT_IDS.proMonthly,
    APPLE_PRODUCT_IDS.proAnnual,
    APPLE_PRODUCT_IDS.proMaxMonthly,
    APPLE_PRODUCT_IDS.proMaxAnnual,
    GOOGLE_PLAY_PRODUCT_IDS.cloudProMonthly,
    ...BURNBAR_CLOUD_PRO_PRODUCT_ALIASES,
  ]) {
    assert.equal(ids.has(id), true, `premium should grant ${id}`);
  }
});

test("cloudPro feature accepts proMax SKUs and aliases but not plain Pro", () => {
  const ids = productIDsForFeature("cloudPro");
  assert.equal(ids.has(APPLE_PRODUCT_IDS.proMaxMonthly), true);
  assert.equal(ids.has(GOOGLE_PLAY_PRODUCT_IDS.cloudProMonthly), true);
  assert.equal(ids.has("com.openburnbar.proMax.bundle.monthly"), true);
  assert.equal(ids.has(APPLE_PRODUCT_IDS.proMonthly), false);
});

test("ultra feature accepts only the Ultra SKUs", () => {
  const ids = productIDsForFeature("ultra");
  assert.equal(ids.has(APPLE_PRODUCT_IDS.ultraMonthly), true);
  assert.equal(ids.has(APPLE_PRODUCT_IDS.ultraAnnual), true);
  assert.equal(ids.has(GOOGLE_PLAY_PRODUCT_IDS.ultraMonthly), true);
  assert.equal(ids.has(APPLE_PRODUCT_IDS.proMaxMonthly), false);
});

test("isActiveEntitlement requires active flag, matching SKU, and future expiry", () => {
  assert.equal(
    isActiveEntitlement(
      { active: true, productID: APPLE_PRODUCT_IDS.proMonthly, expiresAt: FAR_FUTURE },
      "premium",
      { nowMs: NOW },
    ),
    true,
  );
  // inactive flag
  assert.equal(
    isActiveEntitlement(
      { active: false, productID: APPLE_PRODUCT_IDS.proMonthly, expiresAt: FAR_FUTURE },
      "premium",
      { nowMs: NOW },
    ),
    false,
  );
  // wrong SKU for the feature
  assert.equal(
    isActiveEntitlement(
      { active: true, productID: APPLE_PRODUCT_IDS.proMonthly, expiresAt: FAR_FUTURE },
      "ultra",
      { nowMs: NOW },
    ),
    false,
  );
  // expired
  assert.equal(
    isActiveEntitlement(
      { active: true, productID: APPLE_PRODUCT_IDS.proMonthly, expiresAt: "2020-01-01T00:00:00.000Z" },
      "premium",
      { nowMs: NOW },
    ),
    false,
  );
  // missing expiry => fail closed
  assert.equal(
    isActiveEntitlement({ active: true, productID: APPLE_PRODUCT_IDS.proMonthly }, "premium", { nowMs: NOW }),
    false,
  );
});

test("entitlementExpiryMillis resolves the union of every consumer's accepted shapes", () => {
  const ts = { toMillis: () => 1_700_000_000_000 };
  // expireAt as Firestore Timestamp wins over the expiresAt mirror (functions + relay).
  assert.equal(entitlementExpiryMillis({ expireAt: ts, expiresAt: FAR_FUTURE }), 1_700_000_000_000);
  // expireAt as a native Date (hosted-mcp dateFromRaw path).
  assert.equal(entitlementExpiryMillis({ expireAt: new Date(NOW) }), NOW);
  // expireAt as an ISO string (hosted-mcp passed `expireAt ?? expiresAt` through one coercer).
  assert.equal(entitlementExpiryMillis({ expireAt: "2026-06-12T00:00:00.000Z" }), NOW);
  // expiresAt as an ISO string (all three).
  assert.equal(entitlementExpiryMillis({ expiresAt: "2026-06-12T00:00:00.000Z" }), NOW);
  // expiresAt as a native Date.
  assert.equal(entitlementExpiryMillis({ expiresAt: new Date(NOW) }), NOW);
  // a non-parseable expireAt falls through to a valid expiresAt mirror.
  assert.equal(entitlementExpiryMillis({ expireAt: 123, expiresAt: "2026-06-12T00:00:00.000Z" }), NOW);
  assert.equal(Number.isNaN(entitlementExpiryMillis({})), true);
  assert.equal(Number.isNaN(entitlementExpiryMillis(undefined)), true);
  assert.equal(Number.isNaN(entitlementExpiryMillis({ expiresAt: "not-a-date" })), true);
});

test("evaluateEntitlement reports the resolved expiry alongside the active flag", () => {
  const result = evaluateEntitlement(
    { active: true, productID: APPLE_PRODUCT_IDS.ultraMonthly, expiresAt: FAR_FUTURE },
    "ultra",
    { nowMs: NOW },
  );
  assert.equal(result.active, true);
  assert.equal(result.expiresAtMs, Date.parse(FAR_FUTURE));
});

test("EntitlementCache honors injected clock and per-key TTL", () => {
  let clock = 1_000;
  const cache = new EntitlementCache<string>({ now: () => clock });
  cache.set("uid-1", "active", 2_000);
  assert.equal(cache.get("uid-1"), "active");
  clock = 2_000; // expiresAtMs <= now => expired
  assert.equal(cache.get("uid-1"), undefined);
});
