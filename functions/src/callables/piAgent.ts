/**
 * @fileoverview Pi Agent relay pairing and connection callables
 */

import { Timestamp } from "firebase-admin/firestore";
import { HttpsError, onCall, type CallableRequest } from "firebase-functions/v2/https";

import { getConfig } from "../config.js";
import { enforceAuthAndAppCheck } from "../auth.js";
import { db } from "../adminRuntime.js";
import { logInfo } from "../logging.js";
import {
  PI_AGENT_SCHEMA_VERSION,
  PI_AGENT_PAIRING_TTL_MS,
  PI_AGENT_MAX_FAILED_PAIRING_ATTEMPTS,
  nowISO,
  safeIdentifier,
  requiredIdentifier,
  boundedTrimmedString,
  writePiAgentAuditEvent,
  assertActiveHostedQuotaEntitlement,
  checkPiAgentRateLimit,
} from "./shared.js";
import { randomBytes } from "node:crypto";
import {
  isPiAgentConnectionDoc,
  piAgentPairingCodeDigest,
  piAgentSafeEqualHex,
  parsePiAgentConnectionMode,
  parsePiAgentPlatform,
  randomPiAgentPairingCode,
  requirePiAgentPairingDoc,
  sanitizePiAgentCapabilities,
  sanitizePiAgentInstances,
  sanitizePiAgentModels,
  validatePiAgentEndpointURL,
} from "../piAgent.js";
import { recordOrUndefined, stripUndefinedObject } from "../guards.js";
import type { PiAgentConnectionDoc, PiAgentConnectionMode, PiAgentPairingDoc } from "../types.js";

// ---------------------------------------------------------------------------
// Callable: Pi Agent pairing and connection management
// ---------------------------------------------------------------------------

export const createPiAgentPairing = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (
    request: CallableRequest<{
      deviceId?: string;
      platform?: "ios" | "ipados" | "android" | "macos" | "web";
      displayName?: string;
    }>
  ) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in before creating a Pi Agent pairing.");
    }
    enforceAuthAndAppCheck(request, uid);
    await assertActiveHostedQuotaEntitlement(uid);
    await checkPiAgentRateLimit(uid, "create_pairing", 5);

    const code = randomPiAgentPairingCode();
    const id = `pair_${randomBytes(12).toString("hex")}`;
    const now = nowISO();
    const expiresAt = new Date(Date.now() + PI_AGENT_PAIRING_TTL_MS).toISOString();
    const expireAt = Timestamp.fromMillis(Date.now() + PI_AGENT_PAIRING_TTL_MS);
    const doc: PiAgentPairingDoc = {
      id,
      status: "pending",
      codeHash: piAgentPairingCodeDigest(code),
      failedAttempts: 0,
      requestedByDeviceId: boundedTrimmedString(request.data.deviceId, "deviceId", 128),
      requestedByPlatform: parsePiAgentPlatform(request.data.platform),
      displayName: boundedTrimmedString(request.data.displayName, "displayName", 80),
      expiresAt,
      expireAt,
      createdAt: now,
      updatedAt: now,
      schemaVersion: PI_AGENT_SCHEMA_VERSION,
    };

    await db.doc(`users/${uid}/pi_agent_pairings/${id}`).set(stripUndefinedObject(doc));
    await writePiAgentAuditEvent(uid, {
      eventType: "pairing_created",
      pairingId: id,
      actorDeviceId: doc.requestedByDeviceId,
    });

    logInfo({ event: "callable_info", message: "pi_agent_pairing_created", pairing_id: id });
    return { id, code, expiresAt };
  }
);

