/**
 * @fileoverview Hermes relay pairing and connection callables
 */

import { Timestamp } from "firebase-admin/firestore";
import { HttpsError, onCall, type CallableRequest } from "firebase-functions/v2/https";

import { getConfig } from "../config.js";
import { enforceAuthAndAppCheck } from "../auth.js";
import { db } from "../adminRuntime.js";
import { logInfo } from "../logging.js";
import {
  HERMES_SCHEMA_VERSION,
  HERMES_PAIRING_TTL_MS,
  HERMES_MAX_FAILED_PAIRING_ATTEMPTS,
  nowISO,
  safeIdentifier,
  requiredIdentifier,
  boundedTrimmedString,
  writeHermesAuditEvent,
  assertActiveHostedQuotaEntitlement,
  checkHermesRateLimit,
} from "./shared.js";
import { randomBytes } from "node:crypto";
import {
  isHermesConnectionDoc,
  pairingCodeDigest,
  parseHermesConnectionMode,
  parseHermesPlatform,
  randomPairingCode,
  requireHermesPairingDoc,
  safeEqualHex,
  sanitizeHermesCapabilities,
  validateHermesEndpointURL,
} from "../hermes.js";
import { recordOrUndefined, stripUndefinedObject } from "../guards.js";
import type { HermesConnectionDoc, HermesConnectionMode, HermesPairingDoc } from "../types.js";

// ---------------------------------------------------------------------------
// Callable: Hermes pairing and connection management
// ---------------------------------------------------------------------------

export const createHermesPairing = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (
    request: CallableRequest<{
      deviceId?: string;
      platform?: "ios" | "ipados" | "macos" | "web";
      displayName?: string;
    }>
  ) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in before creating a Hermes pairing.");
    }
    enforceAuthAndAppCheck(request, uid);
    await assertActiveHostedQuotaEntitlement(uid);
    await checkHermesRateLimit(uid, "create_pairing", 5);

    const code = randomPairingCode();
    const id = `pair_${randomBytes(12).toString("hex")}`;
    const now = nowISO();
    const expiresAt = new Date(Date.now() + HERMES_PAIRING_TTL_MS).toISOString();
    const expireAt = Timestamp.fromMillis(Date.now() + HERMES_PAIRING_TTL_MS);
    const doc: HermesPairingDoc = {
      id,
      status: "pending",
      codeHash: pairingCodeDigest(code),
      failedAttempts: 0,
      requestedByDeviceId: boundedTrimmedString(request.data.deviceId, "deviceId", 128),
      requestedByPlatform: parseHermesPlatform(request.data.platform),
      displayName: boundedTrimmedString(request.data.displayName, "displayName", 80),
      expiresAt,
      expireAt,
      createdAt: now,
      updatedAt: now,
      schemaVersion: HERMES_SCHEMA_VERSION,
    };

    await db.doc(`users/${uid}/hermes_pairings/${id}`).set(stripUndefinedObject(doc));
    await writeHermesAuditEvent(uid, {
      eventType: "pairing_created",
      pairingId: id,
      actorDeviceId: doc.requestedByDeviceId,
    });

    logInfo({ event: "callable_info", message: "hermes_pairing_created", pairing_id: id });
    return { id, code, expiresAt };
  }
);

