import { randomBytes } from "node:crypto";

import { FieldValue, Timestamp, type Transaction } from "firebase-admin/firestore";
import { HttpsError, type CallableRequest } from "firebase-functions/v2/https";

import { db } from "../adminRuntime.js";
import { enforceHighRiskComputerUseCallableWithNonce } from "../appCheckAttestation.js";
import { getConfig } from "../config.js";
import { logInfo, onCallProduction } from "../logging.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";
import {
  IROH_HOST_ESCROW_PLATFORMS,
  PHONE_CONTROL_ESCROW_PLATFORMS,
  boundedFirestoreDocumentId,
  boundedInteger,
  normalizedControllerDeviceAllowlist,
  requireBase64Like,
} from "./computerUseSecurityCodecs.js";
import {
  IROH_CONTROLLER_ROUTE_CHALLENGE_TTL_MS,
  IROH_CONTROLLER_ROUTE_TTL_MS,
  irohControllerRouteProofPayload,
  requireActiveIrohPairing,
  requireIrohTransportNodeId,
  requireVerifiedControllerAuthority,
  verifyIrohControllerAuthorityProof,
  verifyIrohControllerRouteProof,
} from "./irohControllerRouteSecurity.js";
import { assertActiveBurnBarCloudProEntitlement } from "./shared.js";

const ROUTE_SCHEMA_VERSION = 1;
const MAX_GENERATION = Number.MAX_SAFE_INTEGER - 1;

function requireRecord(
  snapshot: { exists: boolean; data(): Record<string, unknown> | undefined },
  message: string,
): Record<string, unknown> {
  const data = snapshot.exists ? snapshot.data() : undefined;
  if (!data) throw new HttpsError("failed-precondition", message);
  return data;
}

function requireTrustedDeviceRecord(
  device: Record<string, unknown>,
  deviceId: string,
  allowedPlatforms: ReadonlySet<string>,
): void {
  if (
    device.trustState !== "trusted" ||
    typeof device.platform !== "string" ||
    !allowedPlatforms.has(device.platform) ||
    (device.deviceId != null && device.deviceId !== deviceId)
  ) {
    throw new HttpsError("permission-denied", "Controller route requires a trusted same-user native device.");
  }
}

async function readRouteJoin(
  transaction: Transaction,
  uid: string,
  connectionId: string,
  sourceDeviceId: string,
  authorityPeerNodeId: string,
): Promise<{
  pairing: Record<string, unknown>;
  hostKey: Record<string, unknown>;
  hostDevice: Record<string, unknown>;
  sourceDevice: Record<string, unknown>;
  controller: Record<string, unknown>;
}> {
  const pairingRef = db.doc(`users/${uid}/iroh_pairing/${connectionId}`);
  const hostKeyRef = db.doc(`users/${uid}/iroh_pairing_keys/host`);
  const sourceDeviceRef = db.doc(`users/${uid}/escrow_devices/${sourceDeviceId}`);
  const controllerRef = db.doc(`users/${uid}/iroh_pairing/${connectionId}/controllers/${authorityPeerNodeId}`);
  const pairingSnapshot = await transaction.get(pairingRef);
  const pairing = requireRecord(pairingSnapshot, "Active iroh pairing not found.");
  const hostDeviceId = boundedFirestoreDocumentId(pairing.publishedByDeviceId, "pairing.publishedByDeviceId", 160);
  const hostDeviceRef = db.doc(`users/${uid}/escrow_devices/${hostDeviceId}`);
  const hostKey = requireRecord(await transaction.get(hostKeyRef), "Iroh host trust root not found.");
  const hostDevice = requireRecord(await transaction.get(hostDeviceRef), "Trusted iroh host device not found.");
  const sourceDevice = requireRecord(await transaction.get(sourceDeviceRef), "Trusted controller device not found.");
  const controller = requireRecord(await transaction.get(controllerRef), "Controller authority not found.");
  return { pairing, hostKey, hostDevice, sourceDevice, controller };
}

