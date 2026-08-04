/**
 * @fileoverview The Hermes Gateway device-grant approval callable (the approving
 * phone redeems a pairing code and mints a relay-capable client). Split out of
 * hermesGatewayCallables.ts to keep every gateway module under the file-length
 * cap; re-exported from ./hermesGateway.js byte-identically.
 */

import { Timestamp } from "firebase-admin/firestore";
import { HttpsError, onCall, type CallableRequest } from "firebase-functions/v2/https";
import { randomBytes } from "node:crypto";

import { db } from "../adminRuntime.js";
import { enforceAuthAndAppCheck } from "../auth.js";
import { getConfig } from "../config.js";
import { recordOrUndefined, stripUndefinedObject } from "../guards.js";
import { enforceHighRiskOwnerAction } from "./highRiskOwnerAction.js";
import {
  canonicalHermesGatewayUserCode,
  gatewayPlaintextWriteAllowed,
  gatewaySignalRequiredMode,
  gatewayTokenExpiryISO,
  generateHermesGatewayBearerToken,
  hashHermesGatewayBearerToken,
  HERMES_GATEWAY_RELAY_ENCRYPTION,
  HERMES_GATEWAY_SCHEMA_VERSION,
  isGatewayRelayPublicKeyB64,
  negotiateGatewayRelayEnvelopeCapabilities,
  publicClientView,
  sanitizeGatewayRelayEnvelopeCapabilities,
  sanitizeHermesGatewayDestinationId,
  sanitizeHermesGatewayScopes,
  sanitizedGatewayDisplayName,
  sha256Hex,
  tokenPreview,
  type HermesGatewayRelayEnvelopeCapabilities,
  type HermesGatewayScope,
} from "../hermesGateway.js";
import { logInfo, wrapCallableHandler } from "../logging.js";
import type {
  HermesGatewayClientDoc,
  HermesGatewaySignalPrekeyBundleDoc,
} from "../types/generated/hermes-gateway.js";
import { parseGatewaySignalPrekeyBundle } from "../hermesGatewaySignalPrekeys.js";
import { assertCallableApprovalNotLocked, recordCallableApprovalFailure } from "./publicRateLimit.js";
import { nowISO } from "./shared.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";
import {
  parseGatewayPopVersionCapability,
  parseRatchetPrekeyBundle,
  parseRelayPublicKey,
  requireCallableGatewayClientSigningPublicKey,
  type ParsedRatchetPrekeyBundle,
  type ParsedRelayPublicKey,
} from "./hermesGatewayCrypto.js";
import { assertActiveHermesGatewayEntitlement, ensureDefaultDestination } from "./hermesGatewayResolve.js";

interface PairingSession {
  ref: ReturnType<typeof db.doc>;
  data: Record<string, unknown>;
}

/**
 * Locate and validate the pending pairing session for `userCode`. Records an
 * approval failure + throws not-found when absent, throws on an expired or
 * malformed session. A pure relocation of the session-lookup prefix of the
 * approve-grant callable.
 */
async function resolvePairingSession(uid: string, userCode: string): Promise<PairingSession> {
  const sessions = await db
    .collection("hermes_gateway_device_sessions")
    .where("userCode", "==", userCode)
    .where("status", "==", "pending")
    .limit(1)
    .get();
  if (sessions.empty) {
    await recordCallableApprovalFailure(uid, "hermes_gateway_approve_fail");
    throw new HttpsError("not-found", "Hermes Gateway pairing code was not found.");
  }
  const ref = sessions.docs[0].ref;
  const data = recordOrUndefined(sessions.docs[0].data());
  if (!data) throw new HttpsError("failed-precondition", "Hermes Gateway pairing session is invalid.");
  const expiresAt = data.expiresAt instanceof Timestamp ? data.expiresAt.toMillis() : 0;
  if (expiresAt <= Date.now()) {
    await ref.set({ status: "expired", updatedAt: Timestamp.now() }, { merge: true });
    throw new HttpsError("deadline-exceeded", "Hermes Gateway pairing code has expired.");
  }
  return { ref, data };
}

