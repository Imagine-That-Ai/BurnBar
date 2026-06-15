/**
 * @fileoverview Hermes Gateway device-pairing HTTP routes (/device/start and
 * /device/poll) and their builders. Split out of hermesGatewayRoutes.ts to keep
 * every gateway module under the file-length cap; the dispatcher imports the
 * exported handlers.
 */

import { Timestamp } from "firebase-admin/firestore";

import { db } from "../adminRuntime.js";
import { recordOrUndefined, stripUndefinedObject } from "../guards.js";
import {
  gatewayPlaintextWriteAllowed,
  HERMES_GATEWAY_DEVICE_SESSION_TTL_MS,
  HERMES_GATEWAY_SCHEMA_VERSION,
  generateHermesGatewayDeviceCode,
  generateHermesGatewayDeviceSecret,
  hashHermesGatewayDeviceSecret,
  isHermesGatewayClientDoc,
  isSha256Hex,
  publicClientView,
  randomHermesGatewayUserCode,
  safeEqualHex,
  sanitizeGatewayRelayEnvelopeCapabilities,
  sanitizeHermesGatewayScopes,
  sanitizedGatewayDisplayName,
  sha256Hex,
  type HermesGatewayRelayEnvelopeCapabilities,
} from "../hermesGateway.js";
import type { HermesGatewayClientDoc } from "../types/generated/hermes-gateway.js";
import { boundedTrimmedString } from "./shared.js";
import {
  type HttpRequest,
  type HttpResponse,
  httpError,
  requestBody,
  sendJSON,
  setNoStore,
} from "./hermesGatewayHttp.js";
import {
  parseGatewayPopVersionCapability,
  parseRatchetPrekeyBundle,
  parseRelayPublicKey,
  requireGatewayClientSigningPublicKey,
  type ParsedRatchetPrekeyBundle,
  type ParsedRelayPublicKey,
} from "./hermesGatewayCrypto.js";
import { checkPublicHttpRateLimit, clientIpFromHttpRequest } from "./publicRateLimit.js";

function buildDeviceStartSession(options: {
  deviceCode: string;
  userCode: string;
  deviceSecretHash: string;
  clientName: string;
  requestedScopes: string[];
  agentClientSigningPublicKeyBase64: string;
  agentClientSigningKeyId: string;
  popVersion: number;
  agentRelay: ParsedRelayPublicKey | undefined;
  agentCapabilities: HermesGatewayRelayEnvelopeCapabilities | undefined;
  agentRatchet: ParsedRatchetPrekeyBundle | undefined;
  now: Timestamp;
  expiresAt: Timestamp;
}): Record<string, unknown> {
  const { agentRelay, agentCapabilities, agentRatchet } = options;
  return stripUndefinedObject({
    deviceCode: options.deviceCode,
    userCode: options.userCode,
    deviceSecretHash: options.deviceSecretHash,
    status: "pending",
    clientName: options.clientName,
    requestedScopes: options.requestedScopes,
    agentClientSigningPublicKeyBase64: options.agentClientSigningPublicKeyBase64,
    agentClientSigningKeyId: options.agentClientSigningKeyId,
    popRequired: true,
    popVersion: options.popVersion,
    agentRelayPublicKey: agentRelay?.publicKey,
    agentRelayKeyVersion: agentRelay?.keyVersion,
    agentRelayEncryption: agentRelay?.encryption,
    agentSupportsRelayEnvelopeVersions: agentCapabilities?.supportsRelayEnvelopeVersions,
    agentPreferredRelayEnvelopeVersion: agentCapabilities?.preferredRelayEnvelopeVersion,
    agentSupportsHpkeV3: agentCapabilities?.supportsHpkeV3,
    agentSupportsSignalEnvelope: agentCapabilities?.supportsSignalEnvelope,
    agentPlatform: agentCapabilities?.platform,
    agentAppBuild: agentCapabilities?.appBuild,
    agentRatchetIdentityPublicKey: agentRatchet?.identityPublicKey,
    agentRatchetSigningPublicKey: agentRatchet?.signingPublicKey,
    agentRatchetSignedPreKeyPublicKey: agentRatchet?.signedPreKeyPublicKey,
    agentRatchetSignedPreKeyId: agentRatchet?.signedPreKeyId,
    agentRatchetSignedPreKeySignature: agentRatchet?.signedPreKeySignature,
    agentSupportsRatchetV1: agentRatchet?.supportsRatchetV1,
    createdAt: options.now,
    updatedAt: options.now,
    expiresAt: options.expiresAt,
    schemaVersion: HERMES_GATEWAY_SCHEMA_VERSION,
  });
}