function verifyRouteJoin(args: {
  uid: string;
  connectionId: string;
  sourceDeviceId: string;
  authorityPeerNodeId: string;
  join: {
    pairing: Record<string, unknown>;
    hostKey: Record<string, unknown>;
    hostDevice: Record<string, unknown>;
    sourceDevice: Record<string, unknown>;
    controller: Record<string, unknown>;
  };
  nowMillis: number;
}): {
  authorityPublicKeySHA256: string;
  authorityPublicKey: Buffer;
  authorityKeyKind: "ed25519" | "se-p256";
  pairingPublishedAtMillis: number;
} {
  const allowlist = normalizedControllerDeviceAllowlist(args.join.pairing.authorizedControllerDeviceIds);
  if (allowlist.length !== 1 || allowlist[0] !== args.sourceDeviceId) {
    throw new HttpsError("permission-denied", "Iroh pairing does not have one unambiguous controller device.");
  }
  requireTrustedDeviceRecord(args.join.sourceDevice, args.sourceDeviceId, PHONE_CONTROL_ESCROW_PLATFORMS);
  if (args.join.sourceDevice.peerNodeId !== args.authorityPeerNodeId) {
    throw new HttpsError("permission-denied", "Controller authority is not the device's current peer binding.");
  }
  const hostDeviceId = boundedFirestoreDocumentId(
    args.join.pairing.publishedByDeviceId,
    "pairing.publishedByDeviceId",
    160,
  );
  requireTrustedDeviceRecord(args.join.hostDevice, hostDeviceId, IROH_HOST_ESCROW_PLATFORMS);
  const pairing = requireActiveIrohPairing({
    uid: args.uid,
    connectionId: args.connectionId,
    pairing: args.join.pairing,
    hostKey: args.join.hostKey,
    nowMillis: args.nowMillis,
  });
  const authority = requireVerifiedControllerAuthority({
    connectionId: args.connectionId,
    sourceDeviceId: args.sourceDeviceId,
    authorityPeerNodeId: args.authorityPeerNodeId,
    controller: args.join.controller,
  });
  return {
    authorityPublicKeySHA256: authority.authorityPublicKeySHA256,
    authorityPublicKey: authority.authorityPublicKey,
    authorityKeyKind: authority.authorityKeyKind,
    pairingPublishedAtMillis: pairing.publishedAtMillis,
  };
}

export const issueIrohControllerRouteChallenge = onCallProduction(
  "issueIrohControllerRouteChallenge",
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (
    request: CallableRequest<{
      sourceDeviceId?: unknown;
      connectionId?: unknown;
      authorityPeerNodeId?: unknown;
      transportNodeId?: unknown;
      nonce?: unknown;
    }>,
  ) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before issuing a controller-route challenge.");
    await enforceHighRiskComputerUseCallableWithNonce(request, uid, request.data.nonce);
    await assertActiveBurnBarCloudProEntitlement(uid);

    const sourceDeviceId = boundedFirestoreDocumentId(request.data.sourceDeviceId, "sourceDeviceId", 160);
    const connectionId = boundedFirestoreDocumentId(request.data.connectionId, "connectionId", 160);
    const authorityPeerNodeId = boundedFirestoreDocumentId(
      request.data.authorityPeerNodeId,
      "authorityPeerNodeId",
      160,
    );
    const { nodeId: transportNodeId } = requireIrohTransportNodeId(request.data.transportNodeId);
    const challengeId = randomBytes(16).toString("hex");
    const challengeNonce = randomBytes(32).toString("base64url");
    const issuedAtMillis = Date.now();
    const expiresAtMillis = issuedAtMillis + IROH_CONTROLLER_ROUTE_CHALLENGE_TTL_MS;
    const routeRef = db.doc(`users/${uid}/iroh_pairing/${connectionId}/controller_routes/${sourceDeviceId}`);
    const challengeRef = db.doc(`users/${uid}/iroh_controller_route_challenges/${challengeId}`);

    const result = await db.runTransaction(async (transaction) => {
      const join = await readRouteJoin(transaction, uid, connectionId, sourceDeviceId, authorityPeerNodeId);
      verifyRouteJoin({ uid, connectionId, sourceDeviceId, authorityPeerNodeId, join, nowMillis: issuedAtMillis });
      const existingRoute = await transaction.get(routeRef);
      const expectedPriorGeneration = existingRoute.exists
        ? (boundedInteger(existingRoute.get("generation"), "route.generation", 1, MAX_GENERATION, true) ?? 0)
        : 0;
      const registrationGeneration = expectedPriorGeneration + 1;
      const canonicalPayload = irohControllerRouteProofPayload({
        challengeId,
        challengeNonce,
        uid,
        connectionId,
        sourceDeviceId,
        transportNodeId,
        authorityPeerNodeId,
        registrationGeneration,
        issuedAtMillis,
        expiresAtMillis,
      });
      const canonicalPayloadBase64 = canonicalPayload.toString("base64");
      transaction.create(challengeRef, {
        challengeId,
        challengeNonce,
        connectionId,
        sourceDeviceId,
        transportNodeId,
        authorityPeerNodeId,
        expectedPriorGeneration,
        registrationGeneration,
        canonicalPayloadBase64,
        issuedAtMillis,
        expiresAtMillis,
        status: "pending",
        schemaVersion: ROUTE_SCHEMA_VERSION,
        expireAt: Timestamp.fromMillis(expiresAtMillis),
        createdAt: FieldValue.serverTimestamp(),
      });
      return { canonicalPayloadBase64, registrationGeneration };
    });

    logInfo({
      event: "callable_info",
      message: "iroh_controller_route_challenge_issued",
      connection_id: connectionId,
      source_device_id: sourceDeviceId,
      generation: result.registrationGeneration,
    });
    return {
      challengeId,
      canonicalPayloadBase64: result.canonicalPayloadBase64,
      signatureAlgorithm: "ed25519",
      registrationGeneration: result.registrationGeneration,
      issuedAtMillis,
      expiresAtMillis,
    };
  },
);