interface AgentSessionRelay {
  agentRelayPublicKey: string | undefined;
  agentRelayKeyVersion: number | undefined;
  agentRelayEncryption: string | undefined;
  agentCapabilities: HermesGatewayRelayEnvelopeCapabilities | undefined;
  agentRatchet: ParsedRatchetPrekeyBundle | undefined;
  agentSignalPrekeyBundle: HermesGatewaySignalPrekeyBundleDoc | undefined;
}

/**
 * Reconstruct the agent's relay/ratchet material recorded on the pairing session
 * at device/start so it can be carried onto the new client doc. A pure
 * relocation of the agent-key derivation block.
 */
function deriveAgentSessionRelay(session: Record<string, unknown>): AgentSessionRelay {
  const agentRelayPublicKey = isGatewayRelayPublicKeyB64(session.agentRelayPublicKey);
  const agentRelayKeyVersion =
    typeof session.agentRelayKeyVersion === "number"
      ? session.agentRelayKeyVersion
      : agentRelayPublicKey
        ? 1
        : undefined;
  const agentRelayEncryption =
    typeof session.agentRelayEncryption === "string"
      ? session.agentRelayEncryption
      : agentRelayPublicKey
        ? HERMES_GATEWAY_RELAY_ENCRYPTION
        : undefined;
  const agentCapabilities = agentRelayPublicKey
    ? sanitizeGatewayRelayEnvelopeCapabilities({
        supportsRelayEnvelopeVersions: session.agentSupportsRelayEnvelopeVersions,
        preferredRelayEnvelopeVersion: session.agentPreferredRelayEnvelopeVersion,
        supportsHpkeV3: session.agentSupportsHpkeV3,
        supportsSignalEnvelope: session.agentSupportsSignalEnvelope,
        clientPlatform: session.agentPlatform,
        clientAppBuild: session.agentAppBuild,
      })
    : undefined;
  const agentRatchet = parseRatchetPrekeyBundle(
    {
      agentRatchetIdentityPublicKey: session.agentRatchetIdentityPublicKey,
      agentRatchetSigningPublicKey: session.agentRatchetSigningPublicKey,
      agentRatchetSignedPreKeyPublicKey: session.agentRatchetSignedPreKeyPublicKey,
      agentRatchetSignedPreKeyId: session.agentRatchetSignedPreKeyId,
      agentRatchetSignedPreKeySignature: session.agentRatchetSignedPreKeySignature,
      agentSupportsRatchetV1: session.agentSupportsRatchetV1,
    },
    "agent",
    (message) => {
      throw new HttpsError("failed-precondition", `invalid_agent_ratchet_prekey: ${message}`);
    },
  );
  const agentSignalPrekeyBundle = parseGatewaySignalPrekeyBundle(session, "agent", (message) => {
    throw new HttpsError("failed-precondition", `invalid_agent_signal_prekey_bundle: ${message}`);
  });
  if (agentCapabilities?.supportsSignalEnvelope === true && !agentSignalPrekeyBundle) {
    throw new HttpsError(
      "failed-precondition",
      "missing_agent_signal_prekey_bundle: Signal-capable pairings require a PQXDH bundle.",
    );
  }
  return {
    agentRelayPublicKey,
    agentRelayKeyVersion,
    agentRelayEncryption,
    agentCapabilities,
    agentRatchet,
    agentSignalPrekeyBundle,
  };
}

interface ApprovedClientBuildInput {
  uid: string;
  clientId: string;
  displayName: string;
  tokenHash: string;
  token: string;
  agentClientSigningPublicKeyBase64: string;
  agentClientSigningKeyId: string;
  popVersion: number;
  scopes: HermesGatewayScope[];
  homeDestinationId: string;
  tokenExpiresAt: string;
  now: string;
  agentRelay: AgentSessionRelay;
  phoneRelay: ParsedRelayPublicKey | undefined;
  phoneCapabilities: HermesGatewayRelayEnvelopeCapabilities | undefined;
  phoneRatchet: ParsedRatchetPrekeyBundle | undefined;
  phoneSignalPrekeyBundle: HermesGatewaySignalPrekeyBundleDoc | undefined;
  negotiatedCapabilities: HermesGatewayRelayEnvelopeCapabilities | undefined;
  supportsRatchetV1: boolean | undefined;
  relayCapable: boolean;
}