export const completePiAgentPairing = onCall(
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
      mode?: PiAgentConnectionMode;
      endpointURL?: string;
      advertisedModel?: string;
      selectedInstanceID?: string;
      redisURL?: string;
      capabilities?: string[];
      instances?: unknown[];
      models?: unknown[];
      relayPublicKey?: string;
      relayKeyVersion?: number;
      relayEncryption?: string;
      realtimeRelayURL?: string;
      realtimeRelayStatus?: string;
      deviceId?: string;
    }>
  ) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in before completing a Pi Agent pairing.");
    }
    enforceAuthAndAppCheck(request, uid);
    await assertActiveHostedQuotaEntitlement(uid);
    await checkPiAgentRateLimit(uid, "complete_pairing", 1);

    const pairingId = requiredIdentifier(request.data.pairingId, "pairingId");
    const code = boundedTrimmedString(request.data.code, "code", 32, true);
    if (!code) {
      throw new HttpsError("invalid-argument", "code is required.");
    }

    const pairingRef = db.doc(`users/${uid}/pi_agent_pairings/${pairingId}`);
    const connectionId = safeIdentifier(request.data.connectionId, "pi_agent");
    const connectionRef = db.doc(`users/${uid}/pi_agent_connections/${connectionId}`);
    const now = nowISO();
    let failedAttempt = false;

    let connection: PiAgentConnectionDoc;
    try {
      connection = await db.runTransaction(async (tx) => {
        const pairingSnap = await tx.get(pairingRef);
        if (!pairingSnap.exists) {
          throw new HttpsError("not-found", "Pi Agent pairing session not found.");
        }
        const pairing = requirePiAgentPairingDoc(pairingSnap.data());
        if (Date.parse(pairing.expiresAt) <= Date.now() && pairing.status === "pending") {
          tx.set(pairingRef, { status: "expired", updatedAt: now }, { merge: true });
          throw new HttpsError("deadline-exceeded", "Pairing code has expired.");
        }
        if (!piAgentSafeEqualHex(piAgentPairingCodeDigest(code), pairing.codeHash)) {
          failedAttempt = true;
          const failedAttempts = (pairing.failedAttempts ?? 0) + 1;
          tx.set(
            pairingRef,
            {
              failedAttempts,
              status: failedAttempts >= PI_AGENT_MAX_FAILED_PAIRING_ATTEMPTS ? "revoked" : pairing.status,
              updatedAt: now,
            },
            { merge: true }
          );
          throw new HttpsError("permission-denied", "Pairing code mismatch.");
        }
        if (pairing.status === "completed") {
          const completedConnectionId = pairing.connectionId ?? connectionId;
          const existingSnap = await tx.get(db.doc(`users/${uid}/pi_agent_connections/${completedConnectionId}`));
          const existing = recordOrUndefined(existingSnap.data());
          if (existingSnap.exists && existing && isPiAgentConnectionDoc(existing)) {
            return existing;
          }
          throw new HttpsError("failed-precondition", "Pairing is completed but its connection is unavailable.");
        }
        if (pairing.status !== "pending") {
          throw new HttpsError("failed-precondition", "Pairing session is no longer pending.");
        }

        const mode = parsePiAgentConnectionMode(request.data.mode ?? "directURL");
        const endpointURL = validatePiAgentEndpointURL(request.data.endpointURL, mode);
        const capabilities = sanitizePiAgentCapabilities(request.data.capabilities);
        const displayName =
          boundedTrimmedString(request.data.displayName, "displayName", 80) ??
          pairing.displayName ??
          "Pi Agent Host";
        const doc: PiAgentConnectionDoc = {
          id: connectionId,
          displayName,
          mode,
          status: "online",
          endpointURL,
          advertisedModel: boundedTrimmedString(request.data.advertisedModel, "advertisedModel", 160),
          selectedInstanceID: boundedTrimmedString(request.data.selectedInstanceID, "selectedInstanceID", 128),
          redisURL: boundedTrimmedString(request.data.redisURL, "redisURL", 2048),
          relayPublicKey: boundedTrimmedString(request.data.relayPublicKey, "relayPublicKey", 256),
          relayKeyVersion: typeof request.data.relayKeyVersion === "number" ? request.data.relayKeyVersion : undefined,
          relayEncryption: boundedTrimmedString(request.data.relayEncryption, "relayEncryption", 80),
          realtimeRelayURL: boundedTrimmedString(request.data.realtimeRelayURL, "realtimeRelayURL", 2048),
          realtimeRelayStatus: boundedTrimmedString(request.data.realtimeRelayStatus, "realtimeRelayStatus", 40),
          capabilities,
          instances: sanitizePiAgentInstances(request.data.instances),
          models: sanitizePiAgentModels(request.data.models),
          lastSeenAt: now,
          createdAt: now,
          updatedAt: now,
          schemaVersion: PI_AGENT_SCHEMA_VERSION,
        };
        tx.set(connectionRef, stripUndefinedObject(doc), { merge: true });
        tx.set(pairingRef, { status: "completed", connectionId, updatedAt: now }, { merge: true });
        return doc;
      });
    } catch (err) {
      if (failedAttempt) {
        await writePiAgentAuditEvent(uid, {
          eventType: "pairing_failed",
          connectionId,
          pairingId,
          actorDeviceId: boundedTrimmedString(request.data.deviceId, "deviceId", 128),
        });
      }
      throw err;
    }

    await writePiAgentAuditEvent(uid, {
      eventType: "pairing_completed",
      connectionId,
      pairingId,
      actorDeviceId: boundedTrimmedString(request.data.deviceId, "deviceId", 128),
    });
    await writePiAgentAuditEvent(uid, {
      eventType: "connection_created",
      connectionId: connection.id,
      pairingId,
      actorDeviceId: boundedTrimmedString(request.data.deviceId, "deviceId", 128),
      detail: { mode: connection.mode },
    });

    logInfo({
      event: "callable_info",
      message: "pi_agent_pairing_completed",
      pairing_id: pairingId,
      connection_id: connection.id,
    });
    return stripUndefinedObject(connection);
  }
);