export const registerIrohControllerRoute = onCallProduction(
  "registerIrohControllerRoute",
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (
    request: CallableRequest<{
      challengeId?: unknown;
      transportSignatureBase64?: unknown;
      authoritySignatureBase64?: unknown;
    }>,
  ) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before registering a controller route.");
    await assertActiveBurnBarCloudProEntitlement(uid);
    const challengeId = boundedFirestoreDocumentId(request.data.challengeId, "challengeId", 64);
    const transportSignatureBase64 = requireBase64Like(
      request.data.transportSignatureBase64,
      "transportSignatureBase64",
      80,
      128,
    );
    const authoritySignatureBase64 = requireBase64Like(
      request.data.authoritySignatureBase64,
      "authoritySignatureBase64",
      80,
      128,
    );
    const challengeRef = db.doc(`users/${uid}/iroh_controller_route_challenges/${challengeId}`);
    const nowMillis = Date.now();

    const route = await db.runTransaction(async (transaction) => {
      const challengeSnapshot = await transaction.get(challengeRef);
      const challenge = requireRecord(challengeSnapshot, "Controller-route challenge not found.");
      if (challenge.challengeId !== challengeId || challenge.status !== "pending") {
        throw new HttpsError("failed-precondition", "Controller-route challenge was already consumed.");
      }
      const expiresAtMillis =
        boundedInteger(challenge.expiresAtMillis, "challenge.expiresAtMillis", 1, Number.MAX_SAFE_INTEGER, true) ?? 0;
      if (expiresAtMillis < nowMillis) {
        throw new HttpsError("failed-precondition", "Controller-route challenge expired.");
      }
      const sourceDeviceId = boundedFirestoreDocumentId(challenge.sourceDeviceId, "sourceDeviceId", 160);
      const connectionId = boundedFirestoreDocumentId(challenge.connectionId, "connectionId", 160);
      const authorityPeerNodeId = boundedFirestoreDocumentId(challenge.authorityPeerNodeId, "authorityPeerNodeId", 160);
      const { nodeId: transportNodeId, publicKey: transportPublicKey } = requireIrohTransportNodeId(
        challenge.transportNodeId,
      );
      const canonicalPayload = irohControllerRouteProofPayload({
        challengeId,
        challengeNonce: boundedFirestoreDocumentId(challenge.challengeNonce, "challengeNonce", 64),
        uid,
        connectionId,
        sourceDeviceId,
        transportNodeId,
        authorityPeerNodeId,
        registrationGeneration:
          boundedInteger(challenge.registrationGeneration, "registrationGeneration", 1, MAX_GENERATION, true) ?? 1,
        issuedAtMillis:
          boundedInteger(challenge.issuedAtMillis, "issuedAtMillis", 1, Number.MAX_SAFE_INTEGER, true) ?? 0,
        expiresAtMillis,
      }).toString("base64");
      if (challenge.canonicalPayloadBase64 !== canonicalPayload) {
        throw new HttpsError("failed-precondition", "Controller-route challenge payload is inconsistent.");
      }
      if (!verifyIrohControllerRouteProof(transportPublicKey, canonicalPayload, transportSignatureBase64)) {
        throw new HttpsError("permission-denied", "Controller route does not prove possession of transportNodeId.");
      }

      const join = await readRouteJoin(transaction, uid, connectionId, sourceDeviceId, authorityPeerNodeId);
      const verified = verifyRouteJoin({
        uid,
        connectionId,
        sourceDeviceId,
        authorityPeerNodeId,
        join,
        nowMillis,
      });
      if (
        !verifyIrohControllerAuthorityProof(
          verified.authorityPublicKey,
          verified.authorityKeyKind,
          canonicalPayload,
          authoritySignatureBase64,
        )
      ) {
        throw new HttpsError("permission-denied", "Controller route does not prove possession of authorityPeerNodeId.");
      }
      const routeRef = db.doc(`users/${uid}/iroh_pairing/${connectionId}/controller_routes/${sourceDeviceId}`);
      const existingRoute = await transaction.get(routeRef);
      const currentGeneration = existingRoute.exists
        ? (boundedInteger(existingRoute.get("generation"), "route.generation", 1, MAX_GENERATION, true) ?? 0)
        : 0;
      const expectedPriorGeneration =
        boundedInteger(challenge.expectedPriorGeneration, "expectedPriorGeneration", 0, MAX_GENERATION, true) ?? 0;
      const registrationGeneration =
        boundedInteger(challenge.registrationGeneration, "registrationGeneration", 1, MAX_GENERATION, true) ?? 1;
      if (currentGeneration !== expectedPriorGeneration || registrationGeneration !== currentGeneration + 1) {
        throw new HttpsError("aborted", "Controller route changed after this challenge was issued.");
      }
      const routeExpiresAtMillis = nowMillis + IROH_CONTROLLER_ROUTE_TTL_MS;
      transaction.set(routeRef, {
        connectionId,
        sourceDeviceId,
        transportNodeId,
        authorityPeerNodeId,
        authorityPublicKeySHA256: verified.authorityPublicKeySHA256,
        status: "active",
        generation: registrationGeneration,
        registeredAtMillis: nowMillis,
        expiresAtMillis: routeExpiresAtMillis,
        schemaVersion: ROUTE_SCHEMA_VERSION,
        updatedAt: FieldValue.serverTimestamp(),
      });
      transaction.update(challengeRef, {
        status: "consumed",
        consumedAtMillis: nowMillis,
        updatedAt: FieldValue.serverTimestamp(),
      });
      return {
        connectionId,
        sourceDeviceId,
        transportNodeId,
        authorityPeerNodeId,
        generation: registrationGeneration,
        expiresAtMillis: routeExpiresAtMillis,
      };
    });

    logInfo({
      event: "callable_info",
      message: "iroh_controller_route_registered",
      connection_id: route.connectionId,
      source_device_id: route.sourceDeviceId,
      generation: route.generation,
    });
    return { ok: true, ...route };
  },
);

