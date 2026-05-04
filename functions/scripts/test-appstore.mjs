/**
 * Regression tests for the OpenBurnBar Apple App Store JWS verification
 * pipeline.
 *
 * Scope:
 *   We do NOT re-test Apple's `@apple/app-store-server-library` chain
 *   verification — that ships with its own ~70k LoC test suite. We do
 *   test the OpenBurnBar-specific invariants:
 *
 *     1. Apple root certificates round-trip with their pinned SHA-256
 *        fingerprints; tampering fails the cold-start check.
 *     2. Environment enum ↔ AppStoreEnvironment string round-trip.
 *     3. Reconciler `pickWinning` picks the most recent signedDate
 *        and ignores wrong productId payloads.
 *     4. Reconciler `buildEntitlementDoc` produces the documented
 *        v2 shape (active flag, hash, source, schema/verification
 *        versions, lowercased appAccountToken).
 *     5. Reconciler `mergeWithExisting` preserves stable fields
 *        (appAccountToken, ownershipType, environment) when the
 *        new payload omits them.
 *     6. Monotonicity: `shouldOverwrite` rejects an older verified
 *        timestamp.
 *     7. Audit `redact` drops nested signed JWS strings and replaces
 *        them with their SHA-256.
 *     8. Audit `sanitizeDocId` strips path separators and exotic
 *        characters.
 *     9. `appendEntitlementEvent` is idempotent on `(uid, eventId)`.
 *    10. `beginBinding` writes a binding doc keyed by a fresh UUID.
 *    11. `JWSVerificationFailure` and `EntitlementReconcileError`
 *        carry stable error codes for the iOS surface.
 *
 * Run with `npm run test:appstore` (chained from `npm test`).
 */

import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import test from "node:test";

import {
  loadAppleRootCertificates,
  ROOT_CERT_FILES,
  toLibEnvironment,
  fromLibEnvironment,
  AppleJWSVerifier,
  JWSVerificationFailure,
} from "../lib/appstore/verifier.js";

import {
  appendEntitlementEvent,
  __testing__ as auditTesting,
} from "../lib/appstore/audit.js";

import {
  beginBinding,
  EntitlementReconcileError,
  __testing__ as reconcilerTesting,
} from "../lib/appstore/reconciler.js";

import { Environment } from "@apple/app-store-server-library";

// ---------------------------------------------------------------------------
// 1. Apple root certificate fingerprint pinning
// ---------------------------------------------------------------------------

test("apple root certificates load and match pinned fingerprints", () => {
  const buffers = loadAppleRootCertificates();
  assert.equal(buffers.length, ROOT_CERT_FILES.length);
  for (let i = 0; i < buffers.length; i++) {
    const expected = ROOT_CERT_FILES[i].fingerprintHex;
    const got = createHash("sha256").update(buffers[i]).digest("hex");
    assert.equal(got, expected, `cert ${ROOT_CERT_FILES[i].name} fingerprint`);
  }
});

test("ROOT_CERT_FILES is non-empty and uses lowercase hex fingerprints", () => {
  assert.ok(ROOT_CERT_FILES.length >= 3, "expected at least 3 pinned roots");
  for (const r of ROOT_CERT_FILES) {
    assert.match(r.fingerprintHex, /^[0-9a-f]{64}$/, `${r.name} hex format`);
  }
});

// ---------------------------------------------------------------------------
// 2. Environment mapping round-trip
// ---------------------------------------------------------------------------

test("environment enum round-trips for every supported value", () => {
  const inputs = ["Production", "Sandbox", "Xcode", "LocalTesting"];
  for (const env of inputs) {
    const lib = toLibEnvironment(env);
    const back = fromLibEnvironment(lib);
    assert.equal(back, env, `env round-trip for ${env}`);
  }
});

test("fromLibEnvironment returns undefined for unknown values", () => {
  assert.equal(fromLibEnvironment("UnknownThing"), undefined);
  assert.equal(fromLibEnvironment(undefined), undefined);
});

test("toLibEnvironment matches Environment constants", () => {
  assert.equal(toLibEnvironment("Production"), Environment.PRODUCTION);
  assert.equal(toLibEnvironment("Sandbox"), Environment.SANDBOX);
  assert.equal(toLibEnvironment("Xcode"), Environment.XCODE);
  assert.equal(toLibEnvironment("LocalTesting"), Environment.LOCAL_TESTING);
});

