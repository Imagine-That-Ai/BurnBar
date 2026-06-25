import { describe, expect, it } from "vitest";

import { appStoreNotificationReconcileFailureResponse } from "../appstore/notifications.js";
import { EntitlementReconcileError } from "../appstore/reconciler.js";

describe("App Store notification reconcile failure responses", () => {
  it("returns retryable 5xx for transient App Store live-status failures", () => {
    const response = appStoreNotificationReconcileFailureResponse(
      new EntitlementReconcileError("asc_live_status_unavailable", "live status unavailable"),
    );

    expect(response).toEqual({
      statusCode: 503,
      body: {
        error: "app_store_unavailable",
        code: "asc_live_status_unavailable",
      },
    });
  });

  it("acknowledges terminal policy failures so Apple does not retry doomed notifications", () => {
    const response = appStoreNotificationReconcileFailureResponse(
      new EntitlementReconcileError("binding_mismatch", "binding belongs to another user"),
    );

    expect(response).toEqual({
      statusCode: 200,
      body: {
        accepted: false,
        code: "binding_mismatch",
      },
    });
  });

  it("keeps unknown internal errors retryable", () => {
    const response = appStoreNotificationReconcileFailureResponse(new Error("database unavailable"));

    expect(response).toEqual({
      statusCode: 500,
      body: {
        error: "internal",
      },
    });
  });
});
