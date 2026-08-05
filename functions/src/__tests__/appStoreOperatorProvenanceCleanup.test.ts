/**
 * A verified Apple lifecycle that adopts an entitlement previously carried by
 * a temporary operator support bridge must remove stale operator provenance
 * from the source and mirror docs. The mirror then re-asserts its legitimate
 * sourceEntitlementID / sourceProductID.
 */
import { describe, expect, it } from "vitest";
import { FieldValue, Timestamp } from "firebase-admin/firestore";

import type { HostedQuotaEntitlementDoc } from "../types.js";
import {
  appStoreEntitlementTarget,
  buildAppStoreEntitlementWritePayloads,
  writeEntitlementDocs,
  writeEntitlementMirrorOnly,
} from "../appstore/reconciler.js";
import { getConfig } from "../config.js";

type Doc = Record<string, unknown>;

const OPERATOR_PROVENANCE = {
  operatorGrant: true,
  operatorGrantedAt: "2026-06-11T14:40:30.095Z",
  operatorGrantReason: "temporary support bridge",
  sourceEntitlementID: "burnbar_ultra",
  sourceProductID: "com.openburnbar.pro.monthly",
};

function applyMerge(existing: Doc, update: Doc): Doc {
  const merged = { ...existing };
  const deleteSentinel = FieldValue.delete();
  for (const [key, value] of Object.entries(update)) {
    if (value instanceof FieldValue && value.isEqual(deleteSentinel)) {
      delete merged[key];
    } else {
      merged[key] = value;
    }
  }
  return merged;
}

/**
 * In-memory stand-in for the `Transaction`/`Firestore` pair the reconcile
 * writers use. Document refs are plain paths, and merge writes honor
 * `FieldValue.delete()` sentinels, so the tests exercise the exact production
 * write path without any unsafe Firestore casts.
 */
function fakeEntitlementStore(seed: Record<string, Doc> = {}) {
  const docs = new Map<string, Doc>(Object.entries(seed));
  return {
    docs,
    db: { doc: (path: string) => path },
    tx: {
      set(path: string, data: Record<string, unknown>, options: { merge: true }): void {
        const existing = options.merge ? (docs.get(path) ?? {}) : {};
        docs.set(path, applyMerge(existing, data));
      },
    },
  };
}

function verifiedHostedQuotaEntitlement(productID: string, id = "hosted_quota_sync"): HostedQuotaEntitlementDoc {
  return {
    id,
    active: true,
    productID,
    transactionID: "2000000000001",
    originalTransactionID: "2000000000000",
    environment: "Production",
    source: "apple_jws_verified",
    expiresAt: "2030-01-01T00:00:00.000Z",
    expireAt: Timestamp.fromMillis(Date.parse("2030-01-01T00:00:00.000Z")),
    signedTransactionHash: "verified-jws-sha256",
    signedDateMs: Date.parse("2026-07-22T00:00:00.000Z"),
    lastVerifiedAt: "2026-07-22T00:00:00.000Z",
    schemaVersion: 2,
    verificationVersion: 2,
    updatedAt: "2026-07-22T00:00:00.000Z",
  };
}

describe("App Store provider adoption write payloads", () => {
  it("removes all bridge provenance from the source and restores only legitimate mirror provenance", () => {
    const productID = getConfig().hostedQuotaProductID;
    const entitlement = verifiedHostedQuotaEntitlement(productID);
    const target = appStoreEntitlementTarget(productID);
    const payloads = buildAppStoreEntitlementWritePayloads(entitlement, target);

    const staleSource = {
      id: target.sourceEntitlementID,
      source: "internal_operator_grant",
      ...OPERATOR_PROVENANCE,
    };
    const staleMirror = {
      id: target.mirrorEntitlementID,
      source: "internal_operator_grant",
      ...OPERATOR_PROVENANCE,
    };

    const sourceDoc = applyMerge(staleSource, payloads.sourceDoc);
    expect(sourceDoc).toMatchObject({
      id: target.sourceEntitlementID,
      active: true,
      source: "apple_jws_verified",
      productID,
    });
    for (const field of Object.keys(OPERATOR_PROVENANCE)) {
      expect(sourceDoc).not.toHaveProperty(field);
    }

    expect(payloads.mirrorDoc).toBeDefined();
    const mirrorDoc = applyMerge(staleMirror, payloads.mirrorDoc ?? {});
    expect(mirrorDoc).toMatchObject({
      id: target.mirrorEntitlementID,
      active: true,
      source: "apple_jws_verified",
      sourceEntitlementID: target.sourceEntitlementID,
      sourceProductID: productID,
    });
    expect(mirrorDoc).not.toHaveProperty("operatorGrant");
    expect(mirrorDoc).not.toHaveProperty("operatorGrantedAt");
    expect(mirrorDoc).not.toHaveProperty("operatorGrantReason");
  });
});