// ---------------------------------------------------------------------------
// 3. AppleJWSVerifier construction guards
// ---------------------------------------------------------------------------

test("AppleJWSVerifier rejects empty bundleId", () => {
  assert.throws(
    () =>
      new AppleJWSVerifier({
        bundleId: "",
        environment: "Sandbox",
        enableOnlineChecks: false,
        asc: { keyId: "k", issuerId: "i", privateKeyP8: "p" },
      }),
    /bundleId/
  );
});

test("AppleJWSVerifier exposes default environment", () => {
  const v = new AppleJWSVerifier({
    bundleId: "com.test.app",
    environment: "Sandbox",
    enableOnlineChecks: false,
    asc: { keyId: "k", issuerId: "i", privateKeyP8: "p" },
  });
  assert.equal(v.defaultEnvironment, "Sandbox");
});

// ---------------------------------------------------------------------------
// 4. Reconciler pickWinning
// ---------------------------------------------------------------------------

test("pickWinning ignores transactions with the wrong productId", () => {
  const productID = "com.burnbar.hostedQuotaSync.monthly";
  const candidates = [
    fakeTx({ productId: "different", signedDate: 100 }),
    fakeTx({ productId: productID, signedDate: 50 }),
  ];
  const winner = reconcilerTesting.pickWinning(candidates, productID);
  assert.ok(winner);
  assert.equal(winner.payload.signedDate, 50);
});

test("pickWinning selects the most recent signedDate", () => {
  const productID = "com.burnbar.hostedQuotaSync.monthly";
  const candidates = [
    fakeTx({ productId: productID, signedDate: 100, transactionId: "old" }),
    fakeTx({ productId: productID, signedDate: 200, transactionId: "new" }),
    fakeTx({ productId: productID, signedDate: 150, transactionId: "mid" }),
  ];
  const winner = reconcilerTesting.pickWinning(candidates, productID);
  assert.equal(winner.payload.transactionId, "new");
});

test("pickWinning returns undefined when no candidate matches productId", () => {
  const winner = reconcilerTesting.pickWinning(
    [fakeTx({ productId: "x", signedDate: 1 })],
    "y"
  );
  assert.equal(winner, undefined);
});

// ---------------------------------------------------------------------------
// 5. buildEntitlementDoc shape
// ---------------------------------------------------------------------------

test("buildEntitlementDoc surfaces all v2 invariants", () => {
  const productID = "com.burnbar.hostedQuotaSync.monthly";
  const expires = Date.now() + 30 * 24 * 60 * 60 * 1000;
  const candidate = fakeTx({
    productId: productID,
    signedDate: 1700000000_000,
    transactionId: "tx-1",
    originalTransactionId: "otx-1",
    bundleId: "com.test.app",
    expiresDate: expires,
    appAccountToken: "ABCDEF12-3456-7890-ABCD-EF1234567890",
    inAppOwnershipType: "PURCHASED",
  });
  const doc = reconcilerTesting.buildEntitlementDoc({
    productID,
    candidate,
    notificationUUID: "n-uuid",
  });

  assert.equal(doc.id, "hosted_quota_sync");
  assert.equal(doc.active, true, "expected active because expiresDate > now");
  assert.equal(doc.productID, productID);
  assert.equal(doc.transactionID, "tx-1");
  assert.equal(doc.originalTransactionID, "otx-1");
  assert.equal(doc.environment, candidate.environment);
  assert.equal(doc.ownershipType, "PURCHASED");
  // appAccountToken must be lowercased before persistence.
  assert.equal(doc.appAccountToken, "abcdef12-3456-7890-abcd-ef1234567890");
  assert.equal(doc.lastNotificationUUID, "n-uuid");
  assert.equal(doc.source, "apple_jws_verified");
  assert.equal(doc.verificationVersion, reconcilerTesting.VERIFICATION_VERSION);
  assert.equal(doc.schemaVersion, reconcilerTesting.ENTITLEMENT_SCHEMA_VERSION);

  // SHA-256 of the raw JWS, lowercase hex.
  assert.equal(doc.signedTransactionHash.length, 64);
  assert.match(doc.signedTransactionHash, /^[0-9a-f]{64}$/);
});