export const completeHermesPairing = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (
    request: CallableRequest<{
      pairingId: string;
      code: string;
      connectionId?: string;
      displayName?: string;
      mode?: HermesConnectionMode;
      profileName?: string;
      endpointURL?: string;
      advertisedModel?: string;
      capabilities?: string[];
      deviceId?: string;
    }>
  ) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in before completing a Hermes pairing.");
    }
    enforceAuthAndAppCheck(request, uid);
    await assertActiveHostedQuotaEntitlement(uid);
    await checkHermesRateLimit(uid, "complete_pairing", 1);

    const pairingId = requiredIdentifier(request.data.pairingId, "pairingId");
    const code = boundedTrimmedString(request.data.code, "code", 32, true);
    if (!code) {
      throw new HttpsError("invalid-argument", "code is required.");
    }

    const pairingRef = db.doc(`users/${uid}/hermes_pairings/${pairingId}`);
    const connectionId = safeIdentifier(request.data.connectionId, "hermes");
    const connectionRef = db.doc(`users/${uid}/hermes_connections/${connectionId}`);
    const now = nowISO();
    let failedAttempt = false;

    let connection: HermesConnectionDoc;
    try {
      connection = await db.runTransaction(async (tx) => {
      const pairingSnap = await tx.get(pairingRef);
      if (!pairingSnap.exists) {
        throw new HttpsError("not-found", "Pairing session not found.");
      }
      const pairing = requireHermesPairingDoc(pairingSnap.data());
      if (Date.parse(pairing.expiresAt) <= Date.now() && pairing.status === "pending") {
        tx.set(pairingRef, { status: "expired", updatedAt: now }, { merge: true });
        throw new HttpsError("deadline-exceeded", "Pairing code has expired.");
      }
      if (!safeEqualHex(pairingCodeDigest(code), pairing.codeHash)) {
        failedAttempt = true;
        const failedAttempts = (pairing.failedAttempts ?? 0) + 1;
        tx.set(
          pairingRef,
          {
            failedAttempts,
            status: failedAttempts >= HERMES_MAX_FAILED_PAIRING_ATTEMPTS ? "revoked" : pairing.status,
            updatedAt: now,
          },
          { merge: true }
        );
        throw new HttpsError("permission-denied", "Pairing code mismatch.");
      }
      if (pairing.status === "completed") {
        const completedConnectionId = pairing.connectionId ?? connectionId;
        const existingSnap = await tx.get(db.doc(`users/${uid}/hermes_connections/${completedConnectionId}`));
        const existing = recordOrUndefined(existingSnap.data());
        if (existingSnap.exists && existing && isHermesConnectionDoc(existing)) {
          return existing;
        }
        throw new HttpsError("failed-precondition", "Pairing is completed but its connection is unavailable.");
      }
      if (pairing.status !== "pending") {
        throw new HttpsError("failed-precondition", "Pairing session is no longer pending.");
      }

      const mode = parseHermesConnectionMode(request.data.mode ?? "directURL");
      const endpointURL = validateHermesEndpointURL(request.data.endpointURL, mode);
      const capabilities = sanitizeHermesCapabilities(request.data.capabilities);
      const displayName =
        boundedTrimmedString(request.data.displayName, "displayName", 80) ??
        pairing.displayName ??
        "Hermes Host";
      const doc: HermesConnectionDoc = {
        id: connectionId,
        displayName,
        mode,
        status: "online",
        profileName: boundedTrimmedString(request.data.profileName, "profileName", 80),
        endpointURL,
        advertisedModel: boundedTrimmedString(request.data.advertisedModel, "advertisedModel", 160),
        capabilities,
        lastSeenAt: now,
        createdAt: now,
        updatedAt: now,
        schemaVersion: HERMES_SCHEMA_VERSION,
      };
      tx.set(connectionRef, stripUndefinedObject(doc), { merge: true });
      tx.set(
        pairingRef,
        { status: "completed", connectionId, updatedAt: now },
        { merge: true }
      );
      return doc;
      });
    } catch (err) {
      if (failedAttempt) {
        await writeHermesAuditEvent(uid, {
          eventType: "pairing_failed",
          connectionId,
          pairingId,
          actorDeviceId: boundedTrimmedString(request.data.deviceId, "deviceId", 128),
        });
      }
      throw err;
    }

    await writeHermesAuditEvent(uid, {
      eventType: "pairing_completed",
      connectionId,
      pairingId,
      actorDeviceId: boundedTrimmedString(request.data.deviceId, "deviceId", 128),
    });
    await writeHermesAuditEvent(uid, {
      eventType: "connection_created",
      connectionId: connection.id,
      pairingId,
      actorDeviceId: boundedTrimmedString(request.data.deviceId, "deviceId", 128),
      detail: { mode: connection.mode },
    });

    logInfo({
      event: "callable_info",
      message: "hermes_pairing_completed",
      pairing_id: pairingId,
      connection_id: connection.id,
    });
    return stripUndefinedObject(connection);
  }
);