describe("App Store reconcile transaction writers", () => {
  const UID = "appstore-user-1";

  it("writeEntitlementDocs scrubs stale bridge provenance from the persisted source and mirror docs", () => {
    const productID = getConfig().hostedQuotaProductID;
    const entitlement = verifiedHostedQuotaEntitlement(productID);
    const target = appStoreEntitlementTarget(productID);
    const sourcePath = `users/${UID}/entitlements/${target.sourceEntitlementID}`;
    const mirrorPath = `users/${UID}/entitlements/${target.mirrorEntitlementID}`;
    const store = fakeEntitlementStore({
      [sourcePath]: { id: target.sourceEntitlementID, source: "internal_operator_grant", ...OPERATOR_PROVENANCE },
      [mirrorPath]: { id: target.mirrorEntitlementID, source: "internal_operator_grant", ...OPERATOR_PROVENANCE },
    });

    writeEntitlementDocs(store.tx, store.db, UID, entitlement, target);

    const sourceDoc = store.docs.get(sourcePath) ?? {};
    expect(sourceDoc).toMatchObject({ active: true, source: "apple_jws_verified", productID });
    for (const field of Object.keys(OPERATOR_PROVENANCE)) {
      expect(sourceDoc).not.toHaveProperty(field);
    }

    const mirrorDoc = store.docs.get(mirrorPath) ?? {};
    expect(mirrorDoc).toMatchObject({
      active: true,
      source: "apple_jws_verified",
      sourceEntitlementID: target.sourceEntitlementID,
      sourceProductID: productID,
    });
    expect(mirrorDoc).not.toHaveProperty("operatorGrant");
    expect(mirrorDoc).not.toHaveProperty("operatorGrantedAt");
    expect(mirrorDoc).not.toHaveProperty("operatorGrantReason");
  });

  it("writeEntitlementDocs collapses to a single cleaned doc when source and mirror coincide", () => {
    const productID = getConfig().burnBarProProductID;
    const target = appStoreEntitlementTarget(productID);
    expect(target.sourceEntitlementID).toBe(target.mirrorEntitlementID);
    const entitlement = verifiedHostedQuotaEntitlement(productID, target.sourceEntitlementID);
    const sourcePath = `users/${UID}/entitlements/${target.sourceEntitlementID}`;
    const store = fakeEntitlementStore({
      [sourcePath]: { id: target.sourceEntitlementID, source: "internal_operator_grant", ...OPERATOR_PROVENANCE },
    });

    writeEntitlementDocs(store.tx, store.db, UID, entitlement, target);

    expect(store.docs.size).toBe(1);
    const doc = store.docs.get(sourcePath) ?? {};
    expect(doc).toMatchObject({
      active: true,
      source: "apple_jws_verified",
      productID,
      sourceEntitlementID: target.sourceEntitlementID,
      sourceProductID: productID,
    });
    expect(doc).not.toHaveProperty("operatorGrant");
    expect(doc).not.toHaveProperty("operatorGrantedAt");
    expect(doc).not.toHaveProperty("operatorGrantReason");
  });

  it("writeEntitlementMirrorOnly refreshes the mirror without touching the source doc", () => {
    const productID = getConfig().hostedQuotaProductID;
    const entitlement = verifiedHostedQuotaEntitlement(productID);
    const target = appStoreEntitlementTarget(productID);
    const sourcePath = `users/${UID}/entitlements/${target.sourceEntitlementID}`;
    const mirrorPath = `users/${UID}/entitlements/${target.mirrorEntitlementID}`;
    const staleSource = { id: target.sourceEntitlementID, source: "internal_operator_grant", ...OPERATOR_PROVENANCE };
    const store = fakeEntitlementStore({
      [sourcePath]: { ...staleSource },
      [mirrorPath]: { id: target.mirrorEntitlementID, source: "internal_operator_grant", ...OPERATOR_PROVENANCE },
    });

    writeEntitlementMirrorOnly(store.tx, store.db, UID, entitlement, target);

    expect(store.docs.get(sourcePath)).toEqual(staleSource);
    const mirrorDoc = store.docs.get(mirrorPath) ?? {};
    expect(mirrorDoc).toMatchObject({ source: "apple_jws_verified", sourceEntitlementID: target.sourceEntitlementID });
    expect(mirrorDoc).not.toHaveProperty("operatorGrant");
  });

  it("writeEntitlementMirrorOnly is a no-op when source and mirror coincide", () => {
    const productID = getConfig().burnBarProProductID;
    const target = appStoreEntitlementTarget(productID);
    const entitlement = verifiedHostedQuotaEntitlement(productID, target.sourceEntitlementID);
    const store = fakeEntitlementStore();

    writeEntitlementMirrorOnly(store.tx, store.db, UID, entitlement, target);

    expect(store.docs.size).toBe(0);
  });
});