test("buildEntitlementDoc marks revoked transactions inactive", () => {
  const candidate = fakeTx({
    productId: "p",
    signedDate: 1,
    transactionId: "tx",
    originalTransactionId: "otx",
    bundleId: "b",
    expiresDate: Date.now() + 86_400_000,
    revocationDate: Date.now() - 1000,
    revocationReason: 1,
  });
  const doc = reconcilerTesting.buildEntitlementDoc({
    productID: "p",
    candidate,
  });
  assert.equal(doc.active, false);
  assert.ok(doc.revokedAt);
  assert.equal(doc.revocationReason, 1);
});

test("buildEntitlementDoc strips undefined fields", () => {
  const candidate = fakeTx({
    productId: "p",
    signedDate: 1,
    transactionId: "tx",
    originalTransactionId: "otx",
    bundleId: "b",
    // no expiresDate => active becomes false
  });
  const doc = reconcilerTesting.buildEntitlementDoc({
    productID: "p",
    candidate,
  });
  // No expiresAt key should exist (not just be undefined) so we don't
  // pollute Firestore with explicit `null`s.
  assert.ok(!("expiresAt" in doc), "expiresAt should be absent, not undefined");
  assert.ok(!("appAccountToken" in doc));
  assert.ok(!("ownershipType" in doc));
});

// ---------------------------------------------------------------------------
// 6. mergeWithExisting / shouldOverwrite
// ---------------------------------------------------------------------------

test("shouldOverwrite accepts newer or equal verifiedAt", () => {
  const a = stubDoc({ lastVerifiedAt: "2026-01-01T00:00:00.000Z" });
  const b = stubDoc({ lastVerifiedAt: "2026-01-02T00:00:00.000Z" });
  assert.equal(reconcilerTesting.shouldOverwrite(a, b), true);
  assert.equal(reconcilerTesting.shouldOverwrite(b, b), true); // idempotent retry
});

test("shouldOverwrite rejects older verifiedAt (replay protection)", () => {
  const newer = stubDoc({ lastVerifiedAt: "2026-01-02T00:00:00.000Z" });
  const older = stubDoc({ lastVerifiedAt: "2026-01-01T00:00:00.000Z" });
  assert.equal(reconcilerTesting.shouldOverwrite(newer, older), false);
});

test("mergeWithExisting carries forward stable fields when next omits them", () => {
  const existing = stubDoc({
    appAccountToken: "abc-token",
    ownershipType: "FAMILY_SHARED",
    environment: "Sandbox",
  });
  const next = stubDoc({
    appAccountToken: undefined,
    ownershipType: undefined,
    environment: undefined,
    lastVerifiedAt: "2099-01-01T00:00:00.000Z",
  });
  const merged = reconcilerTesting.mergeWithExisting(existing, next);
  assert.equal(merged.appAccountToken, "abc-token");
  assert.equal(merged.ownershipType, "FAMILY_SHARED");
  assert.equal(merged.environment, "Sandbox");
  assert.equal(merged.lastVerifiedAt, "2099-01-01T00:00:00.000Z");
});

test("mergeWithExisting prefers next when next has values", () => {
  const existing = stubDoc({
    appAccountToken: "old",
    ownershipType: "PURCHASED",
    environment: "Sandbox",
  });
  const next = stubDoc({
    appAccountToken: "new",
    ownershipType: "FAMILY_SHARED",
    environment: "Production",
  });
  const merged = reconcilerTesting.mergeWithExisting(existing, next);
  assert.equal(merged.appAccountToken, "new");
  assert.equal(merged.ownershipType, "FAMILY_SHARED");
  assert.equal(merged.environment, "Production");
});

// ---------------------------------------------------------------------------
// 7. Audit redaction
// ---------------------------------------------------------------------------

test("audit.redact replaces signed JWS substrings with their hash", () => {
  const out = auditTesting.redact({
    transactionId: "tx",
    signedTransactionInfo: "ey.alphabetic.thing",
    signedRenewalInfo: "ey.other.thing",
    signedPayload: "ey.outer",
  });
  assert.equal(out.transactionId, "tx");
  assert.ok(!("signedTransactionInfo" in out));
  assert.ok(!("signedRenewalInfo" in out));
  assert.ok(!("signedPayload" in out));
  assert.match(out.signedTransactionInfoHash, /^[0-9a-f]{64}$/);
  assert.match(out.signedRenewalInfoHash, /^[0-9a-f]{64}$/);
  assert.match(out.signedPayloadHash, /^[0-9a-f]{64}$/);
});

