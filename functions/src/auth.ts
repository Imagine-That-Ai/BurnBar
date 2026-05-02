/**
 * @fileoverview Authentication and App Check enforcement helpers.
 *
 * Every callable function must call `assertAuth(ctx)` and, when applicable,
 * `assertAppCheck(ctx)`.  This module centralizes error codes and messaging
 * so callers get consistent HTTP status semantics via HttpsError.
 */

import * as functions from "firebase-functions/v2/https";
import type { CallableRequest } from "firebase-functions/v2/https";
import { getConfig } from "./config.js";

/**
 * Assert that the request carries a valid Firebase Auth token and that the
 * caller UID matches the requested user namespace.
 *
 * @param request - The callable request context.
 * @param expectedUid - The Firestore user namespace being accessed.
 * @throws {HttpsError} UNAUTHENTICATED or PERMISSION_DENIED.
 */
export function assertOwnership(
  request: CallableRequest,
  expectedUid: string
): void {
  assertAuth(request);
  if (request.auth!.uid !== expectedUid) {
    throw new functions.HttpsError(
      "permission-denied",
      `Caller UID ${request.auth!.uid} does not own namespace ${expectedUid}.`
    );
  }
}

/**
 * Assert that the request carries a valid Firebase Auth token.
 *
 * @param request - The callable request context.
 * @throws {HttpsError} UNAUTHENTICATED.
 */
export function assertAuth(request: CallableRequest): void {
  if (!request.auth) {
    throw new functions.HttpsError(
      "unauthenticated",
      "Request must be authenticated with Firebase Auth."
    );
  }
}

/**
 * Assert that App Check attestation is present and valid.
 *
 * Skipped when `enforceAppCheck` is false (local emulation).
 *
 * @param request - The callable request context.
 * @throws {HttpsError} UNAUTHENTICATED.
 */
export function assertAppCheck(request: CallableRequest): void {
  if (!getConfig().enforceAppCheck) return;

  // In v2 callable functions, App Check info is available on the request.
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const appCheck = (request as any).app;
  if (!appCheck || appCheck.appId == null) {
    throw new functions.HttpsError(
      "unauthenticated",
      "App Check attestation is required."
    );
  }
}

/**
 * Convenience guard used at the top of every sensitive callable.
 *
 * @param request - The callable request context.
 * @param expectedUid - The user namespace being accessed.
 */
export function enforceAuthAndAppCheck(
  request: CallableRequest,
  expectedUid: string
): void {
  assertAuth(request);
  assertAppCheck(request);
  assertOwnership(request, expectedUid);
}
