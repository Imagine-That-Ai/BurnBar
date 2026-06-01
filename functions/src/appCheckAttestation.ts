/**
 * @fileoverview App Check attestation binding via Firebase Auth custom claims.
 *
 * High-risk Computer Use and grant-issuance callables require a prior
 * `bindAppCheckAttestation` call so `request.auth.token.obb_app_check.appId`
 * matches the live App Check `request.app.appId`. Firestore rules do not use
 * `request.app` (console-only App Check enforcement on the Firestore product).
 */

import { createHash } from "node:crypto";

import * as functions from "firebase-functions/v2/https";
import type { CallableRequest } from "firebase-functions/v2/https";
import { getAuth } from "firebase-admin/auth";
import { getConfig } from "./config.js";
import { assertAppCheck, assertAuth, assertOwnership } from "./auth.js";
import { isRecord } from "./guards.js";

/** Matches Swift `AppCheckAttestationBinding.canonicalPrefix`. */
export const APP_CHECK_ATTESTATION_DIGEST_PREFIX = "openburnbar.appcheck.v1";

export const APP_CHECK_ATTESTATION_CLAIM_KEY = "obb_app_check" as const;
export const APP_CHECK_ATTESTATION_CLAIM_VERSION = 1 as const;
/** Re-bind after this many days so stale device attestations expire. */
export const APP_CHECK_ATTESTATION_MAX_AGE_MS = 30 * 24 * 60 * 60 * 1000;

export interface OpenBurnBarAppCheckAttestationClaim {
  v: typeof APP_CHECK_ATTESTATION_CLAIM_VERSION;
  appId: string;
  boundAtMillis: number;
}

export function readAppIdFromCallableRequest(request: CallableRequest): string | undefined {
  const appCheck = "app" in request ? request.app : undefined;
  return isRecord(appCheck) && typeof appCheck.appId === "string" ? appCheck.appId : undefined;
}

export function readAppCheckAttestationClaim(
  token: Record<string, unknown> | undefined,
): OpenBurnBarAppCheckAttestationClaim | undefined {
  if (!token) return undefined;
  const raw = token[APP_CHECK_ATTESTATION_CLAIM_KEY];
  if (!isRecord(raw)) return undefined;
  if (raw.v !== APP_CHECK_ATTESTATION_CLAIM_VERSION) return undefined;
  if (typeof raw.appId !== "string" || raw.appId.length === 0) return undefined;
  if (typeof raw.boundAtMillis !== "number" || !Number.isFinite(raw.boundAtMillis)) return undefined;
  return {
    v: APP_CHECK_ATTESTATION_CLAIM_VERSION,
    appId: raw.appId,
    boundAtMillis: raw.boundAtMillis,
  };
}

export function isAppCheckAttestationClaimFresh(
  claim: OpenBurnBarAppCheckAttestationClaim,
  nowMillis: number = Date.now(),
): boolean {
  return nowMillis - claim.boundAtMillis <= APP_CHECK_ATTESTATION_MAX_AGE_MS;
}

/**
 * SHA-256 hex digest placed in `attestationHashBlake3` on phone-control envelopes.
 * (Field name is historical; digest algorithm is SHA-256, shared with Swift.)
 */
export function appCheckAttestationDigestHex(
  appId: string,
  boundAtMillis: number,
): string {
  const payload = `${APP_CHECK_ATTESTATION_DIGEST_PREFIX}|${appId}|${boundAtMillis}`;
  return createHash("sha256").update(payload).digest("hex");
}

/**
 * Bind the caller's Firebase Auth custom claims to the current App Check app id.
 */
export async function bindAppCheckAttestationForUid(
  uid: string,
  appId: string,
  nowMillis: number = Date.now(),
): Promise<OpenBurnBarAppCheckAttestationClaim> {
  const claim: OpenBurnBarAppCheckAttestationClaim = {
    v: APP_CHECK_ATTESTATION_CLAIM_VERSION,
    appId,
    boundAtMillis: nowMillis,
  };
  const auth = getAuth();
  const user = await auth.getUser(uid);
  const existing = (user.customClaims ?? {}) as Record<string, unknown>;
  await auth.setCustomUserClaims(uid, {
    ...existing,
    [APP_CHECK_ATTESTATION_CLAIM_KEY]: claim,
  });
  return claim;
}

/**
 * Require a fresh App-Attest-bound custom claim that matches the callable App Check token.
 *
 * Skipped when `enforceAppCheck` is false (local emulation).
 */
export function assertAppAttestBoundClaims(request: CallableRequest): void {
  if (!getConfig().enforceAppCheck) return;

  assertAuth(request);
  assertAppCheck(request);

  const liveAppId = readAppIdFromCallableRequest(request);
  if (!liveAppId) {
    throw new functions.HttpsError("unauthenticated", "App Check attestation is required.");
  }

  const token = request.auth?.token as Record<string, unknown> | undefined;
  const claim = readAppCheckAttestationClaim(token);
  if (!claim) {
    throw new functions.HttpsError(
      "failed-precondition",
      "Call bindAppCheckAttestation after sign-in before high-risk Computer Use actions.",
    );
  }
  if (claim.appId !== liveAppId) {
    throw new functions.HttpsError(
      "permission-denied",
      "App Check attestation binding does not match this app instance.",
    );
  }
  if (!isAppCheckAttestationClaimFresh(claim)) {
    throw new functions.HttpsError(
      "failed-precondition",
      "App Check attestation binding expired. Call bindAppCheckAttestation again.",
    );
  }
}

/**
 * Auth + App Check + ownership + attestation-bound claims for high-risk mutations.
 */
export function enforceHighRiskComputerUseCallable(request: CallableRequest, expectedUid: string): void {
  assertAuth(request);
  assertAppCheck(request);
  assertOwnership(request, expectedUid);
  assertAppAttestBoundClaims(request);
}