/** Agent relay-key + capability fields for the approved client doc. */
function agentRelayClientFields(agentRelay: AgentSessionRelay): Partial<HermesGatewayClientDoc> {
  const agentCapabilities = agentRelay.agentCapabilities;
  return {
    agentRelayPublicKey: agentRelay.agentRelayPublicKey,
    agentRelayKeyVersion: agentRelay.agentRelayKeyVersion,
    agentRelayEncryption: agentRelay.agentRelayEncryption,
    agentSupportsRelayEnvelopeVersions: agentCapabilities?.supportsRelayEnvelopeVersions,
    agentPreferredRelayEnvelopeVersion: agentCapabilities?.preferredRelayEnvelopeVersion,
    agentSupportsHpkeV3: agentCapabilities?.supportsHpkeV3,
    agentSupportsSignalEnvelope: agentCapabilities?.supportsSignalEnvelope,
    agentSignalPrekeyBundle: agentRelay.agentSignalPrekeyBundle,
    agentPlatform: agentCapabilities?.platform,
    agentAppBuild: agentCapabilities?.appBuild,
  };
}

/** Phone relay-key + capability fields for the approved client doc. */
function phoneRelayClientFields(
  phoneRelay: ParsedRelayPublicKey | undefined,
  phoneCapabilities: HermesGatewayRelayEnvelopeCapabilities | undefined,
  phoneSignalPrekeyBundle: HermesGatewaySignalPrekeyBundleDoc | undefined,
): Partial<HermesGatewayClientDoc> {
  return {
    phoneRelayPublicKey: phoneRelay?.publicKey,
    phoneRelayKeyVersion: phoneRelay?.keyVersion,
    phoneRelayEncryption: phoneRelay?.encryption,
    phoneSupportsRelayEnvelopeVersions: phoneCapabilities?.supportsRelayEnvelopeVersions,
    phonePreferredRelayEnvelopeVersion: phoneCapabilities?.preferredRelayEnvelopeVersion,
    phoneSupportsHpkeV3: phoneCapabilities?.supportsHpkeV3,
    phoneSupportsSignalEnvelope: phoneCapabilities?.supportsSignalEnvelope,
    phoneSignalPrekeyBundle,
    phonePlatform: phoneCapabilities?.platform,
    phoneAppBuild: phoneCapabilities?.appBuild,
  };
}

/** Negotiated relay-envelope capability fields for the approved client doc. */
function negotiatedRelayClientFields(
  negotiatedCapabilities: HermesGatewayRelayEnvelopeCapabilities | undefined,
): Partial<HermesGatewayClientDoc> {
  return {
    supportsRelayEnvelopeVersions: negotiatedCapabilities?.supportsRelayEnvelopeVersions,
    preferredRelayEnvelopeVersion: negotiatedCapabilities?.preferredRelayEnvelopeVersion,
    supportsHpkeV3: negotiatedCapabilities?.supportsHpkeV3,
    supportsSignalEnvelope: negotiatedCapabilities?.supportsSignalEnvelope,
  };
}

/** Agent + phone ratchet prekey fields for the approved client doc. */
function ratchetClientFields(
  agentRatchet: ParsedRatchetPrekeyBundle | undefined,
  phoneRatchet: ParsedRatchetPrekeyBundle | undefined,
  supportsRatchetV1: boolean | undefined,
): Partial<HermesGatewayClientDoc> {
  return {
    agentRatchetIdentityPublicKey: agentRatchet?.identityPublicKey,
    agentRatchetSigningPublicKey: agentRatchet?.signingPublicKey,
    agentRatchetSignedPreKeyPublicKey: agentRatchet?.signedPreKeyPublicKey,
    agentRatchetSignedPreKeyId: agentRatchet?.signedPreKeyId,
    agentRatchetSignedPreKeySignature: agentRatchet?.signedPreKeySignature,
    agentSupportsRatchetV1: agentRatchet?.supportsRatchetV1,
    phoneRatchetIdentityPublicKey: phoneRatchet?.identityPublicKey,
    phoneRatchetSigningPublicKey: phoneRatchet?.signingPublicKey,
    phoneRatchetSignedPreKeyPublicKey: phoneRatchet?.signedPreKeyPublicKey,
    phoneRatchetSignedPreKeyId: phoneRatchet?.signedPreKeyId,
    phoneRatchetSignedPreKeySignature: phoneRatchet?.signedPreKeySignature,
    phoneSupportsRatchetV1: phoneRatchet?.supportsRatchetV1,
    supportsRatchetV1,
  };
}