export async function handleDeviceStart(req: HttpRequest, res: HttpResponse): Promise<void> {
  if (req.method !== "POST") throw httpError(405, "method_not_allowed");
  await checkPublicHttpRateLimit(clientIpFromHttpRequest(req), "hermes_gateway_device_start");
  const body = requestBody(req);
  const providedSecretHash = typeof body.deviceSecretHash === "string" ? body.deviceSecretHash.trim() : "";
  if (providedSecretHash && !isSha256Hex(providedSecretHash)) {
    throw httpError(400, "invalid_device_secret_hash");
  }
  const generatedSecret = providedSecretHash ? undefined : generateHermesGatewayDeviceSecret();
  const deviceSecretHash = generatedSecret ? hashHermesGatewayDeviceSecret(generatedSecret) : providedSecretHash;
  // L4: behind Firebase Hosting -> Cloud Run, req.ip can collapse to a small set
  // of front-end addresses, making the IP bucket coarse. Add a second rate-limit
  // dimension keyed on the supplied device-secret hash so a single stuck/abusive
  // client is throttled independently of how its source IP is observed.
  if (providedSecretHash) {
    await checkPublicHttpRateLimit(`devhash:${providedSecretHash}`, "hermes_gateway_device_start");
  }
  const deviceCode = generateHermesGatewayDeviceCode();
  const userCode = randomHermesGatewayUserCode();
  const now = Timestamp.now();
  const expiresAt = Timestamp.fromMillis(Date.now() + HERMES_GATEWAY_DEVICE_SESSION_TTL_MS);
  const clientName = sanitizedGatewayDisplayName(body.clientName, "Hermes Agent");
  const requestedScopes = sanitizeHermesGatewayScopes(body.scopes);
  const agentClientSigningPublicKey = requireGatewayClientSigningPublicKey(body.agentClientSigningPublicKeyBase64);
  const agentClientSigningPublicKeyBase64 = agentClientSigningPublicKey.toString("base64");
  const agentClientSigningKeyId = sha256Hex(agentClientSigningPublicKeyBase64).slice(0, 32);

  // The agent publishes its relay public key here so the phone can wrap event
  // bodies to it at approval time. Unsealed pairings are rejected; legacy
  // plaintext remains a read fallback only for already-queued docs.
  const agentRelay = parseRelayPublicKey(
    body,
    {
      publicKeyField: "agentRelayPublicKey",
      keyVersionField: "agentRelayKeyVersion",
      encryptionField: "agentRelayEncryption",
    },
    (message) => {
      throw httpError(400, "invalid_agent_relay_public_key", message);
    },
  );
  if (!agentRelay && !gatewayPlaintextWriteAllowed(false)) {
    throw httpError(400, "unsealed_pairing_unsupported");
  }
  const agentCapabilities = agentRelay
    ? sanitizeGatewayRelayEnvelopeCapabilities(body, (message) => {
        throw httpError(400, "invalid_agent_relay_capabilities", message);
      })
    : undefined;
  const agentRatchet = parseRatchetPrekeyBundle(body, "agent", (message) => {
    throw httpError(400, "invalid_agent_ratchet_prekey", message);
  });

  await db.doc(`hermes_gateway_device_sessions/${deviceCode}`).set(
    buildDeviceStartSession({
      deviceCode,
      userCode,
      deviceSecretHash,
      clientName,
      requestedScopes,
      agentClientSigningPublicKeyBase64,
      agentClientSigningKeyId,
      popVersion: parseGatewayPopVersionCapability(body.popVersion),
      agentRelay,
      agentCapabilities,
      agentRatchet,
      now,
      expiresAt,
    }),
  );

  const domain = process.env.BURNBAR_WEBSITE_DOMAIN ?? "https://burnbar.ai";
  setNoStore(res);
  sendJSON(res, 200, {
    deviceCode,
    deviceSecret: generatedSecret,
    userCode,
    verificationUri: `${domain}/hermes/connect`,
    verificationUriComplete: `${domain}/hermes/connect?code=${encodeURIComponent(userCode)}`,
    interval: 3,
    expiresIn: HERMES_GATEWAY_DEVICE_SESSION_TTL_MS / 1000,
  });
}

