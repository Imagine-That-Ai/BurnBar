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
  readonly docRefs = new Map<string, FakeDoc>();
  constructor(data: Record<string, unknown> | undefined | Record<string, Record<string, unknown> | undefined>) {
    if (data === undefined || "active" in data || "productID" in data || "expiresAt" in data || "expireAt" in data) {
      this.docRefs.set("hosted_quota_sync", new FakeDoc(data as Record<string, unknown> | undefined));
      return;
    }
    const entitlementDocs = data as Record<string, Record<string, unknown> | undefined>;
    for (const [id, value] of Object.entries(entitlementDocs)) {
      this.docRefs.set(id, new FakeDoc(value));
    }
  }
  doc(path: string): FakeDoc {
    const id = path.split("/").at(-1) ?? "";
    let docRef = this.docRefs.get(id);
    if (!docRef) {
      docRef = new FakeDoc(undefined);
      this.docRefs.set(id, docRef);
    }
    return docRef;
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
  assert.equal(db.docRefs.get("hosted_quota_sync")?.reads, 1);
});

test("accepts active BurnBar Pro entitlement for upgraded accounts", async () => {
  const db = new FakeFirestore({
    hosted_quota_sync: undefined,
    burnbar_pro: {
      active: true,
      productID: "com.openburnbar.pro.monthly",
      expiresAt: new Date(Date.now() + 60_000).toISOString(),
    },
  });
  const verifier = new FirestoreEntitlementVerifier({
    productIDs: [
      "com.openburnbar.hostedQuotaSync.cloud.monthly",
      "com.openburnbar.hostedQuotaSync.monthly",
      "com.openburnbar.pro.monthly",
    ],
    cacheTTLSeconds: 60,
    negativeCacheTTLSeconds: 1,
    firestore: db as never,
  });

  const entitlement = await verifier.assertActive("uid-1");
  assert.equal(entitlement.productID, "com.openburnbar.pro.monthly");
  assert.equal(entitlement.source, "firestore");
  assert.equal(db.docRefs.get("hosted_quota_sync")?.reads, 1);
  assert.equal(db.docRefs.get("burnbar_pro")?.reads, 1);
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