/** Assemble the new client doc minted on pairing approval. A pure builder. */
function buildApprovedClientDoc(input: ApprovedClientBuildInput): HermesGatewayClientDoc {
  const {
    agentRelay,
    phoneRelay,
    phoneCapabilities,
    phoneRatchet,
    phoneSignalPrekeyBundle,
    negotiatedCapabilities,
  } = input;
  return {
    id: input.clientId,
    uid: input.uid,
    displayName: input.displayName,
    status: "active",
    tokenHash: input.tokenHash,
    tokenPreview: tokenPreview(input.token),
    agentClientSigningPublicKeyBase64: input.agentClientSigningPublicKeyBase64,
    agentClientSigningKeyId: input.agentClientSigningKeyId,
    popRequired: true,
    popVersion: input.popVersion,
    scopes: input.scopes,
    homeDestinationId: input.homeDestinationId,
    expiresAt: input.tokenExpiresAt,
    ...agentRelayClientFields(agentRelay),
    ...phoneRelayClientFields(phoneRelay, phoneCapabilities, phoneSignalPrekeyBundle),
    ...negotiatedRelayClientFields(negotiatedCapabilities),
    ...ratchetClientFields(agentRelay.agentRatchet, phoneRatchet, input.supportsRatchetV1),
    relayCapable: input.relayCapable ? true : undefined,
    createdAt: input.now,
    updatedAt: input.now,
    schemaVersion: HERMES_GATEWAY_SCHEMA_VERSION,
  };
}

/**
 * Persist the approved pairing: write the client doc, the token index, and the
 * session-approval echo (carrying the phone's relay/ratchet material so
 * device/poll can hand it to the agent). A pure relocation of the write block.
 */
async function persistApprovedPairing(input: {
  uid: string;
  clientId: string;
  clientDoc: Record<string, unknown>;
  tokenHash: string;
  token: string;
  tokenExpiresAt: string;
  now: string;
  scopes: string[];
  homeDestinationId: string | undefined;
  sessionRef: ReturnType<typeof db.doc>;
  phoneRelay: ParsedRelayPublicKey | undefined;
  phoneRatchet: ParsedRatchetPrekeyBundle | undefined;
  phoneSignalPrekeyBundle: HermesGatewaySignalPrekeyBundleDoc | undefined;
  supportsRatchetV1: boolean | undefined;
  relayCapable: boolean;
}): Promise<void> {
  const { phoneRelay, phoneRatchet, phoneSignalPrekeyBundle } = input;
  await ensureDefaultDestination(input.uid, input.now);
  await Promise.all([
    db.doc(`users/${input.uid}/hermes_gateway_clients/${input.clientId}`).set(input.clientDoc, { merge: false }),
    db.doc(`hermes_gateway_token_index/${input.tokenHash}`).set({
      uid: input.uid,
      clientId: input.clientId,
      status: "active",
      createdAt: input.now,
      expiresAt: input.tokenExpiresAt,
    }),
    input.sessionRef.set(
      stripUndefinedObject({
        status: "approved",
        uid: input.uid,
        clientId: input.clientId,
        accessToken: input.token,
        scopes: input.scopes,
        homeDestinationId: input.homeDestinationId,
        // Echo the phone's relay key onto the session so device/poll returns
        // it to the agent (the agent then wraps its first reply to the phone).
        phoneRelayPublicKey: phoneRelay?.publicKey,
        phoneRelayKeyVersion: phoneRelay?.keyVersion,
        phoneRelayEncryption: phoneRelay?.encryption,
        phoneSignalPrekeyBundle,
        phoneRatchetIdentityPublicKey: phoneRatchet?.identityPublicKey,
        phoneRatchetSigningPublicKey: phoneRatchet?.signingPublicKey,
        phoneRatchetSignedPreKeyPublicKey: phoneRatchet?.signedPreKeyPublicKey,
        phoneRatchetSignedPreKeyId: phoneRatchet?.signedPreKeyId,
        phoneRatchetSignedPreKeySignature: phoneRatchet?.signedPreKeySignature,
        phoneSupportsRatchetV1: phoneRatchet?.supportsRatchetV1,
        supportsRatchetV1: input.supportsRatchetV1,
        relayCapable: input.relayCapable ? true : undefined,
        approvedAt: input.now,
        updatedAt: Timestamp.now(),
      }),
      { merge: true },
    ),
  ]);
}