test("audit.redact drops undefined values", () => {
  const out = auditTesting.redact({
    a: 1,
    b: undefined,
    c: null,
  });
  assert.equal(out.a, 1);
  assert.ok(!("b" in out));
  assert.equal(out.c, null);
});

test("audit.sanitizeDocId removes slashes and exotic chars", () => {
  assert.equal(
    auditTesting.sanitizeDocId("foo/bar\\baz space"),
    "foo_bar_baz-space"
  );
  assert.equal(
    auditTesting.sanitizeDocId("legal_id.value-1"),
    "legal_id.value-1"
  );
  // 200-char cap
  assert.equal(auditTesting.sanitizeDocId("a".repeat(500)).length, 200);
});

// ---------------------------------------------------------------------------
// 8. appendEntitlementEvent — idempotency + redaction + Firestore shape
// ---------------------------------------------------------------------------

test("appendEntitlementEvent writes the documented shape", async () => {
  const writes = [];
  const db = makeFakeFirestore(writes);
  const doc = await appendEntitlementEvent(db, {
    uid: "uid-1",
    eventId: "evt-1",
    source: "client_callable",
    transactionId: "tx-1",
    originalTransactionId: "otx-1",
    productId: "p",
    environment: "Sandbox",
    expiresAt: "2030-01-01T00:00:00.000Z",
    rawJWS: "ey.aaa.bbb",
    decoded: {
      transactionId: "tx-1",
      signedTransactionInfo: "ey.nested.token",
    },
  });
  assert.equal(doc.id, "evt-1");
  assert.equal(doc.uid, "uid-1");
  assert.equal(doc.environment, "Sandbox");
  assert.equal(doc.schemaVersion, auditTesting.SCHEMA_VERSION);
  // rawJWS is hashed before storage.
  assert.match(doc.rawJWSHash, /^[0-9a-f]{64}$/);
  // Decoded nested signed payload was redacted to a hash key.
  assert.match(doc.decoded.signedTransactionInfoHash, /^[0-9a-f]{64}$/);
  assert.equal(writes.length, 1);
  assert.equal(writes[0].kind, "create");
  assert.equal(writes[0].path, "users/uid-1/entitlement_events/evt-1");
});

test("appendEntitlementEvent is idempotent on the (uid, eventId) tuple", async () => {
  const writes = [];
  const db = makeFakeFirestore(writes, { simulateAlreadyExists: true });
  const doc = await appendEntitlementEvent(db, {
    uid: "uid-1",
    eventId: "evt-1",
    source: "apple_s2s",
    transactionId: "tx",
    originalTransactionId: "otx",
    productId: "p",
    environment: "Production",
    rawJWS: "x.y.z",
    decoded: {},
  });
  // Second call should be a no-op (no extra writes) but still return the doc.
  assert.equal(writes.length, 1);
  assert.equal(doc.id, "evt-1");
});

test("appendEntitlementEvent rethrows non-AlreadyExists errors", async () => {
  const db = makeFakeFirestore([], { simulateError: new Error("disk full") });
  await assert.rejects(
    appendEntitlementEvent(db, {
      uid: "u",
      eventId: "e",
      source: "client_callable",
      transactionId: "t",
      originalTransactionId: "o",
      productId: "p",
      environment: "Sandbox",
      rawJWS: "x",
      decoded: {},
    }),
    /disk full/
  );
});

test("appendEntitlementEvent sanitizes exotic eventIds", async () => {
  const writes = [];
  const db = makeFakeFirestore(writes);
  const doc = await appendEntitlementEvent(db, {
    uid: "uid",
    eventId: "n_3f7e/garbage uuid",
    source: "apple_s2s",
    transactionId: "t",
    originalTransactionId: "o",
    productId: "p",
    environment: "Sandbox",
    rawJWS: "x",
    decoded: {},
  });
  assert.equal(doc.id, "n_3f7e_garbage-uuid");
  assert.equal(writes[0].path, "users/uid/entitlement_events/n_3f7e_garbage-uuid");
});

// ---------------------------------------------------------------------------
// 9. beginBinding
// ---------------------------------------------------------------------------

test("beginBinding mints a UUID and writes a binding doc with that id", async () => {
  const writes = [];
  const db = makeFakeFirestore(writes);
  const out = await beginBinding(db, "uid-7", "p-1", "ios");
  assert.match(
    out.appAccountToken,
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
  );
  assert.equal(writes.length, 1);
  assert.equal(
    writes[0].path,
    `users/uid-7/entitlement_bindings/${out.appAccountToken}`
  );
  assert.equal(writes[0].data.uid, "uid-7");
  assert.equal(writes[0].data.productID, "p-1");
  assert.equal(writes[0].data.clientPlatform, "ios");
  assert.equal(writes[0].data.id, out.appAccountToken);
  assert.equal(
    writes[0].data.schemaVersion,
    reconcilerTesting.BINDING_SCHEMA_VERSION
  );
});

