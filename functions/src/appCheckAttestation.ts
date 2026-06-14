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
import { isRecord, recordOrUndefined } from "./guards.js";

/** Matches Swift `AppCheckAttestationBinding.canonicalPrefix`. */
const APP_CHECK_ATTESTATION_DIGEST_PREFIX = "openburnbar.appcheck.v1";

export const APP_CHECK_ATTESTATION_CLAIM_KEY = "obb_app_check" as const;
const APP_CHECK_ATTESTATION_CLAIM_VERSION = 1 as const;
/** Re-bind after this many days so stale device attestations expire. */
export const APP_CHECK_ATTESTATION_MAX_AGE_MS = 30 * 24 * 60 * 60 * 1000;

/** Per-call replay-resistance nonce TTL (single-use, short-lived). */
export const HIGH_RISK_NONCE_TTL_MS = 2 * 60 * 1000; // 2 minutes
/** Firestore subcollection holding outstanding single-use high-risk nonces. */
const HIGH_RISK_NONCE_COLLECTION = "high_risk_action_nonces" as const;

interface OpenBurnBarAppCheckAttestationClaim {
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
export function appCheckAttestationDigestHex(appId: string, boundAtMillis: number): string {
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
  const existing = isRecord(user.customClaims) ? user.customClaims : {};
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
function assertAppAttestBoundClaims(request: CallableRequest): void {
  if (!getConfig().enforceAppCheck) return;

  assertAuth(request);
  assertAppCheck(request);

  const liveAppId = readAppIdFromCallableRequest(request);
  if (!liveAppId) {
    throw new functions.HttpsError("unauthenticated", "App Check attestation is required.");
  }

  const token = recordOrUndefined(request.auth?.token);
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

/**
 * Mint a single-use, short-lived high-risk action nonce scoped to a uid.
 *
 * The nonce is written under the server-only `high_risk_action_nonces`
 * subcollection (Firestore rules deny client read/write). It must be echoed by
 * the caller and atomically consumed by {@link consumeHighRiskNonceForUid} on
 * the subsequent high-risk action, defeating replay of a captured App Check +
 * ID-token pair within the 30-day attestation window.
 */
export async function issueHighRiskNonceForUid(
  uid: string,
  nowMillis: number = Date.now(),
): Promise<{ nonce: string; expiresAtMillis: number }> {
  const { randomBytes } = await import("node:crypto");
  const { db } = await import("./adminRuntime.js");
  const { Timestamp } = await import("firebase-admin/firestore");
  const nonce = randomBytes(32).toString("base64url");
  const expiresAtMillis = nowMillis + HIGH_RISK_NONCE_TTL_MS;
  await db.doc(`users/${uid}/${HIGH_RISK_NONCE_COLLECTION}/${nonce}`).set({
    nonce,
    createdAtMillis: nowMillis,
    expiresAtMillis,
    consumedAt: null,
    createdAt: Timestamp.fromMillis(nowMillis),
    expireAt: Timestamp.fromMillis(expiresAtMillis),
  });
  return { nonce, expiresAtMillis };
}

/**
 * Atomically consume a high-risk nonce for a uid. Fail-closed: a missing,
 * expired, malformed, or already-consumed nonce throws.
 */
export async function consumeHighRiskNonceForUid(
  uid: string,
  nonce: string,
  nowMillis: number = Date.now(),
): Promise<void> {
  if (typeof nonce !== "string" || nonce.length < 16 || nonce.length > 256) {
    throw new functions.HttpsError("failed-precondition", "A valid high-risk action nonce is required.");
  }
  const { db } = await import("./adminRuntime.js");
  const { Timestamp } = await import("firebase-admin/firestore");
  const ref = db.doc(`users/${uid}/${HIGH_RISK_NONCE_COLLECTION}/${nonce}`);
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const data = snap.data();
    if (
      !snap.exists ||
      !data ||
      data.consumedAt ||
      typeof data.expiresAtMillis !== "number" ||
      data.expiresAtMillis < nowMillis
    ) {
      throw new functions.HttpsError(
        "failed-precondition",
        "High-risk action nonce expired or was already used. Request a fresh nonce.",
      );
    }
    tx.update(ref, { consumedAt: Timestamp.fromMillis(nowMillis) });
  });
}

/**
 * Outcome of {@link enforceHighRiskComputerUseCallableWithNonce}.
 *
 * `nonceConsumed` reports whether a single-use nonce was actually presented and
 * atomically consumed on this call. It is `false` only when App Check is not
 * enforced (local/emulator) or when `requireHighRiskNonce` is off AND the client
 * supplied no nonce (staged-rollout back-compat). Callers that need a HARD nonce
 * requirement for a specific branch — e.g. bootstrap self-approval — must reject
 * when this is `false`, independent of the global flag.
 */
type HighRiskNonceEnforcementResult = { nonceConsumed: boolean };

/**
 * High-risk enforcement layered with single-use nonce replay defense.
 *
 * Runs the existing synchronous guard, then (when App Check is enforced)
 * consumes a supplied nonce. Staged rollout: with `requireHighRiskNonce` off a
 * missing nonce is tolerated for back-compat with in-flight clients; with the
 * flag on a missing nonce is rejected. A supplied-but-invalid nonce is ALWAYS
 * rejected (fail-closed) regardless of the flag.
 *
 * Returns whether a nonce was actually consumed so a caller can additionally
 * require one for an especially sensitive sub-path (see
 * {@link HighRiskNonceEnforcementResult}).
 */
export async function enforceHighRiskComputerUseCallableWithNonce(
  request: CallableRequest,
  expectedUid: string,
  nonce: unknown,
): Promise<HighRiskNonceEnforcementResult> {
  enforceHighRiskComputerUseCallable(request, expectedUid);
  if (!getConfig().enforceAppCheck) return { nonceConsumed: false };
  const supplied = typeof nonce === "string" && nonce.length > 0 ? nonce : undefined;
  if (!supplied) {
    if (getConfig().requireHighRiskNonce) {
      throw new functions.HttpsError(
        "failed-precondition",
        "Call issueHighRiskActionNonce and supply the nonce before this high-risk action.",
      );
    }
    return { nonceConsumed: false };
  }
  await consumeHighRiskNonceForUid(expectedUid, supplied);
  return { nonceConsumed: true };
}
