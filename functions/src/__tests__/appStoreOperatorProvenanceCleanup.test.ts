/**
 * A verified Apple lifecycle that adopts an entitlement previously carried by
 * a temporary operator support bridge must remove the stale operator-only
 * provenance (operatorGrant / operatorGrantedAt / operatorGrantReason and the
 * bridge's sourceEntitlementID / sourceProductID) from BOTH the source doc and
 * the BurnBar mirror doc, matching the cleanup `writeBurnBarProEntitlement`
 * applies on the Stripe / Google Play path. The mirror re-asserts its own
 * sourceEntitlementID / sourceProductID after the cleanup.
 */
import { describe, expect, it, vi } from "vitest";
import type { Firestore } from "firebase-admin/firestore";
import type { StatusResponse } from "@apple/app-store-server-library";

import type { AppStoreConfig } from "../types.js";
import { reconcileEntitlement } from "../appstore/reconciler.js";
import { AppleJWSVerifier, type DecodedTransaction } from "../appstore/verifier.js";
import { getConfig } from "../config.js";

const BUNDLE_ID = "com.openburnbar.app";
const UID = "uid-appstore-adoption-1";
const ORIGINAL_TRANSACTION_ID = "2000000000000";

type Doc = Record<string, unknown>;

function fakeFirestore(): { docs: Map<string, Doc>; db: Firestore } {
  const docs = new Map<string, Doc>();

  class FakeDocSnapshot {
    constructor(private readonly value: Doc | undefined) {}

    get exists() {
      return this.value !== undefined;
    }

    data() {
      return this.value === undefined ? undefined : { ...this.value };
    }

    get(field: string) {
      return this.value === undefined ? undefined : this.value[field];
    }
  }

  class FakeDocRef {
    constructor(readonly path: string) {}

    collection(name: string) {
      return {
        doc: (id: string) => new FakeDocRef(`${this.path}/${name}/${id}`),
      };
    }

    async get() {
      return new FakeDocSnapshot(docs.get(this.path));
    }

    set(data: Doc, options?: { merge?: boolean }) {
      const next = options?.merge ? { ...(docs.get(this.path) ?? {}) } : {};
      for (const [key, value] of Object.entries(data)) {
        if (typeof value === "object" && value !== null && value.constructor.name === "DeleteTransform") {
          delete next[key];
        } else {
          next[key] = value;
        }
      }
      docs.set(this.path, next);
      return Promise.resolve();
    }

    create(data: Doc) {
      docs.set(this.path, { ...data });
      return Promise.resolve();
    }
  }

  const db = {
    doc: (path: string) => new FakeDocRef(path),
    runTransaction: async <T>(
      fn: (transaction: {
        get: (ref: FakeDocRef) => ReturnType<FakeDocRef["get"]>;
        set: (ref: FakeDocRef, data: Doc, options?: { merge?: boolean }) => void;
      }) => Promise<T>,
    ): Promise<T> =>
      fn({
        get: (ref) => ref.get(),
        set: (ref, data, options) => {
          void ref.set(data, options);
        },
      }),
  };

  // @ts-expect-error reason: the fake implements the Firestore surface reconcileEntitlement exercises
  return { docs, db };
}

function appStoreConfig(): AppStoreConfig {
  return {
    bundleId: BUNDLE_ID,
    appAppleId: 1234567890,
    environment: "Production",
    enableOnlineChecks: true,
    autoFallbackEnvironment: true,
    asc: {
      issuerId: "issuer-1",
      keyId: "key-1",
      privateKeyP8: "test-key-material",
    },
  };
}

function transaction(productID: string): DecodedTransaction {
  const payload = {
    bundleId: BUNDLE_ID,
    productId: productID,
    transactionId: "2000000000001",
    originalTransactionId: ORIGINAL_TRANSACTION_ID,
    signedDate: Date.parse("2026-07-22T00:00:00.000Z"),
    expiresDate: Date.now() + 30 * 24 * 60 * 60 * 1000,
  } satisfies DecodedTransaction["payload"];

  return {
    raw: "jws-production",
    environment: "Production",
    payload,
  } satisfies DecodedTransaction;
}

describe("App Store provider adoption", () => {
  it("removes stale operator provenance from the source and mirror docs on a verified reconcile", async () => {
    const productID = getConfig().hostedQuotaProductID;
    const { docs, db } = fakeFirestore();
    const sourcePath = `users/${UID}/entitlements/hosted_quota_sync`;
    const mirrorPath = `users/${UID}/entitlements/burnbar_pro`;

    const operatorProvenance = {
      operatorGrant: true,
      operatorGrantedAt: "2026-06-11T14:40:30.095Z",
      operatorGrantReason: "temporary support bridge",
      sourceEntitlementID: "burnbar_ultra",
      sourceProductID: "com.openburnbar.pro.monthly",
    };
    docs.set(sourcePath, {
      id: "hosted_quota_sync",
      active: true,
      source: "internal_operator_grant",
      originalTransactionID: ORIGINAL_TRANSACTION_ID,
      ...operatorProvenance,
    });
    docs.set(mirrorPath, {
      id: "burnbar_pro",
      active: true,
      source: "internal_operator_grant",
      ...operatorProvenance,
    });

    const emptyStatus = { data: [] } satisfies StatusResponse;
    const fetchLive = vi.fn(async () => ({ status: emptyStatus, pairs: [] }));
    const verifier = new AppleJWSVerifier(appStoreConfig());
    vi.spyOn(verifier, "verifyTransaction").mockResolvedValue(transaction(productID));

    const result = await reconcileEntitlement(
      db,
      appStoreConfig(),
      {
        signedTransactionJWS: "header.payload.signature",
        claimedUid: UID,
        source: "client_callable",
        productID,
      },
      { verifier, fetchLive },
    );
    expect(result.changed).toBe(true);

    const sourceDoc = docs.get(sourcePath);
    expect(sourceDoc).toMatchObject({
      active: true,
      source: "apple_jws_verified",
      productID,
    });
    for (const field of Object.keys(operatorProvenance)) {
      expect(sourceDoc).not.toHaveProperty(field);
    }

    const mirrorDoc = docs.get(mirrorPath);
    expect(mirrorDoc).toMatchObject({
      active: true,
      source: "apple_jws_verified",
      // The mirror re-asserts its OWN provenance after the cleanup.
      sourceEntitlementID: "hosted_quota_sync",
      sourceProductID: productID,
    });
    expect(mirrorDoc).not.toHaveProperty("operatorGrant");
    expect(mirrorDoc).not.toHaveProperty("operatorGrantedAt");
    expect(mirrorDoc).not.toHaveProperty("operatorGrantReason");
  });
});
