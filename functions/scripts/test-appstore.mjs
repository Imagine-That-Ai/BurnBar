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

import { __testing__ as quotaTesting } from "../lib/quota.js";

import {
  beginBinding,
  EntitlementReconcileError,
  reconcileEntitlement,
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

test("environment mapping accepts Apple payload casing", () => {
  assert.equal(fromLibEnvironment("PRODUCTION"), "Production");
  assert.equal(fromLibEnvironment("SANDBOX"), "Sandbox");
  assert.equal(toLibEnvironment("PRODUCTION"), Environment.PRODUCTION);
  assert.equal(toLibEnvironment("SANDBOX"), Environment.SANDBOX);
});

test("environment mapping routes internal test entitlements through Sandbox", () => {
  assert.equal(fromLibEnvironment("InternalTest"), "Sandbox");
  assert.equal(toLibEnvironment("InternalTest"), Environment.SANDBOX);
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

test("AppleJWSVerifier refuses Production without an appAppleId", () => {
  // Library v1.1+ requires `appAppleId` for Production. We surface a
  // human-readable error rather than letting the library throw a vague
  // one when a callable accidentally hits Production with the field unset.
  const v = new AppleJWSVerifier({
    bundleId: "com.test.app",
    environment: "Production",
    enableOnlineChecks: false,
    autoFallbackEnvironment: false,
    asc: { keyId: "k", issuerId: "i", privateKeyP8: "p" },
    // appAppleId intentionally absent.
  });
  assert.throws(
    () => v.warmUp(),
    /appAppleId is required for the Production environment/
  );
});

test("AppleJWSVerifier accepts Production when appAppleId is set", () => {
  const v = new AppleJWSVerifier({
    bundleId: "com.test.app",
    environment: "Production",
    enableOnlineChecks: false,
    appAppleId: 1234567890,
    asc: { keyId: "k", issuerId: "i", privateKeyP8: "p" },
  });
  // We don't actually verify a JWS here — just prove the lib verifier
  // can be constructed. `warmUp()` is the entry point that throws on
  // misconfig.
  assert.doesNotThrow(() => v.warmUp());
});

// ---------------------------------------------------------------------------
// 4. Reconciler pickWinning
// ---------------------------------------------------------------------------

test("pickWinning ignores transactions with the wrong productId", () => {
  const productID = "com.openburnbar.hostedQuotaSync.cloud.monthly";
  const candidates = [
    fakeTx({ productId: "different", signedDate: 100 }),
    fakeTx({ productId: productID, signedDate: 50 }),
  ];
  const winner = reconcilerTesting.pickWinning(candidates, productID);
  assert.ok(winner);
  assert.equal(winner.payload.signedDate, 50);
});

test("pickWinning selects the most recent signedDate", () => {
  const productID = "com.openburnbar.hostedQuotaSync.cloud.monthly";
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
  const productID = "com.openburnbar.hostedQuotaSync.cloud.monthly";
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
  assert.equal(doc.signedDateMs, 1700000000_000);
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

test("shouldOverwrite accepts newer or equal Apple signedDate", () => {
  const a = stubDoc({ signedDateMs: 1700000000_000 });
  const b = stubDoc({ signedDateMs: 1800000000_000 });
  assert.equal(reconcilerTesting.shouldOverwrite(a, b), true);
  assert.equal(reconcilerTesting.shouldOverwrite(b, b), true); // idempotent retry
});

test("shouldOverwrite rejects older Apple signedDate (replay protection)", () => {
  const newer = stubDoc({ signedDateMs: 1800000000_000 });
  const older = stubDoc({ signedDateMs: 1700000000_000 });
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
// 7a. Reconciler: redactPayload (PII filter for the audit `decoded` blob)
// ---------------------------------------------------------------------------

test("redactPayload drops storefront/currency/price PII fields", () => {
  const out = reconcilerTesting.redactPayload({
    transactionId: "t-1",
    productId: "p",
    bundleId: "b",
    storefront: "USA",
    storefrontId: "143441",
    currency: "USD",
    price: 4990,
    signedDate: 1700000000_000,
  });
  assert.equal(out.transactionId, "t-1");
  assert.equal(out.signedDate, 1700000000_000);
  assert.ok(!("storefront" in out), "storefront must be redacted");
  assert.ok(!("storefrontId" in out));
  assert.ok(!("currency" in out));
  assert.ok(!("price" in out));
});

test("redactPayload hashes appAccountToken instead of persisting it", () => {
  const out = reconcilerTesting.redactPayload({
    transactionId: "t",
    productId: "p",
    bundleId: "b",
    appAccountToken: "ABCDEF12-3456-7890-ABCD-EF1234567890",
    signedDate: 1,
  });
  assert.ok(!("appAccountToken" in out));
  assert.match(out.appAccountTokenHash, /^[0-9a-f]{64}$/);
});

test("redactPayload omits appAccountTokenHash when no token was present", () => {
  const out = reconcilerTesting.redactPayload({
    transactionId: "t",
    productId: "p",
    bundleId: "b",
    signedDate: 1,
  });
  assert.ok(!("appAccountTokenHash" in out));
  assert.ok(!("appAccountToken" in out));
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
// 13. End-to-end reconcileEntitlement with fake verifier + fake Firestore
// ---------------------------------------------------------------------------

test("reconcileEntitlement happy path: writes a v2 doc + audit event", async () => {
  const productID = "p-monthly";
  const cfg = stubCfg({ bundleId: "com.test.app" });
  const writes = [];
  const reads = new Map();
  const token = "11111111-1111-1111-1111-111111111111";
  // Pre-populate the binding so resolveUid() succeeds.
  reads.set(`users/uid-7/entitlement_bindings/${token}`, {
    exists: true,
    data: () => ({
      id: token,
      uid: "uid-7",
      productID,
      createdAt: "2026-01-01",
      schemaVersion: 1,
    }),
  });
  const db = makeReconcilerDb(writes, reads);

  const seed = fakeTx({
    productId: productID,
    signedDate: 1700000000_000,
    transactionId: "tx-A",
    originalTransactionId: "otx-A",
    bundleId: "com.test.app",
    expiresDate: Date.now() + 30 * 86_400_000,
    appAccountToken: token,
  });
  const verifier = fakeVerifier({ seed });
  const fetchLive = async () => ({
    status: { data: [] },
    pairs: [],
  });

  const result = await reconcileEntitlement(
    db,
    cfg,
    {
      signedTransactionJWS: seed.raw,
      claimedUid: "uid-7",
      source: "client_callable",
      productID,
    },
    { verifier, fetchLive }
  );

  assert.equal(result.uid, "uid-7");
  assert.equal(result.changed, true);
  assert.equal(result.entitlement.active, true);
  assert.equal(result.entitlement.transactionID, "tx-A");
  assert.equal(result.entitlement.source, "apple_jws_verified");
  // We expect at least: txn set + audit create.
  const entitlementWrite = writes.find((w) =>
    w.path.endsWith("/entitlements/hosted_quota_sync")
  );
  assert.ok(entitlementWrite, "entitlement doc was written");
  const auditWrite = writes.find((w) => w.path.includes("/entitlement_events/"));
  assert.ok(auditWrite, "audit event was written");
});

test("reconcileEntitlement rejects on bundleId mismatch", async () => {
  const cfg = stubCfg({ bundleId: "com.test.app" });
  const writes = [];
  const db = makeReconcilerDb(writes, new Map());

  const seed = fakeTx({
    productId: "p",
    signedDate: 1,
    transactionId: "tx",
    originalTransactionId: "otx",
    bundleId: "com.attacker.app",
    expiresDate: Date.now() + 86_400_000,
  });
  const verifier = fakeVerifier({ seed });
  const fetchLive = async () => ({ status: { data: [] }, pairs: [] });

  await assert.rejects(
    reconcileEntitlement(
      db,
      cfg,
      {
        signedTransactionJWS: seed.raw,
        claimedUid: "uid-8",
        source: "client_callable",
        productID: "p",
      },
      { verifier, fetchLive }
    ),
    /bundle_id_mismatch/
  );
  // No entitlement doc should have been written.
  assert.equal(
    writes.filter((w) => w.path.endsWith("/entitlements/hosted_quota_sync"))
      .length,
    0
  );
});

test("reconcileEntitlement rejects when claimedUid disagrees with binding", async () => {
  const productID = "p";
  const cfg = stubCfg({ bundleId: "com.test.app" });
  const writes = [];
  const reads = new Map();
  const token = "22222222-2222-2222-2222-222222222222";
  // Pre-populate the binding under uid-A …
  reads.set(`users/uid-A/entitlement_bindings/${token}`, {
    exists: true,
    data: () => ({
      id: token,
      uid: "uid-A",
      productID,
      createdAt: "2026-01-01",
      schemaVersion: 1,
    }),
  });
  // … but not under uid-B.
  const db = makeReconcilerDb(writes, reads);

  const seed = fakeTx({
    productId: productID,
    signedDate: 1,
    transactionId: "tx",
    originalTransactionId: "otx",
    bundleId: "com.test.app",
    expiresDate: Date.now() + 86_400_000,
    appAccountToken: token,
  });
  const verifier = fakeVerifier({ seed });
  const fetchLive = async () => ({ status: { data: [] }, pairs: [] });

  // Caller claims uid-B, but the binding is for uid-A.
  await assert.rejects(
    reconcileEntitlement(
      db,
      cfg,
      {
        signedTransactionJWS: seed.raw,
        claimedUid: "uid-B",
        source: "client_callable",
        productID,
      },
      { verifier, fetchLive }
    ),
    /binding_mismatch/
  );
});

test("reconcileEntitlement is idempotent on replay (no extra writes)", async () => {
  const productID = "p";
  const cfg = stubCfg({ bundleId: "com.test.app" });
  const writes = [];
  const reads = new Map();
  // Simulate the second call: existing doc with NEWER lastVerifiedAt.
  reads.set("users/uid-7/entitlements/hosted_quota_sync", {
    exists: true,
    data: () => ({
      id: "hosted_quota_sync",
      signedDateMs: 1800000000_000,
      lastVerifiedAt: "2099-01-01T00:00:00.000Z", // local verification wall clock
      active: true,
      productID,
      transactionID: "tx-A",
      originalTransactionID: "otx-A",
      environment: "Sandbox",
      signedTransactionHash: "0".repeat(64),
      source: "apple_jws_verified",
      verificationVersion: 2,
      schemaVersion: 2,
      updatedAt: "2099-01-01T00:00:00.000Z",
    }),
  });
  const db = makeReconcilerDb(writes, reads);

  const seed = fakeTx({
    productId: productID,
    signedDate: 1700000000_000,
    transactionId: "tx-A",
    originalTransactionId: "otx-A",
    bundleId: "com.test.app",
    expiresDate: Date.now() + 86_400_000,
  });
  const verifier = fakeVerifier({ seed });
  const fetchLive = async () => ({ status: { data: [] }, pairs: [] });

  const result = await reconcileEntitlement(
    db,
    cfg,
    {
      signedTransactionJWS: seed.raw,
      claimedUid: "uid-7",
      source: "client_callable",
      productID,
    },
    { verifier, fetchLive }
  );

  assert.equal(result.changed, false, "old signedDate must not overwrite new doc");
  // The audit event still gets appended (we want the forensic record),
  // but the entitlement itself is untouched.
  const entitlementWrites = writes.filter((w) =>
    w.path.endsWith("/entitlements/hosted_quota_sync")
  );
  assert.equal(entitlementWrites.length, 0);
});

test("reconcileEntitlement honours ASC live state over inbound JWS", async () => {
  const productID = "p";
  const cfg = stubCfg({ bundleId: "com.test.app" });
  const writes = [];
  const db = makeReconcilerDb(writes, new Map());

  const oldTx = fakeTx({
    productId: productID,
    signedDate: 1700000000_000,
    transactionId: "tx-old",
    originalTransactionId: "otx-A",
    bundleId: "com.test.app",
    expiresDate: Date.now() + 86_400_000,
  });
  const newerTx = fakeTx({
    productId: productID,
    signedDate: 1800000000_000, // newer
    transactionId: "tx-new",
    originalTransactionId: "otx-A",
    bundleId: "com.test.app",
    expiresDate: Date.now() + 60 * 86_400_000,
  });
  // Seed sees old; ASC returns the newer one. Reconciler must pick newer.
  const verifier = fakeVerifier({
    seed: oldTx,
    extraVerifyTransaction: { [newerTx.raw]: newerTx },
  });
  const fetchLive = async () => ({
    status: { data: [] },
    pairs: [{ signedTransactionInfo: newerTx.raw }],
  });

  const result = await reconcileEntitlement(
    db,
    cfg,
    {
      signedTransactionJWS: oldTx.raw,
      claimedUid: "uid-7",
      source: "client_callable",
      productID,
    },
    { verifier, fetchLive }
  );

  assert.equal(result.entitlement.transactionID, "tx-new");
});

test("reconcileEntitlement fails closed when ASC live status is unavailable", async () => {
  const productID = "p";
  const cfg = stubCfg({ bundleId: "com.test.app" });
  const writes = [];
  const reads = new Map();
  const token = "33333333-3333-3333-3333-333333333333";
  reads.set(`users/uid-asc/entitlement_bindings/${token}`, {
    exists: true,
    data: () => ({
      id: token,
      uid: "uid-asc",
      productID,
      createdAt: "2026-01-01",
      schemaVersion: 1,
    }),
  });
  const db = makeReconcilerDb(writes, reads);
  const seed = fakeTx({
    productId: productID,
    signedDate: 1700000000_000,
    transactionId: "tx-seed",
    originalTransactionId: "otx-asc",
    bundleId: "com.test.app",
    expiresDate: Date.now() + 86_400_000,
    appAccountToken: token,
  });
  const verifier = fakeVerifier({ seed });
  const fetchLive = async () => {
    throw new Error("ASC temporarily unavailable");
  };

  await assert.rejects(
    reconcileEntitlement(
      db,
      cfg,
      {
        signedTransactionJWS: seed.raw,
        claimedUid: "uid-asc",
        source: "client_callable",
        productID,
      },
      { verifier, fetchLive }
    ),
    /asc_live_status_unavailable/
  );

  assert.equal(
    writes.filter((w) => w.path.endsWith("/entitlements/hosted_quota_sync")).length,
    0
  );
});

// ---------------------------------------------------------------------------
// 12. Hosted quota runner snapshot normalization
// ---------------------------------------------------------------------------

test("hosted runner snapshots are server-attributed and sanitized", () => {
  const account = {
    id: "codex_default",
    providerID: "codex",
    label: "Hosted Codex",
    storageScope: "server_private",
  };
  const snapshot = quotaTesting.normalizeRunnerSnapshot(
    {
      provider: "openai",
      providerID: "openai",
      accountID: "other",
      sourceId: "../hosted runner",
      fetchedAt: "not a date",
      source: "Codex app-server account/rateLimits/read",
      confidence: "high",
      managementURL: "http://example.test/not-allowed",
      buckets: [
        {
          name: "Codex weekly",
          used: 42,
          limit: 100,
          remaining: 58,
          window: "weekly",
          meta: {
            unit: "percent",
            authorization: "nope",
            nested: { should: "drop" },
          },
        },
      ],
    },
    account,
    "2026-05-05T00:00:00.000Z"
  );

  assert.equal(snapshot.provider, "codex");
  assert.equal(snapshot.providerID, "codex");
  assert.equal(snapshot.accountID, "codex_default");
  assert.equal(snapshot.accountLabel, "Hosted Codex");
  assert.equal(snapshot.accountStorageScope, "server_private");
  assert.equal(snapshot.sourceId, "hosted-runner");
  assert.equal(snapshot.fetchedAt, "2026-05-05T00:00:00.000Z");
  assert.equal(snapshot.managementURL, undefined);
  assert.equal(snapshot.buckets.length, 1);
  assert.deepEqual(snapshot.buckets[0].meta, { unit: "percent" });
});

test("hosted runner snapshot normalization rejects empty bucket sets", () => {
  assert.throws(
    () =>
      quotaTesting.normalizeRunnerSnapshot(
        { buckets: [] },
        {
          id: "codex_default",
          providerID: "codex",
          label: "Hosted Codex",
          storageScope: "server_private",
        },
        "2026-05-05T00:00:00.000Z"
      ),
    /no quota buckets/
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
    signedDateMs: 1700000000_000,
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

// ---------------------------------------------------------------------------
// Helpers used by the reconciler integration tests
// ---------------------------------------------------------------------------

function stubCfg(overrides = {}) {
  return {
    bundleId: "com.test.app",
    environment: "Sandbox",
    enableOnlineChecks: false,
    autoFallbackEnvironment: false,
    asc: { keyId: "k", issuerId: "i", privateKeyP8: "p" },
    ...overrides,
  };
}

/**
 * Lightweight fake of admin firestore — supports `.doc(path).{get,create,set}`,
 * `.collection(path).{add,where(...)}`, and `.collectionGroup(name).where(...)`.
 *
 * `reads` is a Map<path, snapshot>; missing paths return `{exists:false}`.
 * `writes` collects every mutation for assertion.
 */
function makeReconcilerDb(writes, reads) {
  const collectionGroupSnaps = new Map();

  function doc(path) {
    return {
      path,
      async get() {
        const snap = reads.get(path);
        if (snap) return snap;
        return { exists: false, data: () => undefined };
      },
      async create(value) {
        // The reconciler uses `.create()` for audit events and bindings;
        // they're new every call, but tolerate repeats for replay tests.
        const existing = reads.get(path);
        if (existing && existing.exists) {
          const err = new Error("ALREADY_EXISTS");
          err.code = 6;
          throw err;
        }
        writes.push({ kind: "create", path, data: value });
      },
      async set(value, options) {
        writes.push({ kind: "set", path, data: value, options });
      },
      collection(name) {
        return collection(`${path}/${name}`);
      },
    };
  }

  function collection(path) {
    return {
      path,
      doc(id) {
        return doc(`${path}/${id}`);
      },
      async add(value) {
        const childPath = `${path}/auto-${writes.length}`;
        writes.push({ kind: "add", path: childPath, data: value });
        return doc(childPath);
      },
      where() {
        // Fall through to an empty snapshot — the reconciler uses
        // collection-group queries for cross-user lookups; tests opt
        // into a populated result via `setCollectionGroupResult()`.
        return {
          async get() {
            return collectionGroupSnaps.get(path) ?? { empty: true, docs: [] };
          },
          where() {
            return this;
          },
          limit() {
            return this;
          },
        };
      },
    };
  }

  async function runTransaction(fn) {
    // Tiny in-memory transaction shim. We don't model isolation —
    // each `tx.get()` returns the current `reads` snapshot and
    // `tx.set()` defers into `writes` only on commit. Sufficient for
    // happy-path / monotonicity / replay tests.
    const txWrites = [];
    const tx = {
      async get(ref) {
        return ref.get();
      },
      set(ref, value, options) {
        txWrites.push({ kind: "set", path: ref.path, data: value, options });
      },
      create(ref, value) {
        txWrites.push({ kind: "create", path: ref.path, data: value });
      },
      update(ref, value) {
        txWrites.push({ kind: "update", path: ref.path, data: value });
      },
    };
    const result = await fn(tx);
    for (const w of txWrites) writes.push(w);
    return result;
  }

  return {
    doc,
    collection,
    runTransaction,
    collectionGroup(name) {
      return {
        where() {
          return {
            async get() {
              return collectionGroupSnaps.get(`__cg__/${name}`) ?? {
                empty: true,
                docs: [],
              };
            },
            where() {
              return this;
            },
            limit() {
              return this;
            },
          };
        },
      };
    },
    setCollectionGroupResult(name, snap) {
      collectionGroupSnaps.set(`__cg__/${name}`, snap);
    },
  };
}

/**
 * Synchronous in-memory verifier matching the live `AppleJWSVerifier`
 * surface area used by the reconciler. `seed` is the JWS we expect the
 * caller to forward; `extraVerifyTransaction` is keyed by raw JWS for
 * the ASC-paired transactions the reconciler re-verifies.
 */
function fakeVerifier({ seed, extraVerifyTransaction = {} }) {
  const byRaw = new Map([[seed.raw, seed]]);
  for (const [raw, tx] of Object.entries(extraVerifyTransaction)) {
    byRaw.set(raw, tx);
  }
  return {
    defaultEnvironment: "Sandbox",
    async verifyTransaction(jws) {
      const tx = byRaw.get(jws);
      if (!tx) {
        const err = new Error(`fakeVerifier: no transaction for ${jws}`);
        err.code = "jws_invalid";
        throw err;
      }
      return tx;
    },
    async verifyRenewalInfo() {
      return { payload: {}, environment: "Sandbox", raw: "" };
    },
    async verifyNotification(jws) {
      const tx = byRaw.get(jws);
      if (!tx) throw new Error("not implemented");
      return { payload: { data: {} }, environment: "Sandbox" };
    },
    warmUp() {},
  };
}