export const approveHermesGatewayDeviceGrant = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 50,
  },
  wrapCallableHandler(
    "approveHermesGatewayDeviceGrant",
    async (
      request: CallableRequest<{
        userCode?: unknown;
        displayName?: unknown;
        destinationId?: unknown;
        scopes?: unknown;
        phoneRelayPublicKey?: unknown;
        phoneRelayKeyVersion?: unknown;
        phoneRelayEncryption?: unknown;
        supportsRelayEnvelopeVersions?: unknown;
        preferredRelayEnvelopeVersion?: unknown;
        supportsHpkeV3?: unknown;
        clientPlatform?: unknown;
        clientAppBuild?: unknown;
        phoneRatchetIdentityPublicKey?: unknown;
        phoneRatchetSigningPublicKey?: unknown;
        phoneRatchetSignedPreKeyPublicKey?: unknown;
        phoneRatchetSignedPreKeyId?: unknown;
        phoneRatchetSignedPreKeySignature?: unknown;
        phoneSupportsRatchetV1?: unknown;
        supportsSignalEnvelope?: unknown;
        phoneSignalPrekeyBundle?: unknown;
        signalPrekeyBundle?: unknown;
        ratchetIdentityPublicKey?: unknown;
        ratchetSigningPublicKey?: unknown;
        ratchetSignedPreKeyPublicKey?: unknown;
        ratchetSignedPreKeyId?: unknown;
        ratchetSignedPreKeySignature?: unknown;
        supportsRatchetV1?: unknown;
      }>,
    ) => {
      const uid = request.auth?.uid;
      if (!uid) throw new HttpsError("unauthenticated", "Sign in before approving Hermes Gateway.");
      enforceAuthAndAppCheck(request, uid);
      await assertCallableApprovalNotLocked(uid, "hermes_gateway_approve_fail");
      await assertActiveHermesGatewayEntitlement(uid);
      const userCode = canonicalHermesGatewayUserCode(request.data.userCode);
      if (!userCode) throw new HttpsError("invalid-argument", "userCode must be an 8-character Hermes Gateway code.");
      await enforceHighRiskOwnerAction(request, uid, {
        actionKind: "hermes_gateway_device_grant_approve",
        subjectId: userCode,
      });
      const requestData = recordOrUndefined(request.data) ?? {};

      // The approving PHONE publishes its own relay public key so the agent can
      // wrap reply/attachment bodies to it. Required once sealing is mandatory
      // (relay-capable pairing / past the grace cutoff); optional only for a
      // legacy in-grace pairing.
      const phoneRelay = parseRelayPublicKey(
        requestData,
        {
          publicKeyField: "phoneRelayPublicKey",
          keyVersionField: "phoneRelayKeyVersion",
          encryptionField: "phoneRelayEncryption",
        },
        (message) => {
          throw new HttpsError("invalid-argument", message);
        },
      );
      const phoneCapabilities = phoneRelay ? sanitizeGatewayRelayEnvelopeCapabilities(requestData) : undefined;
      const phoneRatchet = parseRatchetPrekeyBundle(requestData, "phone", (message) => {
        throw new HttpsError("invalid-argument", message);
      });
      const phoneSignalPrekeyBundle = parseGatewaySignalPrekeyBundle(requestData, "phone", (message) => {
        throw new HttpsError("invalid-argument", message);
      });
      if (phoneCapabilities?.supportsSignalEnvelope === true && !phoneSignalPrekeyBundle) {
        throw new HttpsError(
          "invalid-argument",
          "missing_phone_signal_prekey_bundle: Signal-capable pairings require a PQXDH bundle.",
        );
      }

      const session = await resolvePairingSession(uid, userCode);
      const agentClientSigningPublicKey = requireCallableGatewayClientSigningPublicKey(
        session.data.agentClientSigningPublicKeyBase64,
      );
      const agentClientSigningPublicKeyBase64 = agentClientSigningPublicKey.toString("base64");
      const agentClientSigningKeyId =
        typeof session.data.agentClientSigningKeyId === "string"
          ? session.data.agentClientSigningKeyId
          : sha256Hex(agentClientSigningPublicKeyBase64).slice(0, 32);

      // The agent published its relay public key at device/start; carry it onto
      // the new client doc so the phone can wrap event bodies to it. The pair is
      // relay-capable only when BOTH keys are present.
      const agentRelay = deriveAgentSessionRelay(session.data);
      const relayCapable = !!agentRelay.agentRelayPublicKey && !!phoneRelay;
      const negotiatedCapabilities =
        agentRelay.agentCapabilities && phoneCapabilities
          ? negotiateGatewayRelayEnvelopeCapabilities(agentRelay.agentCapabilities, phoneCapabilities)
          : undefined;
      const supportsRatchetV1 = agentRelay.agentRatchet != null && phoneRatchet != null ? true : undefined;
      if (
        gatewaySignalRequiredMode() &&
        (negotiatedCapabilities?.supportsSignalEnvelope !== true ||
          !agentRelay.agentSignalPrekeyBundle ||
          !phoneSignalPrekeyBundle)
      ) {
        await recordCallableApprovalFailure(uid, "hermes_gateway_approve_fail");
        throw new HttpsError(
          "failed-precondition",
          "signal_pairing_required: both endpoints must negotiate Signal v4 and publish official-libsignal PQXDH bundles.",
        );
      }
      // A pairing that cannot seal in BOTH directions is refused so no plaintext-
      // only client is ever minted.
      if (!relayCapable && !gatewayPlaintextWriteAllowed(false)) {
        await recordCallableApprovalFailure(uid, "hermes_gateway_approve_fail");
        throw new HttpsError(
          "failed-precondition",
          "unsealed_pairing_unsupported: both the agent and this device must publish a relay public key.",
        );
      }

      const token = generateHermesGatewayBearerToken();
      const tokenHash = hashHermesGatewayBearerToken(token);
      const now = nowISO();
      const tokenExpiresAt = gatewayTokenExpiryISO();
      const clientId = `hgw_${randomBytes(12).toString("hex")}`;
      const scopes = sanitizeHermesGatewayScopes(request.data.scopes ?? session.data.requestedScopes);
      const homeDestinationId = sanitizeHermesGatewayDestinationId(request.data.destinationId);
      const displayName = sanitizedGatewayDisplayName(
        request.data.displayName,
        String(session.data.clientName ?? "Hermes Agent"),
      );
      const clientDocPayload = buildApprovedClientDoc({
        uid,
        clientId,
        displayName,
        tokenHash,
        token,
        agentClientSigningPublicKeyBase64,
        agentClientSigningKeyId,
        popVersion: parseGatewayPopVersionCapability(session.data.popVersion),
        scopes,
        homeDestinationId,
        tokenExpiresAt,
        now,
        agentRelay,
        phoneRelay,
        phoneCapabilities,
        phoneRatchet,
        phoneSignalPrekeyBundle,
        negotiatedCapabilities,
        supportsRatchetV1,
        relayCapable,
      });
      const clientDoc = stripUndefinedObject(clientDocPayload);

      await persistApprovedPairing({
        uid,
        clientId,
        clientDoc,
        tokenHash,
        token,
        tokenExpiresAt,
        now,
        scopes,
        homeDestinationId,
        sessionRef: session.ref,
        phoneRelay,
        phoneRatchet,
        phoneSignalPrekeyBundle,
        supportsRatchetV1,
        relayCapable,
      });
      logInfo({ event: "hermes_gateway.device_grant_approved", user_id_hash: uid.slice(0, 8), client_id: clientId });
      // Echo the agent's relay key back so the phone can seal its first event
      // without waiting for a /state round-trip. publicClientView already carries
      // both keys, so the phone reads agentRelayPublicKey straight off `client`.
      return { client: publicClientView(clientDocPayload), homeDestinationId };
    },
  ),
);