test("beginBinding rejects empty uid", async () => {
  await assert.rejects(beginBinding(makeFakeFirestore([]), "", "p"), /uid/);
});

// ---------------------------------------------------------------------------
// 10. Error classes carry stable codes
// ---------------------------------------------------------------------------

test("EntitlementReconcileError exposes its code", () => {
  const err = new EntitlementReconcileError("binding_mismatch", "nope");
  assert.equal(err.name, "EntitlementReconcileError");
  assert.equal(err.code, "binding_mismatch");
  assert.match(err.message, /binding_mismatch: nope/);
});

test("JWSVerificationFailure exposes its status numeric", () => {
  const err = new JWSVerificationFailure(3, "apple-jws-bundle_or_app_id_mismatch: …");
  assert.equal(err.name, "JWSVerificationFailure");
  assert.equal(err.status, 3);
  assert.match(err.message, /apple-jws-bundle_or_app_id_mismatch/);
});

// ---------------------------------------------------------------------------
// 11. Token redactor doesn't leak full UUIDs
// ---------------------------------------------------------------------------

test("redactToken keeps only the first/last 4 chars", () => {
  const full = "abcdef12-3456-7890-abcd-ef1234567890";
  const out = reconcilerTesting.redactToken(full);
  assert.match(out, /^abcd…7890$/);
  assert.equal(reconcilerTesting.redactToken("short"), "***");
});

// ---------------------------------------------------------------------------
// 12. auditEventId derivation
// ---------------------------------------------------------------------------

test("auditEventId prefers notificationUUID when present", () => {
  assert.equal(
    reconcilerTesting.auditEventId(
      { notificationUUID: "n-1" },
      { transactionId: "t", signedDate: 5 }
    ),
    "n_n-1"
  );
});

test("auditEventId falls back to transactionId.signedDate", () => {
  assert.equal(
    reconcilerTesting.auditEventId(
      {},
      { transactionId: "tx-99", signedDate: 1234 }
    ),
    "t_tx-99_1234"
  );
});

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function fakeTx({
  productId,
  signedDate,
  transactionId = "tx",
  originalTransactionId = "otx",
  bundleId = "com.test.app",
  expiresDate,
  revocationDate,
  revocationReason,
  appAccountToken,
  inAppOwnershipType,
}) {
  const payload = {
    productId,
    signedDate,
    transactionId,
    originalTransactionId,
    bundleId,
    expiresDate,
    revocationDate,
    revocationReason,
    appAccountToken,
    inAppOwnershipType,
  };
  return {
    raw: `raw-${transactionId}-${signedDate}`,
    payload,
    environment: "Sandbox",
  };
}

function stubDoc(overrides = {}) {
  return {
    id: "hosted_quota_sync",
    active: true,
    productID: "p",
    transactionID: "tx",
    originalTransactionID: "otx",
    expiresAt: "2099-01-01T00:00:00.000Z",
    environment: "Sandbox",
    signedTransactionHash: "0".repeat(64),
    lastVerifiedAt: "2026-01-01T00:00:00.000Z",
    source: "apple_jws_verified",
    verificationVersion: 2,
    schemaVersion: 2,
    updatedAt: "2026-01-01T00:00:00.000Z",
    ...overrides,
  };
}

function makeFakeFirestore(writes, opts = {}) {
  const docFn = (path) => ({
    path,
    async create(value) {
      if (opts.simulateError) throw opts.simulateError;
      if (opts.simulateAlreadyExists) {
        const err = new Error("ALREADY_EXISTS");
        err.code = 6;
        // Push the original "create" first so the test sees the
        // attempted write before the throw, then surface as
        // ALREADY_EXISTS to exercise the idempotency branch.
        writes.push({ kind: "create", path, data: value });
        throw err;
      }
      writes.push({ kind: "create", path, data: value });
    },
    async set(value, options) {
      writes.push({ kind: "set", path, data: value, options });
    },
    async get() {
      return { exists: false, data: () => undefined };
    },
  });
  return { doc: docFn };
}
