import { randomBytes } from "node:crypto";

import { FieldValue, Timestamp } from "firebase-admin/firestore";
import { HttpsError, type CallableRequest } from "firebase-functions/v2/https";

import { db } from "../adminRuntime.js";
import { enforceHighRiskComputerUseCallableWithNonce } from "../appCheckAttestation.js";
import { getConfig } from "../config.js";
import { logInfo, onCallProduction } from "../logging.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";
import {
  IROH_CONTROLLER_DEVICE_LIMIT,
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
  requireEligibleIrohControllerTransportRenewal,
  requireIrohControllerRouteProofKind,
  requireIrohTransportNodeId,
  verifyIrohControllerAuthorityProof,
  verifyIrohControllerRouteProof,
} from "./irohControllerRouteSecurity.js";
import {
  readAndVerifyIrohControllerRouteJoin,
  requireTrustedIrohRouteDevice,
  type VerifiedIrohControllerRouteJoin,
} from "./irohControllerRouteTrust.js";
import { assertActiveBurnBarCloudProEntitlement } from "./shared.js";

const ROUTE_SCHEMA_VERSION = 2;
const MAX_GENERATION = Number.MAX_SAFE_INTEGER - 1;

function requireExpectedAuthenticatedUID(expectedUID: unknown, authenticatedUID: string): void {
  if (typeof expectedUID !== "string" || expectedUID.length === 0 || expectedUID.length > 128) {
    throw new HttpsError("invalid-argument", "expectedUid is required for controller-route mutations.");
  }
  if (expectedUID !== authenticatedUID) {
    throw new HttpsError("permission-denied", "Authenticated account changed during controller-route mutation.");
  }
}

