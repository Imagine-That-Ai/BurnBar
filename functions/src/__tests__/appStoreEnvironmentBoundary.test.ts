import { describe, expect, it, vi } from "vitest";
import type { StatusResponse } from "@apple/app-store-server-library";
import { Firestore } from "firebase-admin/firestore";

import type { AppStoreConfig } from "../types.js";
import {
  assertConfiguredAppStoreEnvironment,
  reconcileEntitlement,
  EntitlementReconcileError,
} from "../appstore/reconciler.js";
import { AppleJWSVerifier, type DecodedTransaction } from "../appstore/verifier.js";

const BUNDLE_ID = "com.openburnbar.app";
const PRODUCT_ID = "com.openburnbar.hostedQuotaSync.cloud.monthly";

function appStoreConfig(environment: AppStoreConfig["environment"]): AppStoreConfig {
  return {
    bundleId: BUNDLE_ID,
    appAppleId: 1234567890,
    environment,
    enableOnlineChecks: true,
    autoFallbackEnvironment: true,
    asc: {
      issuerId: "issuer-1",
      keyId: "key-1",
      privateKeyP8: "test-key-material",
    },
  };
}

function transaction(environment: AppStoreConfig["environment"]): DecodedTransaction {
  const payload = {
    bundleId: BUNDLE_ID,
    productId: PRODUCT_ID,
    transactionId: "1000000000001",
    originalTransactionId: "1000000000000",
    signedDate: Date.parse("2026-06-22T00:00:00.000Z"),
    expiresDate: Date.parse("2026-07-22T00:00:00.000Z"),
  } satisfies DecodedTransaction["payload"];

  return {
    raw: `jws-${environment}`,
    environment,
    payload,
  } satisfies DecodedTransaction;
}

describe("App Store entitlement environment boundary", () => {
  it("accepts an exact configured App Store environment", () => {
    expect(() => assertConfiguredAppStoreEnvironment(appStoreConfig("Production"), "Production", "seed")).not.toThrow();
    expect(() => assertConfiguredAppStoreEnvironment(appStoreConfig("Sandbox"), "Sandbox", "seed")).not.toThrow();
  });

  it("rejects a sandbox transaction before production entitlement reconciliation can write", async () => {
    const emptyStatus = { data: [] } satisfies StatusResponse;
    const fetchLive = vi.fn(async () => ({ status: emptyStatus, pairs: [] }));
    const verifier = new AppleJWSVerifier(appStoreConfig("Production"));
    const firestore = new Firestore({ projectId: "openburnbar-test" });
    vi.spyOn(verifier, "verifyTransaction").mockResolvedValue(transaction("Sandbox"));

    await expect(
      reconcileEntitlement(
        firestore,
        appStoreConfig("Production"),
        {
          signedTransactionJWS: "header.payload.signature",
          claimedUid: "uid-1",
          source: "client_callable",
          productID: PRODUCT_ID,
        },
        {
          verifier,
          fetchLive,
        },
      ),
    ).rejects.toMatchObject({
      name: "EntitlementReconcileError",
      code: "environment_mismatch",
    } satisfies Partial<EntitlementReconcileError>);

    expect(fetchLive).not.toHaveBeenCalled();
  });
});