export const listPiAgentConnections = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (request: CallableRequest<{ includeRevoked?: boolean }>) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in before listing Pi Agent connections.");
    }
    enforceAuthAndAppCheck(request, uid);
    await assertActiveHostedQuotaEntitlement(uid);

    const snap = await db.collection(`users/${uid}/pi_agent_connections`).get();
    const connections = snap.docs
      .flatMap((doc): PiAgentConnectionDoc[] => {
        const data = recordOrUndefined(doc.data());
        return data && isPiAgentConnectionDoc(data) ? [data] : [];
      })
      .filter((doc) => request.data.includeRevoked === true || doc.status !== "revoked")
      .sort((left, right) => right.updatedAt.localeCompare(left.updatedAt));
    return { connections };
  }
);

export const revokePiAgentConnection = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (request: CallableRequest<{ connectionId: string; deviceId?: string }>) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in before revoking a Pi Agent connection.");
    }
    enforceAuthAndAppCheck(request, uid);
    await assertActiveHostedQuotaEntitlement(uid);
    await checkPiAgentRateLimit(uid, "revoke_connection", 2);

    const connectionId = requiredIdentifier(request.data.connectionId, "connectionId");
    const now = nowISO();
    const ref = db.doc(`users/${uid}/pi_agent_connections/${connectionId}`);
    await db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      if (!snap.exists) {
        throw new HttpsError("not-found", "Pi Agent connection not found.");
      }
      tx.update(ref, { status: "revoked", updatedAt: now });
    });
    await writePiAgentAuditEvent(uid, {
      eventType: "connection_revoked",
      connectionId,
      actorDeviceId: boundedTrimmedString(request.data.deviceId, "deviceId", 128),
    });
    logInfo({ event: "callable_info", message: "pi_agent_connection_revoked", connection_id: connectionId });
    return { success: true, connectionId };
  }
);

export const updatePiAgentConnectionStatus = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (
    request: CallableRequest<{
      connectionId: string;
      status: PiAgentConnectionDoc["status"];
      advertisedModel?: string;
      selectedInstanceID?: string;
      capabilities?: string[];
      instances?: unknown[];
      models?: unknown[];
      deviceId?: string;
    }>
  ) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in before updating a Pi Agent connection.");
    }
    enforceAuthAndAppCheck(request, uid);
    await assertActiveHostedQuotaEntitlement(uid);
    await checkPiAgentRateLimit(uid, "update_connection_status", 2);

    const allowedStatus = new Set<PiAgentConnectionDoc["status"]>([
      "pending",
      "online",
      "offline",
      "unauthorized",
      "revoked",
      "degraded",
    ]);
    if (!allowedStatus.has(request.data.status)) {
      throw new HttpsError("invalid-argument", "Unknown Pi Agent connection status.");
    }

    const connectionId = requiredIdentifier(request.data.connectionId, "connectionId");
    const now = nowISO();
    const update: Partial<PiAgentConnectionDoc> = {
      status: request.data.status,
      updatedAt: now,
    };
    const advertisedModel = boundedTrimmedString(request.data.advertisedModel, "advertisedModel", 160);
    if (advertisedModel) {
      update.advertisedModel = advertisedModel;
    }
    const selectedInstanceID = boundedTrimmedString(request.data.selectedInstanceID, "selectedInstanceID", 128);
    if (selectedInstanceID) {
      update.selectedInstanceID = selectedInstanceID;
    }
    if (request.data.status === "online") {
      update.lastSeenAt = now;
    }
    if (Array.isArray(request.data.capabilities)) {
      update.capabilities = sanitizePiAgentCapabilities(request.data.capabilities);
    }
    if (Array.isArray(request.data.instances)) {
      update.instances = sanitizePiAgentInstances(request.data.instances);
    }
    if (Array.isArray(request.data.models)) {
      update.models = sanitizePiAgentModels(request.data.models);
    }
    const ref = db.doc(`users/${uid}/pi_agent_connections/${connectionId}`);
    await db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      if (!snap.exists) {
        throw new HttpsError("not-found", "Pi Agent connection not found.");
      }
      const current = recordOrUndefined(snap.data());
      if (!current || !isPiAgentConnectionDoc(current)) {
        throw new HttpsError("failed-precondition", "Pi Agent connection document is invalid.");
      }
      if (current.status === "revoked") {
        throw new HttpsError("failed-precondition", "Revoked Pi Agent connections cannot be reactivated.");
      }
      tx.update(ref, update);
    });
    await writePiAgentAuditEvent(uid, {
      eventType: "connection_status_updated",
      connectionId,
      actorDeviceId: boundedTrimmedString(request.data.deviceId, "deviceId", 128),
      detail: { status: request.data.status },
    });
    return { success: true, connectionId };
  }
);

