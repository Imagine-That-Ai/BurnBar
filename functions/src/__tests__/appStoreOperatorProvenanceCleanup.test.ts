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
  buildAppStoreEntitlementSource,
  buildBurnBarEntitlementMirror,
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

function verifiedHostedQuotaEntitlement(productID: string): HostedQuotaEntitlementDoc {
  return {
    id: "hosted_quota_sync",
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
    const sourcePayload = buildAppStoreEntitlementSource(entitlement);
    const mirrorPayload = buildBurnBarEntitlementMirror(entitlement, target);

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

    const sourceDoc = applyMerge(staleSource, sourcePayload);
    expect(sourceDoc).toMatchObject({
      id: target.sourceEntitlementID,
      active: true,
      source: "apple_jws_verified",
      productID,
    });
    for (const field of Object.keys(OPERATOR_PROVENANCE)) {
      expect(sourceDoc).not.toHaveProperty(field);
    }

    const mirrorDoc = applyMerge(staleMirror, mirrorPayload);
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

  it("composes a single clean document when the source is also the mirror", () => {
    const productID = getConfig().burnBarProProductID;
    const target = appStoreEntitlementTarget(productID);
    const entitlement = {
      ...verifiedHostedQuotaEntitlement(productID),
      id: target.sourceEntitlementID,
    };
    const sourcePayload = buildAppStoreEntitlementSource(entitlement);
    const mirrorPayload = buildBurnBarEntitlementMirror(entitlement, target);

    const sourceDoc = applyMerge(
      {
        id: target.sourceEntitlementID,
        source: "internal_operator_grant",
        ...OPERATOR_PROVENANCE,
      },
      { ...sourcePayload, ...mirrorPayload },
    );
    expect(sourceDoc).toMatchObject({
      id: target.sourceEntitlementID,
      active: true,
      source: "apple_jws_verified",
      sourceEntitlementID: target.sourceEntitlementID,
      sourceProductID: productID,
    });
    expect(sourceDoc).not.toHaveProperty("operatorGrant");
    expect(sourceDoc).not.toHaveProperty("operatorGrantedAt");
    expect(sourceDoc).not.toHaveProperty("operatorGrantReason");
  });
});