function requireRecord(
  snapshot: { exists: boolean; data(): Record<string, unknown> | undefined },
  message: string,
): Record<string, unknown> {
  const data = snapshot.exists ? snapshot.data() : undefined;
  if (!data) throw new HttpsError("failed-precondition", message);
  return data;
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
      expectedUid?: unknown;
      nonce?: unknown;
    }>,
  ) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before issuing a controller-route challenge.");
    requireExpectedAuthenticatedUID(request.data.expectedUid, uid);
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
      const verified = await readAndVerifyIrohControllerRouteJoin({
        transaction,
        uid,
        connectionId,
        sourceDeviceId,
        authorityPeerNodeId,
        nowMillis: issuedAtMillis,
      });
      const existingRoute = await transaction.get(routeRef);
      const expectedPriorGeneration = existingRoute.exists
        ? (boundedInteger(existingRoute.get("generation"), "route.generation", 1, MAX_GENERATION, true) ?? 0)
        : 0;
      const existingStatus = existingRoute.exists ? existingRoute.get("status") : undefined;
      if (existingRoute.exists && existingStatus !== "active" && existingStatus !== "revoked") {
        throw new HttpsError("failed-precondition", "Existing controller route has an invalid status.");
      }
      let expectedRegisteredAtMillis: number | null = null;
      let proofKind: "bootstrap" | "transport-renewal" = "bootstrap";
      if (existingStatus === "active") {
        const existingExpiresAtMillis =
          boundedInteger(
            existingRoute.get("expiresAtMillis"),
            "route.expiresAtMillis",
            1,
            Number.MAX_SAFE_INTEGER,
            true,
          ) ?? 0;
        const existingRegisteredAtMillis =
          boundedInteger(
            existingRoute.get("registeredAtMillis"),
            "route.registeredAtMillis",
            1,
            Number.MAX_SAFE_INTEGER,
            true,
          ) ?? 0;
        const exactActiveTuple =
          existingRoute.get("connectionId") === connectionId &&
          existingRoute.get("sourceDeviceId") === sourceDeviceId &&
          existingRoute.get("transportNodeId") === transportNodeId &&
          existingRoute.get("authorityPeerNodeId") === authorityPeerNodeId &&
          existingRoute.get("authorityPublicKeySHA256") === verified.authorityPublicKeySHA256 &&
          existingExpiresAtMillis > issuedAtMillis;
        if (exactActiveTuple) {
          proofKind = "transport-renewal";
          expectedRegisteredAtMillis = existingRegisteredAtMillis;
        }
      }
      const registrationGeneration =
        proofKind === "transport-renewal" ? expectedPriorGeneration : expectedPriorGeneration + 1;
      const canonicalPayload = irohControllerRouteProofPayload({
        challengeId,
        challengeNonce,
        proofKind,
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
        proofKind,
        expectedPriorGeneration,
        expectedRegisteredAtMillis,
        registrationGeneration,
        canonicalPayloadBase64,
        issuedAtMillis,
        expiresAtMillis,
        status: "pending",
        schemaVersion: ROUTE_SCHEMA_VERSION,
        expireAt: Timestamp.fromMillis(expiresAtMillis),
        createdAt: FieldValue.serverTimestamp(),
      });
      return { canonicalPayloadBase64, proofKind, registrationGeneration };
    });

    logInfo({
      event: "callable_info",
      message: "iroh_controller_route_challenge_issued",
      connection_id: connectionId,
      source_device_id: sourceDeviceId,
    });
    return {
      challengeId,
      canonicalPayloadBase64: result.canonicalPayloadBase64,
      signatureAlgorithm: "ed25519",
      proofKind: result.proofKind,
      requiresAuthorityProof: result.proofKind === "bootstrap",
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
      expectedUid?: unknown;
    }>,
  ) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before registering a controller route.");
    requireExpectedAuthenticatedUID(request.data.expectedUid, uid);
    await assertActiveBurnBarCloudProEntitlement(uid);
    const challengeId = boundedFirestoreDocumentId(request.data.challengeId, "challengeId", 64);
    const transportSignatureBase64 = requireBase64Like(
      request.data.transportSignatureBase64,
      "transportSignatureBase64",
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
      const proofKind = requireIrohControllerRouteProofKind(challenge.proofKind);
      const { nodeId: transportNodeId, publicKey: transportPublicKey } = requireIrohTransportNodeId(
        challenge.transportNodeId,
      );
      const canonicalPayload = irohControllerRouteProofPayload({
        challengeId,
        challengeNonce: boundedFirestoreDocumentId(challenge.challengeNonce, "challengeNonce", 64),
        proofKind,
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

      const verified = await readAndVerifyIrohControllerRouteJoin({
        transaction,
        uid,
        connectionId,
        sourceDeviceId,
        authorityPeerNodeId,
        nowMillis,
      });
      const routeRef = db.doc(`users/${uid}/iroh_pairing/${connectionId}/controller_routes/${sourceDeviceId}`);
      const existingRoute = await transaction.get(routeRef);
      const currentGeneration = existingRoute.exists
        ? (boundedInteger(existingRoute.get("generation"), "route.generation", 1, MAX_GENERATION, true) ?? 0)
        : 0;
      const expectedPriorGeneration =
        boundedInteger(challenge.expectedPriorGeneration, "expectedPriorGeneration", 0, MAX_GENERATION, true) ?? 0;
      const registrationGeneration =
        boundedInteger(challenge.registrationGeneration, "registrationGeneration", 1, MAX_GENERATION, true) ?? 1;
      if (currentGeneration !== expectedPriorGeneration) {
        throw new HttpsError("aborted", "Controller route changed after this challenge was issued.");
      }
      let registeredAtMillis: number;
      let routeExpiresAtMillis: number;
      if (proofKind === "transport-renewal") {
        ({ registeredAtMillis, expiresAtMillis: routeExpiresAtMillis } = requireEligibleIrohControllerTransportRenewal({
          route: existingRoute,
          connectionId,
          sourceDeviceId,
          transportNodeId,
          authorityPeerNodeId,
          authorityPublicKeySHA256: verified.authorityPublicKeySHA256,
          currentGeneration,
          registrationGeneration,
          expectedRegisteredAtMillis: challenge.expectedRegisteredAtMillis,
          nowMillis,
        }));
      } else {
        if (registrationGeneration !== currentGeneration + 1) {
          throw new HttpsError("aborted", "Controller route changed after this challenge was issued.");
        }
        const authoritySignatureBase64 = requireBase64Like(
          request.data.authoritySignatureBase64,
          "authoritySignatureBase64",
          80,
          128,
        );
        if (
          !verifyIrohControllerAuthorityProof(
            verified.authorityPublicKey,
            verified.authorityKeyKind,
            canonicalPayload,
            authoritySignatureBase64,
          )
        ) {
          throw new HttpsError(
            "permission-denied",
            "Controller route does not prove possession of authorityPeerNodeId.",
          );
        }
        registeredAtMillis = nowMillis;
        routeExpiresAtMillis = nowMillis + IROH_CONTROLLER_ROUTE_TTL_MS;
      }
      transaction.set(routeRef, {
        connectionId,
        sourceDeviceId,
        transportNodeId,
        authorityPeerNodeId,
        authorityPublicKeySHA256: verified.authorityPublicKeySHA256,
        status: "active",
        generation: registrationGeneration,
        registeredAtMillis,
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
  async (
    request: CallableRequest<{
      sourceDeviceId?: unknown;
      connectionId?: unknown;
      expectedUid?: unknown;
      nonce?: unknown;
    }>,
  ) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before revoking a controller route.");
    requireExpectedAuthenticatedUID(request.data.expectedUid, uid);
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
      if (allowlist.length > IROH_CONTROLLER_DEVICE_LIMIT || !allowlist.includes(sourceDeviceId)) {
        throw new HttpsError("permission-denied", "Only an authorized controller device may revoke its route.");
      }
      const sourceDevice = requireRecord(
        await transaction.get(db.doc(`users/${uid}/escrow_devices/${sourceDeviceId}`)),
        "Trusted controller device not found.",
      );
      requireTrustedIrohRouteDevice(sourceDevice, sourceDeviceId, PHONE_CONTROL_ESCROW_PLATFORMS);
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
      if (!pairingSnapshot.exists) return [];
      const pairing = pairingSnapshot.data();
      if (!pairing) {
        throw new HttpsError("failed-precondition", "Iroh pairing record is malformed.");
      }
      const allowlist = normalizedControllerDeviceAllowlist(pairing.authorizedControllerDeviceIds);
      if (allowlist.length === 0 || allowlist.length > IROH_CONTROLLER_DEVICE_LIMIT) {
        return [];
      }
      const activeRoutes: Array<{
        connectionId: string;
        sourceDeviceId: string;
        transportNodeId: string;
        authorityPeerNodeId: string;
        generation: number;
        registeredAtMillis: number;
        expiresAtMillis: number;
      }> = [];
      const transportNodeIds = new Set<string>();
      const ambiguousTransportNodeIds = new Set<string>();
      for (const sourceDeviceId of allowlist) {
        const routeSnapshot = await transaction.get(
          db.doc(`users/${uid}/iroh_pairing/${connectionId}/controller_routes/${sourceDeviceId}`),
        );
        if (!routeSnapshot.exists) continue;
        const route = routeSnapshot.data();
        if (!route) {
          throw new HttpsError("failed-precondition", "Verified iroh controller route is malformed.");
        }
        if (route.status === "revoked") continue;
        if (route.status !== "active") {
          throw new HttpsError("failed-precondition", "Verified iroh controller route has an invalid status.");
        }
        if (route.connectionId !== connectionId || route.sourceDeviceId !== sourceDeviceId) {
          throw new HttpsError("permission-denied", "Verified iroh controller route ownership is inconsistent.");
        }
        const authorityPeerNodeId = boundedFirestoreDocumentId(route.authorityPeerNodeId, "authorityPeerNodeId", 160);
        const transportNodeId = requireIrohTransportNodeId(route.transportNodeId).nodeId;
        const generation = boundedInteger(route.generation, "route.generation", 1, MAX_GENERATION, true) ?? 0;
        const registeredAtMillis =
          boundedInteger(route.registeredAtMillis, "route.registeredAtMillis", 1, Number.MAX_SAFE_INTEGER, true) ?? 0;
        const expiresAtMillis =
          boundedInteger(route.expiresAtMillis, "route.expiresAtMillis", 1, Number.MAX_SAFE_INTEGER, true) ?? 0;
        if (expiresAtMillis <= nowMillis) continue;
        let verified: VerifiedIrohControllerRouteJoin;
        try {
          verified = await readAndVerifyIrohControllerRouteJoin({
            transaction,
            uid,
            connectionId,
            sourceDeviceId,
            authorityPeerNodeId,
            nowMillis,
          });
        } catch (error) {
          if (
            error instanceof HttpsError &&
            (error.code === "permission-denied" ||
              error.code === "failed-precondition" ||
              error.code === "invalid-argument")
          ) {
            continue;
          }
          throw error;
        }
        if (route.authorityPublicKeySHA256 !== verified.authorityPublicKeySHA256) {
          continue;
        }
        if (transportNodeIds.has(transportNodeId)) {
          ambiguousTransportNodeIds.add(transportNodeId);
        } else {
          transportNodeIds.add(transportNodeId);
        }
        activeRoutes.push({
          connectionId,
          sourceDeviceId,
          transportNodeId,
          authorityPeerNodeId,
          generation,
          registeredAtMillis,
          expiresAtMillis,
        });
      }
      return activeRoutes.filter((route) => !ambiguousTransportNodeIds.has(route.transportNodeId));
    });
    return { uid, connectionId, resolvedAtMillis: nowMillis, routes: result };
  },
);