export const revokeIrohControllerRoute = onCallProduction(
  "revokeIrohControllerRoute",
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (request: CallableRequest<{ sourceDeviceId?: unknown; connectionId?: unknown; nonce?: unknown }>) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before revoking a controller route.");
    await enforceHighRiskComputerUseCallableWithNonce(request, uid, request.data.nonce);
    const sourceDeviceId = boundedFirestoreDocumentId(request.data.sourceDeviceId, "sourceDeviceId", 160);
    const connectionId = boundedFirestoreDocumentId(request.data.connectionId, "connectionId", 160);
    const nowMillis = Date.now();
    const routeRef = db.doc(`users/${uid}/iroh_pairing/${connectionId}/controller_routes/${sourceDeviceId}`);
    const generation = await db.runTransaction(async (transaction) => {
      const pairing = requireRecord(
        await transaction.get(db.doc(`users/${uid}/iroh_pairing/${connectionId}`)),
        "Iroh pairing not found.",
      );
      const allowlist = normalizedControllerDeviceAllowlist(pairing.authorizedControllerDeviceIds);
      if (allowlist.length !== 1 || allowlist[0] !== sourceDeviceId) {
        throw new HttpsError("permission-denied", "Only the active controller device may revoke this route.");
      }
      const sourceDevice = requireRecord(
        await transaction.get(db.doc(`users/${uid}/escrow_devices/${sourceDeviceId}`)),
        "Trusted controller device not found.",
      );
      requireTrustedDeviceRecord(sourceDevice, sourceDeviceId, PHONE_CONTROL_ESCROW_PLATFORMS);
      const route = await transaction.get(routeRef);
      const priorGeneration = route.exists
        ? (boundedInteger(route.get("generation"), "route.generation", 1, MAX_GENERATION, true) ?? 0)
        : 0;
      if (
        route.exists &&
        (route.get("sourceDeviceId") !== sourceDeviceId || route.get("connectionId") !== connectionId)
      ) {
        throw new HttpsError("permission-denied", "Controller route ownership is inconsistent.");
      }
      const nextGeneration = priorGeneration + 1;
      transaction.set(
        routeRef,
        {
          connectionId,
          sourceDeviceId,
          status: "revoked",
          generation: nextGeneration,
          expiresAtMillis: nowMillis,
          revokedAtMillis: nowMillis,
          schemaVersion: ROUTE_SCHEMA_VERSION,
          updatedAt: FieldValue.serverTimestamp(),
        },
        { merge: true },
      );
      return nextGeneration;
    });
    return { ok: true, connectionId, sourceDeviceId, generation };
  },
);

