import { describe, expect, it } from "vitest";
import { VerificationStatus } from "@apple/app-store-server-library";
import type { Response } from "express";

import {
  appStoreNotificationReconcileFailureResponse,
  appStoreNotificationVerifyFailureResponse,
  respondToAppStoreNotificationVerifyFailure,
} from "../appstore/notifications.js";
import { EntitlementReconcileError } from "../appstore/reconciler.js";
import { JWSVerificationFailure } from "../appstore/verifier.js";

interface CapturedResponse {
  statusCode?: number;
  body?: unknown;
}

function responseRecorder(): { response: Response; captured: CapturedResponse } {
  const captured: CapturedResponse = {};
  const response = {
    status(statusCode: number) {
      captured.statusCode = statusCode;
      return response;
    },
    json(body: unknown) {
      captured.body = body;
      return response;
    },
  } as unknown as Response;
  return { response, captured };
}

const TERMINAL_JWS_STATUSES = [
  VerificationStatus.VERIFICATION_FAILURE,
  VerificationStatus.INVALID_APP_IDENTIFIER,
  VerificationStatus.INVALID_ENVIRONMENT,
  VerificationStatus.INVALID_CHAIN_LENGTH,
  VerificationStatus.INVALID_CERTIFICATE,
  VerificationStatus.FAILURE,
] as const;

describe("App Store notification JWS verification failure responses", () => {
  it("returns 503 for Apple's explicit retryable verifier status", () => {
    const error = new JWSVerificationFailure(
      VerificationStatus.RETRYABLE_VERIFICATION_FAILURE,
      "OCSP temporarily unavailable",
    );

    expect(appStoreNotificationVerifyFailureResponse(error)).toEqual({
      statusCode: 503,
      body: {
        error: "jws_verification_unavailable",
      },
    });
  });

  it.each(TERMINAL_JWS_STATUSES)("returns 400 for terminal verifier status %s", (status) => {
    const error = new JWSVerificationFailure(status, "terminal verification failure");

    expect(appStoreNotificationVerifyFailureResponse(error)).toEqual({
      statusCode: 400,
      body: {
        error: "jws_invalid",
      },
    });
  });

  it("keeps impossible or future verifier statuses retryable instead of silently discarding the notification", () => {
    const impossible = new JWSVerificationFailure(VerificationStatus.OK, "unexpected success status");
    const future = new JWSVerificationFailure(999 as VerificationStatus, "unknown future status");

    expect(appStoreNotificationVerifyFailureResponse(impossible)).toEqual({
      statusCode: 500,
      body: {
        error: "internal",
      },
    });
    expect(appStoreNotificationVerifyFailureResponse(future)).toEqual({
      statusCode: 500,
      body: {
        error: "internal",
      },
    });
  });

  it("keeps unknown internal verification errors retryable", () => {
    expect(appStoreNotificationVerifyFailureResponse(new Error("verifier crashed"))).toEqual({
      statusCode: 500,
      body: {
        error: "internal",
      },
    });
  });

  it("wires the retryable classification into the actual HTTP responder", () => {
    const { response, captured } = responseRecorder();

    respondToAppStoreNotificationVerifyFailure(
      response,
      new JWSVerificationFailure(VerificationStatus.RETRYABLE_VERIFICATION_FAILURE, "OCSP temporarily unavailable"),
    );

    expect(captured).toEqual({
      statusCode: 503,
      body: {
        error: "jws_verification_unavailable",
      },
    });
  });

  it("wires terminal signature rejection into the actual HTTP responder", () => {
    const { response, captured } = responseRecorder();

    respondToAppStoreNotificationVerifyFailure(
      response,
      new JWSVerificationFailure(VerificationStatus.VERIFICATION_FAILURE, "signature invalid"),
    );

    expect(captured).toEqual({
      statusCode: 400,
      body: {
        error: "jws_invalid",
      },
    });
  });
});

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
