/**
 * signalActivationReadiness — pre-flip readiness gate for Signal at-rest sealing.
 *
 * The at-rest producers fail OPEN to legacy when a trusted device has not published a
 * Signal identity, so activation never loses data — but it also means Signal coverage is
 * incomplete until every trusted device has published. This callable reports, for the
 * caller's OWN account, whether all `trustState == "trusted"` escrow devices have a valid
 * `signal_identity_public_keys/{deviceId}_{keyVersion}` doc. The activation runbook calls
 * it per-cohort and only ramps the Remote Config kill switch where readiness is 100%.
 *
 * Owner-scoped (rules are owner-only read); the Admin SDK bypasses rules, so the callable
 * re-derives everything from the caller's uid. The pure core is unit-tested without the
 * emulator; the callable is the thin Firestore wiring.
 */
import { onCall, HttpsError, type CallableRequest } from "firebase-functions/v2/https";

import { getConfig } from "../config.js";
import { db } from "../adminRuntime.js";
import { enforceAuthAndAppCheck } from "../auth.js";
import { logInfo, wrapCallableHandler } from "../logging.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";

const CALLABLE_OPTS = {
  region: FUNCTIONS_REGION,
  enforceAppCheck: getConfig().enforceAppCheck,
  maxInstances: 50,
} as const;

// Mirrors packages/signal-envelope-contracts SIGNAL_AT_REST_ENCRYPTION + the rules.
const SIGNAL_AT_REST_ENCRYPTION = "signal-hpke-identity-seal-v1";

export interface ReadinessTrustedDevice {
  deviceId: string;
  keyVersion: number | null;
}

export interface ReadinessIdentity {
  algorithm?: unknown;
  publicKeyData?: unknown;
}

export interface SignalActivationReadinessResult {
  ready: boolean;
  total: number;
  published: number;
  missing: Array<{ deviceId: string; keyVersion: number | null; reason: string }>;
}

/**
 * Pure readiness computation — no Firestore. `ready` is true only when there is at least
 * one trusted device and EVERY trusted device has a valid published Signal identity.
 */
export function computeSignalActivationReadiness(
  trusted: ReadinessTrustedDevice[],
  identityByKeyId: Map<string, ReadinessIdentity>,
): SignalActivationReadinessResult {
  let published = 0;
  const missing: SignalActivationReadinessResult["missing"] = [];
  for (const device of trusted) {
    if (device.keyVersion === null || !Number.isInteger(device.keyVersion)) {
      missing.push({ deviceId: device.deviceId, keyVersion: device.keyVersion, reason: "no-keyVersion" });
      continue;
    }
    const identityKeyId = `${device.deviceId}_${device.keyVersion}`;
    const identity = identityByKeyId.get(identityKeyId);
    const valid =
      !!identity &&
      identity.algorithm === SIGNAL_AT_REST_ENCRYPTION &&
      typeof identity.publicKeyData === "string" &&
      (identity.publicKeyData as string).length > 0;
    if (valid) {
      published += 1;
    } else {
      missing.push({
        deviceId: device.deviceId,
        keyVersion: device.keyVersion,
        reason: identity ? "invalid-identity" : "no-identity",
      });
    }
  }
  const total = trusted.length;
  return { ready: total > 0 && missing.length === 0, total, published, missing };
}

function requireUid(request: CallableRequest): string {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in to check Signal activation readiness.");
  enforceAuthAndAppCheck(request, uid);
  return uid;
}

export const signalActivationReadiness = onCall(
  CALLABLE_OPTS,
  wrapCallableHandler("signalActivationReadiness", async (request: CallableRequest) => {
    const uid = requireUid(request);
    const userRef = db.collection("users").doc(uid);

    const trustedSnap = await userRef
      .collection("escrow_devices")
      .where("trustState", "==", "trusted")
      .get();

    const trusted: ReadinessTrustedDevice[] = trustedSnap.docs.map((doc) => {
      const data = doc.data();
      const rawDeviceId = typeof data.deviceId === "string" ? data.deviceId.trim() : "";
      const deviceId = rawDeviceId.length > 0 ? rawDeviceId : doc.id;
      const keyVersion = typeof data.keyVersion === "number" ? data.keyVersion : null;
      return { deviceId, keyVersion };
    });

    const identityByKeyId = new Map<string, ReadinessIdentity>();
    await Promise.all(
      trusted
        .filter((device) => device.keyVersion !== null)
        .map(async (device) => {
          const identityKeyId = `${device.deviceId}_${device.keyVersion}`;
          const snap = await userRef.collection("signal_identity_public_keys").doc(identityKeyId).get();
          if (snap.exists) {
            const data = snap.data() ?? {};
            identityByKeyId.set(identityKeyId, {
              algorithm: data.algorithm,
              publicKeyData: data.publicKeyData,
            });
          }
        }),
    );

    const result = computeSignalActivationReadiness(trusted, identityByKeyId);
    logInfo({
      event: "signalActivationReadiness",
      uid,
      total: result.total,
      published: result.published,
      ready: result.ready,
    });
    return result;
  }),
);

export const __testing__ = { computeSignalActivationReadiness };