export const resolveActiveIrohControllerRoutes = onCallProduction(
  "resolveActiveIrohControllerRoutes",
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (request: CallableRequest<{ connectionId?: unknown }>) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before resolving controller routes.");
    await assertActiveBurnBarCloudProEntitlement(uid);
    const connectionId = boundedFirestoreDocumentId(request.data.connectionId, "connectionId", 160);
    const nowMillis = Date.now();
    const result = await db.runTransaction(async (transaction) => {
      const pairingSnapshot = await transaction.get(db.doc(`users/${uid}/iroh_pairing/${connectionId}`));
      const pairing = requireRecord(pairingSnapshot, "Active iroh pairing not found.");
      const allowlist = normalizedControllerDeviceAllowlist(pairing.authorizedControllerDeviceIds);
      if (allowlist.length !== 1) {
        throw new HttpsError("failed-precondition", "Iroh pairing has no unambiguous active controller.");
      }
      const sourceDeviceId = allowlist[0];
      const routeSnapshot = await transaction.get(
        db.doc(`users/${uid}/iroh_pairing/${connectionId}/controller_routes/${sourceDeviceId}`),
      );
      const route = requireRecord(routeSnapshot, "Verified iroh controller route not found.");
      const authorityPeerNodeId = boundedFirestoreDocumentId(route.authorityPeerNodeId, "authorityPeerNodeId", 160);
      const transportNodeId = requireIrohTransportNodeId(route.transportNodeId).nodeId;
      const generation = boundedInteger(route.generation, "route.generation", 1, MAX_GENERATION, true) ?? 0;
      const expiresAtMillis =
        boundedInteger(route.expiresAtMillis, "route.expiresAtMillis", 1, Number.MAX_SAFE_INTEGER, true) ?? 0;
      if (
        route.status !== "active" ||
        route.connectionId !== connectionId ||
        route.sourceDeviceId !== sourceDeviceId ||
        expiresAtMillis <= nowMillis
      ) {
        throw new HttpsError("failed-precondition", "Verified iroh controller route is stale or revoked.");
      }
      const join = await readRouteJoin(transaction, uid, connectionId, sourceDeviceId, authorityPeerNodeId);
      const verified = verifyRouteJoin({
        uid,
        connectionId,
        sourceDeviceId,
        authorityPeerNodeId,
        join,
        nowMillis,
      });
      if (route.authorityPublicKeySHA256 !== verified.authorityPublicKeySHA256) {
        throw new HttpsError("permission-denied", "Controller authority rotated after route registration.");
      }
      return {
        pairingPublishedAtMillis: verified.pairingPublishedAtMillis,
        route: {
          connectionId,
          sourceDeviceId,
          transportNodeId,
          authorityPeerNodeId,
          generation,
          registeredAtMillis: route.registeredAtMillis,
          expiresAtMillis,
        },
      };
    });
    return { uid, connectionId, resolvedAtMillis: nowMillis, routes: [result.route] };
  },
);