export const listHermesConnections = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (request: CallableRequest<{ includeRevoked?: boolean }>) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in before listing Hermes connections.");
    }
    enforceAuthAndAppCheck(request, uid);
    await assertActiveHostedQuotaEntitlement(uid);

    const snap = await db.collection(`users/${uid}/hermes_connections`).get();
    const connections = snap.docs
      .flatMap((doc): HermesConnectionDoc[] => {
        const data = recordOrUndefined(doc.data());
        return data && isHermesConnectionDoc(data) ? [data] : [];
      })
      .filter((doc) => request.data.includeRevoked === true || doc.status !== "revoked")
      .sort((left, right) => right.updatedAt.localeCompare(left.updatedAt));
    return { connections };
  }
);

export const revokeHermesConnection = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (request: CallableRequest<{ connectionId: string; deviceId?: string }>) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in before revoking a Hermes connection.");
    }
    enforceAuthAndAppCheck(request, uid);
    await assertActiveHostedQuotaEntitlement(uid);
    await checkHermesRateLimit(uid, "revoke_connection", 2);

    const connectionId = requiredIdentifier(request.data.connectionId, "connectionId");
    const now = nowISO();
    const ref = db.doc(`users/${uid}/hermes_connections/${connectionId}`);
    await db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      if (!snap.exists) {
        throw new HttpsError("not-found", "Hermes connection not found.");
      }
      tx.update(ref, { status: "revoked", updatedAt: now });
    });
    await writeHermesAuditEvent(uid, {
      eventType: "connection_revoked",
      connectionId,
      actorDeviceId: boundedTrimmedString(request.data.deviceId, "deviceId", 128),
    });
    logInfo({ event: "callable_info", message: "hermes_connection_revoked", connection_id: connectionId });
    return { success: true, connectionId };
  }
);

export const updateHermesConnectionStatus = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (
    request: CallableRequest<{
      connectionId: string;
      status: HermesConnectionDoc["status"];
      advertisedModel?: string;
      capabilities?: string[];
      deviceId?: string;
    }>
  ) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in before updating a Hermes connection.");
    }
    enforceAuthAndAppCheck(request, uid);
    await assertActiveHostedQuotaEntitlement(uid);
    await checkHermesRateLimit(uid, "update_connection_status", 2);

    const allowedStatus = new Set<HermesConnectionDoc["status"]>([
      "pending",
      "online",
      "offline",
      "unauthorized",
      "revoked",
      "degraded",
    ]);
    if (!allowedStatus.has(request.data.status)) {
      throw new HttpsError("invalid-argument", "Unknown Hermes connection status.");
    }

    const connectionId = requiredIdentifier(request.data.connectionId, "connectionId");
    const now = nowISO();
    const update: Partial<HermesConnectionDoc> = {
      status: request.data.status,
      updatedAt: now,
    };
    const advertisedModel = boundedTrimmedString(request.data.advertisedModel, "advertisedModel", 160);
    if (advertisedModel) {
      update.advertisedModel = advertisedModel;
    }
    if (request.data.status === "online") {
      update.lastSeenAt = now;
    }
    if (Array.isArray(request.data.capabilities)) {
      update.capabilities = sanitizeHermesCapabilities(request.data.capabilities);
    }
    const ref = db.doc(`users/${uid}/hermes_connections/${connectionId}`);
    await db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      if (!snap.exists) {
        throw new HttpsError("not-found", "Hermes connection not found.");
      }
      const current = recordOrUndefined(snap.data());
      if (!current || !isHermesConnectionDoc(current)) {
        throw new HttpsError("failed-precondition", "Hermes connection document is invalid.");
      }
      if (current.status === "revoked") {
        throw new HttpsError("failed-precondition", "Revoked Hermes connections cannot be reactivated.");
      }
      tx.update(ref, update);
    });
    await writeHermesAuditEvent(uid, {
      eventType: "connection_status_updated",
      connectionId,
      actorDeviceId: boundedTrimmedString(request.data.deviceId, "deviceId", 128),
      detail: { status: request.data.status },
    });
    return { success: true, connectionId };
  }
);

