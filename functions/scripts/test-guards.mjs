import assert from "node:assert/strict";

import {
  coerceFirestoreDate,
  errorCode,
  isRecord,
  isStripeCheckoutSession,
  isStripeSubscription,
  isTimestampWithToMillis,
  parseEntitlementBindingDoc,
  parseProvider,
  parseProviderAccountDoc,
  parseProviderAccountSecretRefDoc,
  parseProviderConnectionDoc,
  parseUsageEventDoc,
  recordOrUndefined,
} from "../lib/guards.js";

assert.equal(isRecord({ ok: true }), true);
assert.equal(isRecord(null), false);
assert.equal(isRecord(["nope"]), false);
assert.deepEqual(recordOrUndefined({ a: 1 }), { a: 1 });
assert.equal(recordOrUndefined("nope"), undefined);

assert.equal(parseProvider("mimo"), "mimo");
assert.equal(parseProvider("unknown-provider"), undefined);
assert.equal(errorCode({ code: "already-exists" }), "already-exists");
assert.equal(errorCode({ code: 6 }), 6);
assert.equal(errorCode(new Error("boom")), undefined);

const timestampLike = { toMillis: () => 1234 };
assert.equal(isTimestampWithToMillis(timestampLike), true);
assert.equal(timestampLike.toMillis(), 1234);

assert.equal(parseProviderAccountDoc({
  id: "mimo_default",
  providerID: "mimo",
  label: "Default",
  status: "connected",
  credentialKind: "bearer",
  storageScope: "cloud_refreshable",
  redactedLabel: "mimo_***abcd",
  isDefault: true,
  sortKey: 0,
  schemaVersion: 2,
  createdAt: "2026-05-26T00:00:00.000Z",
  updatedAt: "2026-05-26T00:00:00.000Z",
})?.providerID, "mimo");
assert.equal(parseProviderAccountDoc({ id: "missing-required-fields" }), undefined);

assert.equal(parseProviderAccountSecretRefDoc({
  uid: "user_1",
  providerID: "mimo",
  accountID: "mimo_default",
  secretVersionName: "projects/p/secrets/s/versions/1",
  createdAt: "2026-05-26T00:00:00.000Z",
  updatedAt: "2026-05-26T00:00:00.000Z",
})?.secretVersionName, "projects/p/secrets/s/versions/1");

assert.equal(parseProviderConnectionDoc({
  provider: "mimo",
  status: "connected",
  credentialKind: "bearer",
  redactedLabel: "mimo_***abcd",
  schemaVersion: 1,
})?.provider, "mimo");

assert.equal(parseUsageEventDoc({
  provider: "kimi",
  totalTokens: 42,
  startTime: "2026-06-09T12:00:00.000Z",
})?.totalTokens, 42);

assert.equal(
  parseUsageEventDoc({
    provider: "kimi",
    totalTokens: 42,
    startTime: "2026-06-09T12:00:00.000Z",
  })?.recordedAt,
  "2026-06-09T12:00:00.000Z",
);

assert.equal(
  parseUsageEventDoc({
    provider: "kimi",
    totalTokens: 42,
    startTime: { seconds: 1_718_000_000, nanoseconds: 500_000_000 },
  })?.recordedAt,
  "2024-06-10T06:13:20.500Z",
);

assert.equal(
  coerceFirestoreDate({ seconds: 1_718_000_000, _nanoseconds: 500_000_000 })?.toISOString(),
  "2024-06-10T06:13:20.500Z",
);

assert.equal(isStripeSubscription({ object: "subscription", id: "sub_123" }), true);
assert.equal(isStripeSubscription({ id: "sub_123" }), false);
assert.equal(isStripeCheckoutSession({ object: "checkout.session", id: "cs_123" }), true);
assert.equal(isStripeCheckoutSession({ id: "cs_123" }), false);

assert.equal(parseEntitlementBindingDoc({
  id: "binding",
  uid: "user_1",
  productID: "burnbar_pro_monthly",
  createdAt: "2026-05-26T00:00:00.000Z",
  schemaVersion: 1,
})?.uid, "user_1");

assert.equal(
  parseEntitlementBindingDoc({
    id: "legacy-binding-token",
    uid: "user_1",
    productID: "burnbar_pro_monthly",
    createdAt: "2026-05-26T00:00:00.000Z",
    schemaVersion: 1,
  })?.appAccountToken,
  "legacy-binding-token",
);

console.log("guards tests passed");