/** Approved-session response payload for /device/poll. Pure builder. */
function approvedDevicePollBody(
  data: Record<string, unknown>,
  uid: string,
  clientId: string,
  accessToken: string,
  clientDoc: HermesGatewayClientDoc,
): Record<string, unknown> {
  return stripUndefinedObject({
    status: "approved",
    uid,
    userId: uid,
    clientId,
    accessToken,
    tokenType: "Bearer",
    scopes: Array.isArray(data.scopes) ? data.scopes : [],
    client: publicClientView(clientDoc),
    homeDestinationId: clientDoc.homeDestinationId,
    relayCapable: clientDoc.relayCapable === true,
    // The phone's relay public key (copied onto the session by the approve
    // callable) so the agent can wrap its first reply body to the phone.
    phoneRelayPublicKey: clientDoc.phoneRelayPublicKey,
    phoneRelayKeyVersion: clientDoc.phoneRelayKeyVersion,
    phoneRelayEncryption: clientDoc.phoneRelayEncryption,
    phoneSupportsRelayEnvelopeVersions: clientDoc.phoneSupportsRelayEnvelopeVersions,
    phonePreferredRelayEnvelopeVersion: clientDoc.phonePreferredRelayEnvelopeVersion,
    phoneSupportsHpkeV3: clientDoc.phoneSupportsHpkeV3,
    phoneSupportsSignalEnvelope: clientDoc.phoneSupportsSignalEnvelope,
    phoneRatchetIdentityPublicKey: clientDoc.phoneRatchetIdentityPublicKey,
    phoneRatchetSigningPublicKey: clientDoc.phoneRatchetSigningPublicKey,
    phoneRatchetSignedPreKeyPublicKey: clientDoc.phoneRatchetSignedPreKeyPublicKey,
    phoneRatchetSignedPreKeyId: clientDoc.phoneRatchetSignedPreKeyId,
    phoneRatchetSignedPreKeySignature: clientDoc.phoneRatchetSignedPreKeySignature,
    phoneSupportsRatchetV1: clientDoc.phoneSupportsRatchetV1,
    supportsRatchetV1: clientDoc.supportsRatchetV1,
  });
}

async function emitApprovedDevicePoll(
  res: HttpResponse,
  ref: ReturnType<typeof db.doc>,
  data: Record<string, unknown>,
): Promise<void> {
  const accessToken = typeof data.accessToken === "string" ? data.accessToken : undefined;
  if (!accessToken) throw httpError(500, "missing_access_token");
  const uid = typeof data.uid === "string" ? data.uid : undefined;
  const clientId = typeof data.clientId === "string" ? data.clientId : undefined;
  if (!uid || !clientId) throw httpError(500, "missing_pairing_identity");
  const clientSnap = await db.doc(`users/${uid}/hermes_gateway_clients/${clientId}`).get();
  const rawClient = clientSnap.data();
  const clientDoc = isHermesGatewayClientDoc(rawClient) ? rawClient : undefined;
  if (!clientDoc) throw httpError(500, "missing_gateway_client");
  sendJSON(res, 200, approvedDevicePollBody(data, uid, clientId, accessToken, clientDoc));
  await ref.delete();
}

export async function handleDevicePoll(req: HttpRequest, res: HttpResponse): Promise<void> {
  if (req.method !== "POST") throw httpError(405, "method_not_allowed");
  const body = requestBody(req);
  const deviceCode = boundedTrimmedString(body.deviceCode, "deviceCode", 80, true);
  const deviceSecret = boundedTrimmedString(body.deviceSecret, "deviceSecret", 160, true);
  const ref = db.doc(`hermes_gateway_device_sessions/${deviceCode}`);
  const snap = await ref.get();
  if (!snap.exists) {
    sendJSON(res, 200, { status: "expired" });
    return;
  }
  const data = recordOrUndefined(snap.data());
  if (!data || typeof data.deviceSecretHash !== "string") {
    throw httpError(400, "invalid_session");
  }
  if (!safeEqualHex(hashHermesGatewayDeviceSecret(deviceSecret), data.deviceSecretHash)) {
    throw httpError(403, "invalid_device_secret");
  }
  const expiresAt = data.expiresAt instanceof Timestamp ? data.expiresAt.toMillis() : 0;
  if (expiresAt <= Date.now()) {
    await ref.set({ status: "expired", updatedAt: Timestamp.now() }, { merge: true });
    sendJSON(res, 200, { status: "expired" });
    return;
  }
  if (data.status === "approved") {
    await emitApprovedDevicePoll(res, ref, data);
    return;
  }
  if (data.status === "denied") {
    await ref.delete();
    sendJSON(res, 200, { status: "denied" });
    return;
  }
  sendJSON(res, 200, { status: "authorization_pending" });
}
