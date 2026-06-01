import { describe, expect, it } from "vitest";

import { googlePlayBillingRecordPath } from "../callables/googlePlayBillingPaths.js";

describe("googlePlayBillingRecordPath", () => {
  it("builds valid nested Firestore document paths for Google Play audit records", () => {
    const uid = "user_123";
    const tokenHash = "a".repeat(64);

    const purchasePath = googlePlayBillingRecordPath(uid, "purchase", tokenHash);
    const topupPath = googlePlayBillingRecordPath(uid, "topup", tokenHash);

    expect(purchasePath).toBe(`users/${uid}/billing/google_play_purchases/tokens/${tokenHash}`);
    expect(topupPath).toBe(`users/${uid}/billing/google_play_topups/tokens/${tokenHash}`);
    expect(purchasePath.split("/")).toHaveLength(6);
    expect(topupPath.split("/")).toHaveLength(6);
  });
});
