import assert from "node:assert/strict";
import test from "node:test";
import { FirestoreEntitlementVerifier } from "./entitlements.js";
import { RelayHttpError } from "./errors.js";

class FakeDoc {
  reads = 0;
  constructor(private readonly dataValue: Record<string, unknown> | undefined) {}

  async get(): Promise<{ exists: boolean; data(): Record<string, unknown> | undefined }> {
    this.reads += 1;
    return {
      exists: this.dataValue !== undefined,
      data: () => this.dataValue,
    };
  }
}

class FakeFirestore {
  readonly docRef: FakeDoc;
  constructor(data: Record<string, unknown> | undefined) {
    this.docRef = new FakeDoc(data);
  }
  doc(): FakeDoc {
    return this.docRef;
  }
}

test("accepts active paid entitlement and caches the read", async () => {
  const db = new FakeFirestore({
    active: true,
    productID: "com.openburnbar.hostedQuotaSync.cloud.monthly",
    expiresAt: new Date(Date.now() + 60_000).toISOString(),
  });
  const verifier = new FirestoreEntitlementVerifier({
    productIDs: ["com.openburnbar.hostedQuotaSync.cloud.monthly"],
    cacheTTLSeconds: 60,
    negativeCacheTTLSeconds: 1,
    firestore: db as never,
  });

  assert.equal((await verifier.assertActive("uid-1")).source, "firestore");
  assert.equal((await verifier.assertActive("uid-1")).source, "cache");
  assert.equal(db.docRef.reads, 1);
});

test("rejects missing, wrong-product, and expired entitlement", async () => {
  for (const data of [
    undefined,
    { active: true, productID: "wrong", expiresAt: new Date(Date.now() + 60_000).toISOString() },
    { active: true, productID: "com.openburnbar.hostedQuotaSync.cloud.monthly", expiresAt: new Date(Date.now() - 1_000).toISOString() },
  ]) {
    const verifier = new FirestoreEntitlementVerifier({
      productIDs: ["com.openburnbar.hostedQuotaSync.cloud.monthly"],
      cacheTTLSeconds: 60,
      negativeCacheTTLSeconds: 1,
      firestore: new FakeFirestore(data) as never,
    });
    await assert.rejects(
      verifier.assertActive("uid-1"),
      (error) => error instanceof RelayHttpError && error.statusCode === 403
    );
  }
});
