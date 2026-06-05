/**
 * @fileoverview BurnBar Cloud Hermes Gateway HTTP API and management callables.
 */

import { FieldValue, Timestamp, type DocumentData, type Query } from "firebase-admin/firestore";
import { getStorage } from "firebase-admin/storage";
import { HttpsError, onCall, onRequest, type CallableRequest } from "firebase-functions/v2/https";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { createHash, randomBytes } from "node:crypto";

import { db } from "../adminRuntime.js";
import { enforceHighRiskComputerUseCallable } from "../appCheckAttestation.js";
import { enforceAuthAndAppCheck } from "../auth.js";
import { getConfig } from "../config.js";
import { recordOrUndefined, stripUndefinedObject } from "../guards.js";
import {
  bearerTokenFromAuthorizationHeader,
  canonicalHermesGatewayUserCode,
  clampHermesGatewayLimit,
  clientAdvertisesModel,
  effectiveOversightMode,
  gatewayApprovalExpiryISO,
  generateHermesGatewayBearerToken,
  gatewayTokenExpiryISO,
  generateHermesGatewayDeviceCode,
  generateHermesGatewayDeviceSecret,
  hashHermesGatewayBearerToken,
  isHermesGatewayApprovalDoc,
  isHermesGatewayApprovalExpired,
  isHermesGatewayClientOnline,
  isHermesGatewayTokenExpired,
  hashHermesGatewayDeviceSecret,
  hasHermesGatewayScope,
  HERMES_GATEWAY_DEFAULT_DESTINATION_ID,
  HERMES_GATEWAY_DEVICE_SESSION_TTL_MS,
  HERMES_GATEWAY_MAX_ATTACHMENT_BYTES,
  HERMES_GATEWAY_MAX_EVENT_TEXT,
  HERMES_GATEWAY_MAX_MESSAGE_TEXT,
  HERMES_GATEWAY_PROTOCOL_VERSION,
  HERMES_GATEWAY_RELAY_ENCRYPTION,
  HERMES_GATEWAY_RELAY_PUBLIC_KEY_VERSION,
  HERMES_GATEWAY_SCHEMA_VERSION,
  isGatewayRelayPublicKeyB64,
  isHermesGatewayClientDoc,
  isHermesGatewayAttachmentManifestDoc,
  isSha256Hex,
  gatewayPlaintextWriteAllowed,
  makeHermesGatewaySSE,
  parseHermesGatewayCursor,
  pendingModelSwitchInFlight,
  publicApprovalView,
  publicClientView,
  randomHermesGatewayUserCode,
  requireGatewayRatchetEnvelope,
  requireProductionGatewaySignalEnvelope,
  requireProductionGatewayRelayEnvelope,
  safeEqualHex,
  sha256Hex,
  negotiateGatewayRelayEnvelopeCapabilities,
  sanitizeHermesGatewayApprovalTTL,
  sanitizeGatewayRelayEnvelopeCapabilities,
  sanitizeHermesGatewayDestinationId,
  sanitizeHermesGatewayModelId,
  sanitizeHermesGatewayModelOptions,
  sanitizeHermesGatewayOversightMode,
  sanitizeHermesGatewayScopes,
  sanitizedAttachmentIds,
  sanitizedGatewayDisplayName,
  serializeHermesGatewayEvent,
  serializeHermesGatewayTypingDoc,
  tokenPreview,
  type GatewayRelayEnvelopeDoc,
  type GatewayRatchetEnvelopeDoc,
  type GatewaySignalEnvelopeDoc,
  type HermesGatewayApprovalDoc,
  type HermesGatewayAttachmentManifestDoc,
  type HermesGatewayClientDoc,
  type HermesGatewayScope,
  type HermesGatewayRelayEnvelopeCapabilities,
} from "../hermesGateway.js";
import { logError, logInfo, wrapCallableHandler } from "../logging.js";
import {
  assertCallableApprovalNotLocked,
  checkPublicHttpRateLimit,
  clientIpFromHttpRequest,
  recordCallableApprovalFailure,
} from "./publicRateLimit.js";
import {
  boundedTrimmedString,
  isActiveBurnBarCloudProEntitlement,
  isActiveHostedQuotaEntitlement,
  isActivePremiumEntitlement,
  nowISO,
  requiredIdentifier,
  safeIdentifier,
} from "./shared.js";
import { FUNCTIONS_REGION, HOT_PATH_OPTIONS } from "../runtimeOptions.js";

type HttpRequest = {
  method?: string;
  path?: string;
  url?: string;
  body?: unknown;
  headers?: Record<string, unknown>;
  ip?: string;
  socket?: { remoteAddress?: string };
  query: Record<string, unknown>;
  get(name: string): string | undefined;
};

type HttpResponse = {
  status(code: number): HttpResponse;
  json(body: unknown): void;
  send(body?: unknown): void;
  set(name: string, value: string): void;
};

interface ResolvedGatewayGrant {
  uid: string;
  client: HermesGatewayClientDoc;
}

interface GatewayHttpError {
  status: number;
  error: string;
  detail?: string;
}

type StorageBucket = ReturnType<ReturnType<typeof getStorage>["bucket"]>;
type StorageFile = ReturnType<StorageBucket["file"]>;

// Platforms eligible to resolve an oversight gate. Mirrors the trusted-native
// escrow set enforced by the CLI-agent mission approval path so the gateway and
// mission oversight share one trust model (a web/headless device cannot approve).
const NATIVE_ESCROW_PLATFORMS = new Set(["macOS", "iOS", "iPadOS", "Android"]);

function httpError(status: number, error: string, detail?: string): GatewayHttpError {
  return { status, error, detail };
}

function isGatewayHttpError(error: unknown): error is GatewayHttpError {
  const record = recordOrUndefined(error);
  return !!record && typeof record.status === "number" && typeof record.error === "string";
}

function sendJSON(res: HttpResponse, status: number, body: Record<string, unknown>): void {
  res.status(status).json(body);
}

function setNoStore(res: HttpResponse): void {
  res.set("Cache-Control", "no-store");
}

function assertSafeAttachmentContentType(contentType: string): void {
  const mediaType = baseAttachmentContentType(contentType);
  const blocked = new Set([
    "text/html",
    "text/javascript",
    "application/javascript",
    "application/ecmascript",
    "application/xhtml+xml",
    "application/xml",
    "text/xml",
    "image/svg+xml",
  ]);
  if (!mediaType || blocked.has(mediaType)) {
    throw httpError(400, "unsafe_content_type");
  }
}

function baseAttachmentContentType(contentType: string): string {
  return contentType.split(";")[0]?.trim().toLowerCase() ?? "";
}

// Canonical id length + charset for gateway HTTP identifiers. attachments/finalize
// validates `attachmentId` with this exact contract (cap 160, [A-Za-z0-9_.:-]).
export const HERMES_GATEWAY_HTTP_ID_MAX_LENGTH = 160;
export const HERMES_GATEWAY_HTTP_ID_PATTERN = /^[A-Za-z0-9_.:-]+$/u;

export function requiredHttpIdentifier(raw: unknown, fieldName: string): string {
  const value = boundedTrimmedString(raw, fieldName, HERMES_GATEWAY_HTTP_ID_MAX_LENGTH, true);
  if (!HERMES_GATEWAY_HTTP_ID_PATTERN.test(value)) {
    throw httpError(400, `invalid_${fieldName}`);
  }
  return value;
}

/**
 * Resolve the id a /messages or /attachments/init write should adopt for its
 * Firestore doc. When the client supplies an id we accept it ONLY if it would
 * also pass the canonical `requiredHttpIdentifier` contract used by
 * /attachments/finalize (and the /actions read path) — same ≤160 cap, same
 * charset. This makes the rules symmetric: an id init adopts is always an id
 * finalize accepts, closing the asymmetry where `safeIdentifier` (no length cap,
 * lossy charset coercion) could mint an id finalize would later reject. A
 * malformed/over-long/absent id falls back to a fresh server-minted token so the
 * happy path (no client id, the common case) is unchanged.
 */
export function adoptedGatewayDocId(rawId: unknown, generateFallback: () => string): string {
  if (typeof rawId === "string") {
    const trimmed = rawId.trim();
    if (
      trimmed.length > 0 &&
      trimmed.length <= HERMES_GATEWAY_HTTP_ID_MAX_LENGTH &&
      HERMES_GATEWAY_HTTP_ID_PATTERN.test(trimmed)
    ) {
      return trimmed;
    }
  }
  return generateFallback();
}

function requestedAttachmentHash(raw: unknown): string | undefined {
  if (raw == null) return undefined;
  if (!isSha256Hex(raw)) {
    throw httpError(400, "invalid_sha256");
  }
  return raw.trim().toLowerCase();
}

interface ParsedRelayPublicKey {
  publicKey: string;
  keyVersion: number;
  encryption: string;
}

interface ParsedRatchetPrekeyBundle {
  identityPublicKey: string;
  signingPublicKey: string;
  signedPreKeyPublicKey: string;
  signedPreKeyId: string;
  signedPreKeySignature: string;
  supportsRatchetV1: boolean;
}

/**
 * Parse + validate a published relay public-key trio from a request body. Reads
 * `<publicKeyField>` (base64 X9.63 P-256, 65B/0x04), `<keyVersionField>` (int
 * 1..100, default 1) and `<encryptionField>` (must equal the relay algorithm
 * constant, default the constant). Returns undefined when the public key is
 * absent (legacy pairing); throws on a malformed/forged value. `throwError`
 * adapts the error type to the calling surface (HTTP vs callable).
 */
function parseRelayPublicKey(
  body: Record<string, unknown>,
  fields: { publicKeyField: string; keyVersionField: string; encryptionField: string },
  throwError: (message: string) => never,
): ParsedRelayPublicKey | undefined {
  const rawKey = body[fields.publicKeyField];
  if (rawKey == null || rawKey === "") return undefined;
  const publicKey = isGatewayRelayPublicKeyB64(rawKey);
  if (!publicKey) {
    throwError(`${fields.publicKeyField} must be a base64 X9.63 P-256 public key (65 bytes, 0x04-prefixed).`);
  }
  const rawVersion = body[fields.keyVersionField];
  const keyVersion =
    rawVersion == null
      ? HERMES_GATEWAY_RELAY_PUBLIC_KEY_VERSION
      : typeof rawVersion === "number"
        ? Math.floor(rawVersion)
        : Number(rawVersion);
  if (keyVersion !== HERMES_GATEWAY_RELAY_PUBLIC_KEY_VERSION) {
    throwError(`${fields.keyVersionField} must be ${HERMES_GATEWAY_RELAY_PUBLIC_KEY_VERSION}.`);
  }
  const rawEncryption = body[fields.encryptionField];
  const encryption =
    rawEncryption == null || rawEncryption === ""
      ? HERMES_GATEWAY_RELAY_ENCRYPTION
      : typeof rawEncryption === "string"
        ? rawEncryption.trim()
        : "";
  if (encryption !== HERMES_GATEWAY_RELAY_ENCRYPTION) {
    throwError(`${fields.encryptionField} must be ${HERMES_GATEWAY_RELAY_ENCRYPTION}.`);
  }
  return { publicKey, keyVersion, encryption };
}

function ratchetBundleField(body: Record<string, unknown>, prefix: "agent" | "phone", suffix: string): unknown {
  const prefixed = `${prefix}Ratchet${suffix}`;
  const generic = `ratchet${suffix}`;
  return body[prefixed] ?? body[generic];
}

function ratchetBundleBoolean(body: Record<string, unknown>, prefix: "agent" | "phone"): boolean | undefined {
  const raw = body[`${prefix}SupportsRatchetV1`] ?? body.supportsRatchetV1;
  if (raw === undefined || raw === null || raw === "") return undefined;
  return raw === true;
}

function ratchetPrekeyId(raw: unknown): string | undefined {
  if (typeof raw !== "string") return undefined;
  const value = raw.trim();
  if (!value || value.length > 160 || /[\r\n/]/u.test(value)) return undefined;
  return value;
}

function ratchetSignature(raw: unknown): string | undefined {
  if (typeof raw !== "string") return undefined;
  const value = raw.trim();
  if (!value || value.length > 1024 || !/^[A-Za-z0-9+/=]+$/u.test(value)) return undefined;
  try {
    Buffer.from(value, "base64");
  } catch {
    return undefined;
  }
  return value;
}

function parseRatchetPrekeyBundle(
  body: Record<string, unknown>,
  prefix: "agent" | "phone",
  throwError: (message: string) => never,
): ParsedRatchetPrekeyBundle | undefined {
  const supports = ratchetBundleBoolean(body, prefix);
  const rawIdentityPublicKey = ratchetBundleField(body, prefix, "IdentityPublicKey");
  const rawSigningPublicKey = ratchetBundleField(body, prefix, "SigningPublicKey");
  const rawSignedPreKeyPublicKey = ratchetBundleField(body, prefix, "SignedPreKeyPublicKey");
  const rawSignedPreKeyId = ratchetBundleField(body, prefix, "SignedPreKeyId");
  const rawSignedPreKeySignature = ratchetBundleField(body, prefix, "SignedPreKeySignature");
  const identityPublicKey = isGatewayRelayPublicKeyB64(rawIdentityPublicKey);
  const signingPublicKey = isGatewayRelayPublicKeyB64(rawSigningPublicKey);
  const signedPreKeyPublicKey = isGatewayRelayPublicKeyB64(rawSignedPreKeyPublicKey);
  const signedPreKeyId = ratchetPrekeyId(rawSignedPreKeyId);
  const signedPreKeySignature = ratchetSignature(rawSignedPreKeySignature);
  const rawFieldsPresent =
    rawIdentityPublicKey !== undefined ||
    rawSigningPublicKey !== undefined ||
    rawSignedPreKeyPublicKey !== undefined ||
    rawSignedPreKeyId !== undefined ||
    rawSignedPreKeySignature !== undefined;
  const anyPresent = supports !== undefined || rawFieldsPresent;
  if (!anyPresent) return undefined;
  if (supports === false && !rawFieldsPresent) return undefined;
  if (!identityPublicKey) throwError(`${prefix}RatchetIdentityPublicKey must be a base64 X9.63 P-256 public key.`);
  if (!signingPublicKey) throwError(`${prefix}RatchetSigningPublicKey must be a base64 X9.63 P-256 public key.`);
  if (!signedPreKeyPublicKey) {
    throwError(`${prefix}RatchetSignedPreKeyPublicKey must be a base64 X9.63 P-256 public key.`);
  }
  if (!signedPreKeyId) throwError(`${prefix}RatchetSignedPreKeyId must be a non-empty safe identifier.`);
  if (!signedPreKeySignature) throwError(`${prefix}RatchetSignedPreKeySignature must be base64 within the size cap.`);
  return {
    identityPublicKey,
    signingPublicKey,
    signedPreKeyPublicKey,
    signedPreKeyId,
    signedPreKeySignature,
    supportsRatchetV1: true,
  };
}

interface ResolvedGatewayWriteBody {
  relayEnvelope?: GatewayRelayEnvelopeDoc;
  ratchetEnvelope?: GatewayRatchetEnvelopeDoc;
  signalEnvelope?: GatewaySignalEnvelopeDoc;
  legacyText?: string;
}

/**
 * Decide whether a phone/agent write carries a sealed body and enforce the
 * privacy gate. Precedence:
 *   1. A present relayEnvelope is validated (shape only) and ALWAYS used; any
 *      plaintext text supplied alongside it is ignored (the sealed body wins).
 *   2. With no envelope, plaintext is rejected. The legacy plaintext output is
 *      retained only as dead-code-compatible shape for old test fixtures and
 *      read paths; gatewayPlaintextWriteAllowed() now always returns false.
 */
function resolveGatewayWriteBody(
  rawEnvelope: unknown,
  rawRatchetEnvelope: unknown,
  rawSignalEnvelope: unknown,
  rawText: unknown,
  client: Pick<HermesGatewayClientDoc, "id" | "relayCapable">,
  surface: "events" | "messages",
): ResolvedGatewayWriteBody {
  const providedEnvelopeCount = [rawEnvelope, rawRatchetEnvelope, rawSignalEnvelope].filter(
    (value) => value != null,
  ).length;
  if (providedEnvelopeCount > 1) {
    throw new HttpsError(
      "invalid-argument",
      "ambiguous_ciphertext: provide only one of relayEnvelope, ratchetEnvelope, or signalEnvelope.",
    );
  }
  if (rawSignalEnvelope != null) {
    return { signalEnvelope: requireProductionGatewaySignalEnvelope(rawSignalEnvelope, "signalEnvelope") };
  }
  if (rawRatchetEnvelope != null) {
    return { ratchetEnvelope: requireGatewayRatchetEnvelope(rawRatchetEnvelope, "ratchetEnvelope") };
  }
  if (rawEnvelope != null) {
    return { relayEnvelope: requireProductionGatewayRelayEnvelope(rawEnvelope, "relayEnvelope") };
  }
  const text = typeof rawText === "string" ? rawText.trim() : "";
  if (!text) return {};
  if (!gatewayPlaintextWriteAllowed(client.relayCapable)) {
    throw new HttpsError(
      "invalid-argument",
      "ciphertext_required: a relayEnvelope or ratchetEnvelope is required for Hermes Gateway message bodies.",
    );
  }
  logInfo({
    event: "hermes_gateway.plaintext_body_deprecated",
    surface,
    client_id: client.id,
    relay_capable: client.relayCapable === true,
  });
  const maxLen = surface === "events" ? HERMES_GATEWAY_MAX_EVENT_TEXT : HERMES_GATEWAY_MAX_MESSAGE_TEXT;
  return { legacyText: text.slice(0, maxLen) };
}

function requireSafeGatewayEventId(raw: unknown): string {
  const value = requiredIdentifier(raw, "eventId");
  const safe = safeIdentifier(value, "evt");
  if (safe !== value || !safe.startsWith("evt_")) {
    throw new HttpsError("invalid-argument", "eventId must be a safe evt_ identifier.");
  }
  return safe;
}

function statusCodeForAttachmentManifest(status: HermesGatewayAttachmentManifestDoc["status"]): number {
  if (status === "expired") return 410;
  if (status === "rejected" || status === "failed") return 409;
  return 400;
}

/**
 * Legacy (unsealed) attachment integrity: the stored object's observed media
 * type must match the declared one and be a safe type. Rejects the manifest on
 * mismatch. Sealed uploads skip this entirely — their bytes are opaque
 * ciphertext, integrity-checked by the ciphertext sha256.
 */
async function assertLegacyAttachmentContentType(
  ref: { set: (data: Record<string, unknown>, opts: { merge: boolean }) => Promise<unknown> },
  declaredContentType: string,
  observedContentType: string,
): Promise<void> {
  const declaredMediaType = baseAttachmentContentType(declaredContentType);
  const observedMediaType = baseAttachmentContentType(observedContentType);
  if (!observedMediaType || observedMediaType !== declaredMediaType) {
    await ref.set({ status: "rejected", updatedAt: nowISO() }, { merge: true });
    throw httpError(400, "attachment_content_type_mismatch");
  }
  assertSafeAttachmentContentType(observedContentType);
}

async function sha256ForStorageFile(file: StorageFile): Promise<string> {
  return await new Promise((resolve, reject) => {
    const hash = createHash("sha256");
    file
      .createReadStream()
      .on("data", (chunk: Buffer | string) => {
        hash.update(chunk);
      })
      .on("error", reject)
      .on("end", () => {
        resolve(hash.digest("hex"));
      });
  });
}

async function requireUploadedGatewayAttachments(params: {
  uid: string;
  clientId?: string;
  destinationId?: string;
  attachmentIds: string[];
}): Promise<void> {
  await Promise.all(
    params.attachmentIds.map(async (attachmentId) => {
      const snap = await db.doc(`users/${params.uid}/hermes_gateway_attachments/${attachmentId}`).get();
      const manifest = snap.data();
      if (!snap.exists || !isHermesGatewayAttachmentManifestDoc(manifest)) {
        throw new HttpsError("invalid-argument", `Hermes Gateway attachment ${attachmentId} was not found.`);
      }
      if (params.clientId && manifest.clientId !== params.clientId) {
        throw new HttpsError(
          "permission-denied",
          `Hermes Gateway attachment ${attachmentId} belongs to another client.`,
        );
      }
      if (params.destinationId && manifest.destinationId && manifest.destinationId !== params.destinationId) {
        throw new HttpsError(
          "invalid-argument",
          `Hermes Gateway attachment ${attachmentId} belongs to another destination.`,
        );
      }
      if (manifest.status !== "uploaded") {
        throw new HttpsError(
          "invalid-argument",
          `Hermes Gateway attachment ${attachmentId} must be finalized before use.`,
        );
      }
    }),
  );
}

function gatewayPath(req: HttpRequest): string {
  const path = req.path || new URL(req.url || "/", "https://api.burnbar.ai").pathname;
  return (
    path
      .replace(/^\/burnBarHermesGateway\b/, "")
      .replace(/^\/v1\/hermes-gateway\b/, "")
      .replace(/\/+$/, "") || "/"
  );
}

function requestBody(req: HttpRequest): Record<string, unknown> {
  return recordOrUndefined(req.body) ?? {};
}

function header(req: HttpRequest, name: string): string | undefined {
  const value = req.get(name);
  return typeof value === "string" ? value : undefined;
}

async function assertActiveHermesGatewayEntitlement(uid: string): Promise<void> {
  const [hostedSnap, proSnap, proMaxSnap] = await Promise.all([
    db.doc(`users/${uid}/entitlements/hosted_quota_sync`).get(),
    db.doc(`users/${uid}/entitlements/burnbar_pro`).get(),
    db.doc(`users/${uid}/entitlements/burnbar_pro_max`).get(),
  ]);
  if (isActiveHostedQuotaEntitlement(hostedSnap.data())) return;
  if (isActivePremiumEntitlement(proSnap.data())) return;
  if (isActiveBurnBarCloudProEntitlement(proMaxSnap.data())) return;
  throw new HttpsError("permission-denied", "BurnBar Cloud or BurnBar Cloud Pro is required for Hermes Gateway.");
}

async function assertActiveHermesGatewayClient(uid: string, targetClientId: string): Promise<HermesGatewayClientDoc> {
  const ref = db.doc(`users/${uid}/hermes_gateway_clients/${targetClientId}`);
  const snap = await ref.get();
  const client = snap.data();
  if (!snap.exists || !isHermesGatewayClientDoc(client) || client.status !== "active" || client.id !== targetClientId) {
    throw new HttpsError("failed-precondition", "Selected Hermes Gateway client is not active.");
  }
  return client;
}

async function resolveGatewayGrant(req: HttpRequest, scope: HermesGatewayScope): Promise<ResolvedGatewayGrant> {
  const token = bearerTokenFromAuthorizationHeader(header(req, "authorization"));
  if (!token) throw httpError(401, "missing_bearer_token");
  const tokenHash = hashHermesGatewayBearerToken(token);
  const indexSnap = await db.doc(`hermes_gateway_token_index/${tokenHash}`).get();
  const index = recordOrUndefined(indexSnap.data());
  if (!indexSnap.exists || !index || typeof index.uid !== "string" || typeof index.clientId !== "string") {
    throw httpError(401, "invalid_bearer_token");
  }
  const clientRef = db.doc(`users/${index.uid}/hermes_gateway_clients/${index.clientId}`);
  const clientSnap = await clientRef.get();
  const client = clientSnap.data();
  if (!clientSnap.exists || !isHermesGatewayClientDoc(client) || client.status !== "active") {
    throw httpError(401, "revoked_bearer_token");
  }
  if (client.tokenHash !== tokenHash) {
    await db
      .doc(`hermes_gateway_token_index/${tokenHash}`)
      .delete()
      .catch(() => undefined);
    throw httpError(401, "stale_bearer_token");
  }
  if (isHermesGatewayTokenExpired(client.expiresAt)) {
    throw httpError(401, "expired_bearer_token");
  }
  if (!hasHermesGatewayScope(client.scopes, scope)) {
    throw httpError(403, "missing_scope", scope);
  }
  await assertActiveHermesGatewayEntitlement(index.uid);
  const now = nowISO();
  // Grandfather legacy tokens: backfill a default expiry on first use so
  // pre-expiry tokens eventually age out without mass-invalidation.
  const expiresAtBackfill = client.expiresAt ? undefined : gatewayTokenExpiryISO();
  await Promise.all([
    clientRef.set(stripUndefinedObject({ lastSeenAt: now, updatedAt: now, expiresAt: expiresAtBackfill }), {
      merge: true,
    }),
    expiresAtBackfill
      ? db.doc(`hermes_gateway_token_index/${tokenHash}`).set({ expiresAt: expiresAtBackfill }, { merge: true })
      : Promise.resolve(),
  ]);
  return { uid: index.uid, client };
}

function defaultDestinationDoc(now: string) {
  return {
    id: HERMES_GATEWAY_DEFAULT_DESTINATION_ID,
    displayName: "BurnBar Home",
    kind: "home",
    status: "active",
    isDefault: true,
    createdAt: now,
    updatedAt: now,
    schemaVersion: HERMES_GATEWAY_SCHEMA_VERSION,
  };
}

async function ensureDefaultDestination(uid: string, now = nowISO()): Promise<void> {
  await db.doc(`users/${uid}/hermes_gateway_destinations/home`).set(defaultDestinationDoc(now), { merge: true });
}

async function handleDeviceStart(req: HttpRequest, res: HttpResponse): Promise<void> {
  if (req.method !== "POST") throw httpError(405, "method_not_allowed");
  await checkPublicHttpRateLimit(clientIpFromHttpRequest(req), "hermes_gateway_device_start");
  const body = requestBody(req);
  const providedSecretHash = typeof body.deviceSecretHash === "string" ? body.deviceSecretHash.trim() : "";
  if (providedSecretHash && !isSha256Hex(providedSecretHash)) {
    throw httpError(400, "invalid_device_secret_hash");
  }
  const generatedSecret = providedSecretHash ? undefined : generateHermesGatewayDeviceSecret();
  const deviceSecretHash = generatedSecret ? hashHermesGatewayDeviceSecret(generatedSecret) : providedSecretHash;
  const deviceCode = generateHermesGatewayDeviceCode();
  const userCode = randomHermesGatewayUserCode();
  const now = Timestamp.now();
  const expiresAt = Timestamp.fromMillis(Date.now() + HERMES_GATEWAY_DEVICE_SESSION_TTL_MS);
  const clientName = sanitizedGatewayDisplayName(body.clientName, "Hermes Agent");
  const requestedScopes = sanitizeHermesGatewayScopes(body.scopes);

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
    stripUndefinedObject({
      deviceCode,
      userCode,
      deviceSecretHash,
      status: "pending",
      clientName,
      requestedScopes,
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
      createdAt: now,
      updatedAt: now,
      expiresAt,
      schemaVersion: HERMES_GATEWAY_SCHEMA_VERSION,
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

async function handleDevicePoll(req: HttpRequest, res: HttpResponse): Promise<void> {
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
    const accessToken = typeof data.accessToken === "string" ? data.accessToken : undefined;
    if (!accessToken) throw httpError(500, "missing_access_token");
    const uid = typeof data.uid === "string" ? data.uid : undefined;
    const clientId = typeof data.clientId === "string" ? data.clientId : undefined;
    if (!uid || !clientId) throw httpError(500, "missing_pairing_identity");
    const clientSnap = await db.doc(`users/${uid}/hermes_gateway_clients/${clientId}`).get();
    const rawClient = clientSnap.data();
    const clientDoc = isHermesGatewayClientDoc(rawClient) ? rawClient : undefined;
    if (!clientDoc) throw httpError(500, "missing_gateway_client");
    const clientView = publicClientView(clientDoc);
    sendJSON(
      res,
      200,
      stripUndefinedObject({
        status: "approved",
        uid,
        userId: uid,
        clientId,
        accessToken,
        tokenType: "Bearer",
        scopes: Array.isArray(data.scopes) ? data.scopes : [],
        client: clientView,
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
      }),
    );
    await ref.delete();
    return;
  }
  if (data.status === "denied") {
    await ref.delete();
    sendJSON(res, 200, { status: "denied" });
    return;
  }
  sendJSON(res, 200, { status: "authorization_pending" });
}

async function handleDestinations(req: HttpRequest, res: HttpResponse): Promise<void> {
  if (req.method !== "GET") throw httpError(405, "method_not_allowed");
  const grant = await resolveGatewayGrant(req, "hermes.gateway.read");
  await ensureDefaultDestination(grant.uid);
  const snap = await db.collection(`users/${grant.uid}/hermes_gateway_destinations`).get();
  const destinations = snap.docs
    .map((doc) => doc.data())
    .filter((doc) => doc.status !== "archived")
    .sort((left, right) => {
      if (left.isDefault === true) return -1;
      if (right.isDefault === true) return 1;
      return String(left.displayName ?? "").localeCompare(String(right.displayName ?? ""));
    });
  sendJSON(res, 200, { destinations });
}

async function handleEvents(req: HttpRequest, res: HttpResponse): Promise<void> {
  if (req.method !== "GET") throw httpError(405, "method_not_allowed");
  const grant = await resolveGatewayGrant(req, "hermes.gateway.read");
  const cursor = parseHermesGatewayCursor(req.query.cursor);
  const limit = clampHermesGatewayLimit(req.query.limit);
  const destinationId =
    typeof req.query.destinationId === "string"
      ? sanitizeHermesGatewayDestinationId(req.query.destinationId)
      : undefined;
  let query = db
    .collection(`users/${grant.uid}/hermes_gateway_events`)
    .where("sequence", ">", cursor)
    .orderBy("sequence", "asc")
    .limit(limit);
  if (destinationId) {
    query = db
      .collection(`users/${grant.uid}/hermes_gateway_events`)
      .where("destinationId", "==", destinationId)
      .where("sequence", ">", cursor)
      .orderBy("sequence", "asc")
      .limit(limit);
  }
  const snap = await query.get();
  const scannedEvents = snap.docs.flatMap((doc) => {
    const event = serializeHermesGatewayEvent(doc.data());
    return event ? [event] : [];
  });
  const events = scannedEvents.filter((event) => !event.targetClientId || event.targetClientId === grant.client.id);
  const nextCursor = scannedEvents.reduce((max, event) => Math.max(max, event.sequence), cursor);
  if (header(req, "accept")?.includes("text/event-stream") || req.query.stream === "true") {
    res.set("Content-Type", "text/event-stream; charset=utf-8");
    res.set("Cache-Control", "no-store");
    res.status(200).send(makeHermesGatewaySSE(events, nextCursor));
    return;
  }
  sendJSON(res, 200, { events, nextCursor });
}

async function handleMessageSend(req: HttpRequest, res: HttpResponse): Promise<void> {
  if (req.method !== "POST") throw httpError(405, "method_not_allowed");
  const grant = await resolveGatewayGrant(req, "hermes.gateway.write");
  const body = requestBody(req);
  const destinationId = sanitizeHermesGatewayDestinationId(body.destinationId);
  const attachmentIds = sanitizedAttachmentIds(body.attachmentIds);
  if (grant.client.relayCapable !== true) {
    throw httpError(400, "unsealed_client_unsupported");
  }
  // The agent seals its reply body (the message text) to the phone's relay key
  // BEFORE this call; the server only forwards the opaque envelope. Plaintext
  // `text` is rejected on every new write.
  const sealed = resolveGatewayWriteBody(
    body.relayEnvelope,
    body.ratchetEnvelope,
    body.signalEnvelope,
    body.text,
    grant.client,
    "messages",
  );
  const attachmentsOnly = attachmentIds.length > 0;
  if (
    !sealed.relayEnvelope &&
    !sealed.ratchetEnvelope &&
    !sealed.signalEnvelope &&
    !sealed.legacyText &&
    !attachmentsOnly
  ) {
    throw httpError(400, "empty_message");
  }
  await requireUploadedGatewayAttachments({ uid: grant.uid, clientId: grant.client.id, destinationId, attachmentIds });
  const now = nowISO();
  const id = safeIdentifier(body.messageId, "msg");
  const doc = stripUndefinedObject({
    id,
    clientId: grant.client.id,
    kind: "agent_message",
    destinationId,
    // threadId/replyToEventId are private conversation-routing metadata. For new
    // sealed messages they must live inside relayEnvelope, not as top-level
    // Firestore fields.
    threadId: sealed.legacyText ? boundedTrimmedString(body.threadId, "threadId", 160, false) : undefined,
    replyToEventId: sealed.legacyText
      ? boundedTrimmedString(body.replyToEventId, "replyToEventId", 160, false)
      : undefined,
    // Sealed body for schema 2+; plaintext text is never accepted for new writes.
    relayEnvelope: sealed.relayEnvelope,
    ratchetEnvelope: sealed.ratchetEnvelope,
    signalEnvelope: sealed.signalEnvelope,
    text: sealed.legacyText,
    attachmentIds,
    createdAt: now,
    schemaVersion: HERMES_GATEWAY_SCHEMA_VERSION,
  });
  // Create-if-absent, same hardening as attachments/init: a blind
  // `set(merge:false)` would let a re-send of the same messageId clobber an
  // already-stored sealed message. We keep `safeIdentifier` (not the stricter
  // adoptedGatewayDocId) for the id here ON PURPOSE: the agent derives messageId
  // as token_hex(16) and BINDS it into the sealed body's AES-GCM AAD
  // (gatewayMessage/gatewayMessageKey). The phone re-derives that AAD from the
  // stored `id` to open the body — so the server must echo the client's id
  // byte-for-byte. token_hex(16) is already lowercase-hex, so safeIdentifier is a
  // pass-through for the real client; swapping the resolver risks perturbing an
  // AAD-bound value, and unlike attachments there is no stricter finalize
  // validator to stay symmetric with. The transaction below still closes the
  // clobber half of the finding.
  const messageRef = db.doc(`users/${grant.uid}/hermes_gateway_messages/${id}`);
  await db.runTransaction(async (tx) => {
    const existing = await tx.get(messageRef);
    if (existing.exists) {
      throw httpError(409, "message_already_sent");
    }
    tx.set(messageRef, doc);
  });
  logInfo({ event: "hermes_gateway.message_sent", client_id: grant.client.id, message_id: id });
  sendJSON(res, 200, { message: doc });
}

async function handleTyping(req: HttpRequest, res: HttpResponse): Promise<void> {
  if (req.method !== "POST") throw httpError(405, "method_not_allowed");
  const grant = await resolveGatewayGrant(req, "hermes.gateway.write");
  const body = requestBody(req);
  if (grant.client.relayCapable !== true) {
    throw httpError(400, "unsealed_client_unsupported");
  }
  const destinationId = sanitizeHermesGatewayDestinationId(body.destinationId);
  const now = nowISO();
  const doc = serializeHermesGatewayTypingDoc({
    clientId: grant.client.id,
    destinationId,
    createdAt: now,
    expiresAt: new Date(Date.now() + 15_000).toISOString(),
  });
  await db.doc(`users/${grant.uid}/hermes_gateway_typing/${grant.client.id}`).set(doc, { merge: true });
  sendJSON(res, 200, { success: true });
}

async function handleRuntimeStatus(req: HttpRequest, res: HttpResponse): Promise<void> {
  if (req.method !== "POST") throw httpError(405, "method_not_allowed");
  const grant = await resolveGatewayGrant(req, "hermes.gateway.write");
  const body = requestBody(req);
  const runtimeModelId = sanitizeHermesGatewayModelId(body.currentModelId);
  const runtimeProviderId = boundedTrimmedString(body.currentProviderId, "currentProviderId", 80, false);
  const runtimeModelOptions = sanitizeHermesGatewayModelOptions(body.modelOptions);
  const agentVersion = boundedTrimmedString(body.agentVersion, "agentVersion", 120, false);
  // The agent MAY publish its relay public key here, but only to ESTABLISH it on
  // first pairing (trust-on-first-use). Once a key is pinned on the client doc it
  // is IMMUTABLE: a /runtime request can never overwrite it. A bearer token alone
  // must not be able to swap the pinned relay key — that would let the server (or
  // any token holder) substitute its own key and MITM the sealed channel. Rotation
  // is explicit re-pair only: no relay-supplied update, signed or unsigned, can
  // change a pin in place.
  const agentRelay = parseRelayPublicKey(
    body,
    {
      publicKeyField: "agentRelayPublicKey",
      keyVersionField: "agentRelayKeyVersion",
      encryptionField: "agentRelayEncryption",
    },
    (message) => {
      throw new HttpsError("invalid-argument", message);
    },
  );
  const pinnedAgentKey =
    typeof grant.client.agentRelayPublicKey === "string" ? grant.client.agentRelayPublicKey : undefined;
  // Decide whether this request may WRITE the relay-key fields. We write them only
  // when no key is pinned yet (first pairing). If a key is already pinned and the
  // incoming one differs, we DROP the incoming key (do not write) and log a
  // security event so the substitution attempt is auditable. A re-publish of the
  // SAME pinned key is a harmless no-op (no write needed, no alert).
  let agentRelayKeyWrite: ParsedRelayPublicKey | undefined;
  let agentCapabilities: HermesGatewayRelayEnvelopeCapabilities | undefined;
  if (agentRelay) {
    if (!pinnedAgentKey) {
      agentRelayKeyWrite = agentRelay;
      agentCapabilities = sanitizeGatewayRelayEnvelopeCapabilities(body);
    } else if (agentRelay.publicKey === pinnedAgentKey) {
      agentCapabilities = sanitizeGatewayRelayEnvelopeCapabilities(body);
    } else if (agentRelay.publicKey !== pinnedAgentKey) {
      logInfo({
        event: "hermes_gateway.relay_key_change_rejected",
        reason: "agent_relay_public_key_immutable",
        client_id: grant.client.id,
        user_id_hash: grant.uid.slice(0, 8),
      });
    }
  }
  const requestedAgentRatchet = parseRatchetPrekeyBundle(body, "agent", (message) => {
    throw new HttpsError("invalid-argument", message);
  });
  const pinnedAgentRatchetIdentity =
    typeof grant.client.agentRatchetIdentityPublicKey === "string"
      ? grant.client.agentRatchetIdentityPublicKey
      : undefined;
  let agentRatchetWrite: ParsedRatchetPrekeyBundle | undefined;
  if (requestedAgentRatchet) {
    if (!pinnedAgentRatchetIdentity || requestedAgentRatchet.identityPublicKey === pinnedAgentRatchetIdentity) {
      agentRatchetWrite = requestedAgentRatchet;
    } else {
      logInfo({
        event: "hermes_gateway.ratchet_identity_change_rejected",
        reason: "agent_ratchet_identity_immutable",
        client_id: grant.client.id,
        user_id_hash: grant.uid.slice(0, 8),
      });
    }
  }
  const now = nowISO();
  // Reconcile the optimistic model-switch marker: once the runtime reports it is
  // actually running the requested model, clear pendingModelId so /state stops
  // reporting "switching…". A no-op when there is no pending switch.
  const pending = typeof grant.client.pendingModelId === "string" ? grant.client.pendingModelId.trim() : "";
  const settled = !!pending && !!runtimeModelId && pending.toLowerCase() === runtimeModelId.trim().toLowerCase();
  // relayCapable becomes true once BOTH endpoints have a key on record. The agent
  // key counts whether it was just pinned now or pinned earlier.
  const phoneKeyOnRecord = typeof grant.client.phoneRelayPublicKey === "string";
  const agentKeyOnRecord = pinnedAgentKey !== undefined || agentRelayKeyWrite != null;
  const relayCapable = agentKeyOnRecord && phoneKeyOnRecord ? true : undefined;
  const phoneCapabilities = phoneKeyOnRecord
    ? sanitizeGatewayRelayEnvelopeCapabilities({
        supportsRelayEnvelopeVersions: grant.client.phoneSupportsRelayEnvelopeVersions,
        preferredRelayEnvelopeVersion: grant.client.phonePreferredRelayEnvelopeVersion,
        supportsHpkeV3: grant.client.phoneSupportsHpkeV3,
        supportsSignalEnvelope: grant.client.phoneSupportsSignalEnvelope,
        clientPlatform: grant.client.phonePlatform,
        clientAppBuild: grant.client.phoneAppBuild,
      })
    : undefined;
  const negotiatedCapabilities =
    agentCapabilities && phoneCapabilities
      ? negotiateGatewayRelayEnvelopeCapabilities(agentCapabilities, phoneCapabilities)
      : undefined;
  const agentRatchetOnRecord = pinnedAgentRatchetIdentity !== undefined || agentRatchetWrite != null;
  const phoneRatchetOnRecord = grant.client.phoneSupportsRatchetV1 === true;
  const supportsRatchetV1 = agentRatchetOnRecord && phoneRatchetOnRecord ? true : undefined;
  await db.doc(`users/${grant.uid}/hermes_gateway_clients/${grant.client.id}`).set(
    stripUndefinedObject({
      runtimeModelId,
      runtimeProviderId,
      runtimeModelOptions,
      agentVersion,
      // Pin-only: relay-key fields are written ONLY on first pairing
      // (agentRelayKeyWrite set). Once pinned they are never overwritten here.
      agentRelayPublicKey: agentRelayKeyWrite?.publicKey,
      agentRelayKeyVersion: agentRelayKeyWrite?.keyVersion,
      agentRelayEncryption: agentRelayKeyWrite?.encryption,
      agentSupportsRelayEnvelopeVersions: agentCapabilities?.supportsRelayEnvelopeVersions,
      agentPreferredRelayEnvelopeVersion: agentCapabilities?.preferredRelayEnvelopeVersion,
      agentSupportsHpkeV3: agentCapabilities?.supportsHpkeV3,
      agentSupportsSignalEnvelope: agentCapabilities?.supportsSignalEnvelope,
      agentPlatform: agentCapabilities?.platform,
      agentAppBuild: agentCapabilities?.appBuild,
      supportsRelayEnvelopeVersions: negotiatedCapabilities?.supportsRelayEnvelopeVersions,
      preferredRelayEnvelopeVersion: negotiatedCapabilities?.preferredRelayEnvelopeVersion,
      supportsHpkeV3: negotiatedCapabilities?.supportsHpkeV3,
      supportsSignalEnvelope: negotiatedCapabilities?.supportsSignalEnvelope,
      agentRatchetIdentityPublicKey: agentRatchetWrite?.identityPublicKey,
      agentRatchetSigningPublicKey: agentRatchetWrite?.signingPublicKey,
      agentRatchetSignedPreKeyPublicKey: agentRatchetWrite?.signedPreKeyPublicKey,
      agentRatchetSignedPreKeyId: agentRatchetWrite?.signedPreKeyId,
      agentRatchetSignedPreKeySignature: agentRatchetWrite?.signedPreKeySignature,
      agentSupportsRatchetV1: agentRatchetWrite?.supportsRatchetV1,
      supportsRatchetV1,
      relayCapable,
      runtimeUpdatedAt: now,
      lastSeenAt: now,
      updatedAt: now,
      pendingModelId: settled ? FieldValue.delete() : undefined,
      pendingModelRequestedAt: settled ? FieldValue.delete() : undefined,
      schemaVersion: HERMES_GATEWAY_SCHEMA_VERSION,
    }),
    { merge: true },
  );
  sendJSON(res, 200, {
    success: true,
    runtimeModelId,
    runtimeProviderId,
    agentVersion,
    modelOptionCount: runtimeModelOptions.length,
    pendingModelSwitchSettled: settled,
    runtimeUpdatedAt: now,
  });
}

/**
 * GET /state — a single truthful snapshot of the gateway: the event cursor, the
 * paired clients with DERIVED online/offline + in-flight model switch, the
 * current model, the oversight mode, and version metadata. Read-only: it never
 * bumps the event cursor. Presence is derived from lastSeenAt at read time, so a
 * stopped gateway reports offline without any write.
 */
async function handleGatewayState(req: HttpRequest, res: HttpResponse): Promise<void> {
  if (req.method !== "GET") throw httpError(405, "method_not_allowed");
  const grant = await resolveGatewayGrant(req, "hermes.gateway.read");
  const now = Date.now();
  const nowIso = new Date(now).toISOString();
  const [stateSnap, clientsSnap] = await Promise.all([
    db.doc(`users/${grant.uid}/hermes_gateway_state/cursors`).get(),
    db.collection(`users/${grant.uid}/hermes_gateway_clients`).get(),
  ]);
  const eventSequence = Number(stateSnap.get("eventSequence") ?? 0);
  const activeClients = clientsSnap.docs
    .flatMap((doc): HermesGatewayClientDoc[] => {
      const client = doc.data();
      return isHermesGatewayClientDoc(client) ? [client] : [];
    })
    .filter((client) => client.status === "active")
    .sort((left, right) => right.updatedAt.localeCompare(left.updatedAt));
  const clients = activeClients.map((client) => ({
    ...publicClientView(client),
    online: isHermesGatewayClientOnline(client.lastSeenAt, now),
    pendingModelSwitch: pendingModelSwitchInFlight(client, now),
  }));
  const onlineCount = activeClients.filter((client) => isHermesGatewayClientOnline(client.lastSeenAt, now)).length;
  // The "current model" is whatever the freshest online client is running.
  const primary = activeClients.find((client) => isHermesGatewayClientOnline(client.lastSeenAt, now));
  sendJSON(res, 200, {
    online: onlineCount > 0,
    generatedAt: nowIso,
    eventSequence: Number.isFinite(eventSequence) ? eventSequence : 0,
    schemaVersion: HERMES_GATEWAY_SCHEMA_VERSION,
    protocolVersion: HERMES_GATEWAY_PROTOCOL_VERSION,
    currentModelId: primary?.runtimeModelId ?? null,
    currentProviderId: primary?.runtimeProviderId ?? null,
    agentVersion: primary?.agentVersion ?? null,
    oversightMode: effectiveOversightMode(primary?.oversightMode),
    connectedClientCount: onlineCount,
    clientCount: clients.length,
    clients,
  });
}

async function handleAttachmentInit(req: HttpRequest, res: HttpResponse): Promise<void> {
  if (req.method !== "POST") throw httpError(405, "method_not_allowed");
  const grant = await resolveGatewayGrant(req, "hermes.gateway.write");
  const body = requestBody(req);
  // Sealed attachments (schema 2+): the agent seals the BYTES before uploading,
  // and seals {fileName,byteCount,contentType} into either relayEnvelope or the
  // Phase 6 ratchetEnvelope. The server never sees the plaintext name or bytes.
  // byteCount is the CIPHERTEXT length (≈ plaintext + 28B GCM overhead); the
  // stored object is opaque (application/octet-stream).
  const providedEnvelopeCount = [body.relayEnvelope, body.ratchetEnvelope, body.signalEnvelope].filter(
    (value) => value != null,
  ).length;
  if (providedEnvelopeCount > 1) {
    throw new HttpsError(
      "invalid-argument",
      "ambiguous_ciphertext: provide only one of relayEnvelope, ratchetEnvelope, or signalEnvelope.",
    );
  }
  const signalEnvelope =
    body.signalEnvelope != null
      ? requireProductionGatewaySignalEnvelope(body.signalEnvelope, "signalEnvelope")
      : undefined;
  const sealedEnvelope =
    body.relayEnvelope != null ? requireProductionGatewayRelayEnvelope(body.relayEnvelope, "relayEnvelope") : undefined;
  const ratchetEnvelope =
    body.ratchetEnvelope != null ? requireGatewayRatchetEnvelope(body.ratchetEnvelope, "ratchetEnvelope") : undefined;
  const sealed = sealedEnvelope != null || ratchetEnvelope != null || signalEnvelope != null;
  if (!sealed && !gatewayPlaintextWriteAllowed(grant.client.relayCapable)) {
    throw new HttpsError(
      "invalid-argument",
      "ciphertext_required: a relayEnvelope or ratchetEnvelope (with the sealed fileName) is required for Hermes Gateway attachments.",
    );
  }
  // Plaintext fileName is never accepted for new writes; the name lives inside
  // the envelope and is never stored cleartext.
  const legacyFileName = sealed
    ? undefined
    : boundedTrimmedString(body.fileName, "fileName", 255, true).replace(/[\\/]/g, "-");
  if (legacyFileName !== undefined) {
    logInfo({ event: "hermes_gateway.plaintext_filename_deprecated", client_id: grant.client.id });
  }
  // Declared content type: opaque ciphertext on the sealed path, the real type on
  // the legacy path (where it is still validated against the unsafe-type list).
  const declaredContentType = sealed
    ? "application/octet-stream"
    : boundedTrimmedString(body.contentType, "contentType", 128, true);
  if (!sealed) {
    assertSafeAttachmentContentType(declaredContentType);
  }
  const byteCount = typeof body.byteCount === "number" ? body.byteCount : Number(body.byteCount);
  if (!Number.isFinite(byteCount) || byteCount < 1 || byteCount > HERMES_GATEWAY_MAX_ATTACHMENT_BYTES) {
    throw httpError(400, "invalid_byte_count");
  }
  const destinationId = sanitizeHermesGatewayDestinationId(body.destinationId);
  // Adopt a client-supplied attachmentId only when it ALSO passes the canonical
  // finalize contract (≤160, [A-Za-z0-9_.:-]); otherwise mint a fresh token. This
  // keeps init↔finalize symmetric (no id init accepts that finalize would reject).
  const attachmentId = adoptedGatewayDocId(body.attachmentId, () => `att_${randomBytes(8).toString("hex")}`);
  // The storage object name carries NO fileName segment — the file name is
  // private and never appears in a path the server (or a Storage listing) sees.
  const storagePath = `users/${grant.uid}/hermes_gateway_attachments/${grant.client.id}/${attachmentId}`;
  const expiresAt = new Date(Date.now() + 10 * 60 * 1000);
  const [uploadURL] = await getStorage().bucket().file(storagePath).getSignedUrl({
    version: "v4",
    action: "write",
    expires: expiresAt,
    contentType: declaredContentType,
  });
  const now = nowISO();
  const manifest = stripUndefinedObject({
    id: attachmentId,
    clientId: grant.client.id,
    destinationId,
    fileName: legacyFileName,
    relayEnvelope: sealedEnvelope,
    ratchetEnvelope,
    signalEnvelope,
    contentType: declaredContentType,
    byteCount,
    storagePath,
    status: "pending_upload",
    createdAt: now,
    expiresAt: expiresAt.toISOString(),
    schemaVersion: HERMES_GATEWAY_SCHEMA_VERSION,
  });
  // Create-if-absent: a blind `set(merge:false)` would re-mint a fresh signed
  // upload URL over an already-initialized attachment doc. Adopting an id is now a
  // create — a re-init of an existing id (malicious or buggy) is rejected (409)
  // rather than clobbering the prior manifest. The agent's 128-bit token_hex makes
  // an honest collision negligible.
  const attachmentRef = db.doc(`users/${grant.uid}/hermes_gateway_attachments/${attachmentId}`);
  await db.runTransaction(async (tx) => {
    const existing = await tx.get(attachmentRef);
    if (existing.exists) {
      throw httpError(409, "attachment_already_initialized");
    }
    tx.set(attachmentRef, manifest);
  });
  sendJSON(res, 200, { attachment: manifest, uploadURL, maxBytes: HERMES_GATEWAY_MAX_ATTACHMENT_BYTES });
}

async function handleAttachmentFinalize(req: HttpRequest, res: HttpResponse): Promise<void> {
  if (req.method !== "POST") throw httpError(405, "method_not_allowed");
  const grant = await resolveGatewayGrant(req, "hermes.gateway.write");
  const body = requestBody(req);
  const attachmentId = requiredHttpIdentifier(body.attachmentId, "attachmentId");
  const expectedSha256 = requestedAttachmentHash(body.sha256);
  const requestedDestinationId =
    body.destinationId == null ? undefined : sanitizeHermesGatewayDestinationId(body.destinationId);
  const ref = db.doc(`users/${grant.uid}/hermes_gateway_attachments/${attachmentId}`);
  const snap = await ref.get();
  const manifest = snap.data();
  if (!snap.exists || !isHermesGatewayAttachmentManifestDoc(manifest) || manifest.id !== attachmentId) {
    throw httpError(404, "attachment_not_found");
  }
  if (manifest.clientId !== grant.client.id) {
    throw httpError(403, "attachment_client_mismatch");
  }
  if (requestedDestinationId && manifest.destinationId && manifest.destinationId !== requestedDestinationId) {
    throw httpError(400, "attachment_destination_mismatch");
  }
  // Sealed manifests store the object at .../{attachmentId} (no fileName
  // segment); legacy manifests stored it at .../{attachmentId}/{fileName}. Accept
  // the bare id and the id-plus-segment form, but nothing outside this client's
  // attachment namespace.
  const expectedPathBase = `users/${grant.uid}/hermes_gateway_attachments/${grant.client.id}/${attachmentId}`;
  if (manifest.storagePath !== expectedPathBase && !manifest.storagePath.startsWith(`${expectedPathBase}/`)) {
    throw httpError(403, "attachment_storage_path_mismatch");
  }
  if (manifest.status === "uploaded") {
    if (expectedSha256 && manifest.sha256 && manifest.sha256 !== expectedSha256) {
      throw httpError(409, "attachment_hash_mismatch");
    }
    sendJSON(res, 200, { attachment: manifest });
    return;
  }
  if (manifest.status !== "pending_upload") {
    throw httpError(statusCodeForAttachmentManifest(manifest.status), "attachment_not_uploadable", manifest.status);
  }
  const expiresAtMs = Date.parse(manifest.expiresAt);
  if (!Number.isFinite(expiresAtMs) || expiresAtMs <= Date.now()) {
    await ref.set({ status: "expired", updatedAt: nowISO() }, { merge: true });
    throw httpError(410, "attachment_upload_expired");
  }
  if (manifest.byteCount < 1 || manifest.byteCount > HERMES_GATEWAY_MAX_ATTACHMENT_BYTES) {
    await ref.set({ status: "rejected", updatedAt: nowISO() }, { merge: true });
    throw httpError(400, "invalid_attachment_manifest");
  }

  const file = getStorage().bucket().file(manifest.storagePath);
  const [exists] = await file.exists();
  if (!exists) {
    throw httpError(404, "attachment_object_missing");
  }
  const sealed = manifest.relayEnvelope != null || manifest.ratchetEnvelope != null || manifest.signalEnvelope != null;
  const [metadata] = await file.getMetadata();
  const observedByteCount = Number(metadata.size);
  const observedContentType = typeof metadata.contentType === "string" ? metadata.contentType : "";
  if (!Number.isFinite(observedByteCount) || observedByteCount !== manifest.byteCount) {
    await ref.set({ status: "rejected", updatedAt: nowISO() }, { merge: true });
    throw httpError(400, "attachment_size_mismatch");
  }
  // For a sealed upload the bytes are ciphertext: the real media type is sealed
  // inside relayEnvelope/ratchetEnvelope and the stored object is opaque, so the
  // server neither matches nor safety-sniffs the content type (the sha256 below
  // is the integrity gate on the ciphertext). Legacy plaintext uploads validate.
  if (!sealed) {
    await assertLegacyAttachmentContentType(ref, manifest.contentType, observedContentType);
  }

  const sha256 = await sha256ForStorageFile(file);
  if (expectedSha256 && sha256 !== expectedSha256) {
    await ref.set({ status: "rejected", updatedAt: nowISO() }, { merge: true });
    throw httpError(409, "attachment_hash_mismatch");
  }

  const now = nowISO();
  const finalized = stripUndefinedObject({
    ...manifest,
    status: "uploaded",
    updatedAt: now,
    uploadedAt: now,
    finalizedAt: now,
    sha256,
    storageGeneration:
      typeof metadata.generation === "string"
        ? metadata.generation
        : metadata.generation == null
          ? undefined
          : String(metadata.generation),
  });
  await ref.set(finalized, { merge: true });
  sendJSON(res, 200, { attachment: finalized });
}

// Deterministic gate id so a retried arm request from the agent is idempotent
// (same client + actionId always maps to the same approval document).
function gatewayApprovalDocId(clientId: string, actionId: string): string {
  return `hga_${sha256Hex(`${clientId}:${actionId}`).slice(0, 40)}`;
}

/**
 * POST /approvals — the agent arms a human-in-the-loop gate before a risky
 * action. Idempotent: arming the same (clientId, actionId) twice returns the
 * existing gate (and its resolution if already decided). The gate is resolved by
 * a trusted native device via the respondHermesGatewayApproval callable; the
 * agent's write scope can never self-approve.
 */
async function handleArmApproval(req: HttpRequest, res: HttpResponse): Promise<void> {
  if (req.method !== "POST") throw httpError(405, "method_not_allowed");
  const grant = await resolveGatewayGrant(req, "hermes.gateway.write");
  const body = requestBody(req);
  const actionId = requiredHttpIdentifier(body.actionId, "actionId");
  const toolName = boundedTrimmedString(body.toolName, "toolName", 120, false);
  // PRIVACY BOUNDARY: the oversight gate is CONTROL-PLANE only — it carries the
  // actionId + a coarse toolName category and a SERVER-DERIVED label, never the
  // agent's free-text command. The human-readable action detail is delivered
  // end-to-end ENCRYPTED over the message channel (the adapter's send_slash_confirm
  // posts a sealed prompt the phone correlates by actionId), so the server is never
  // able to read it. We deliberately IGNORE any client-supplied `summary`, even if
  // an older adapter sends one — enforced here at the trust boundary so no client
  // can reintroduce server-readable private text on the sealed gateway.
  const summary = toolName ? `Approve ${toolName} action` : "Approve agent action";
  const destinationId = sanitizeHermesGatewayDestinationId(body.destinationId);
  const ttlMillis = sanitizeHermesGatewayApprovalTTL(body.expiresInSeconds);
  const approvalId = gatewayApprovalDocId(grant.client.id, actionId);
  const ref = db.doc(`users/${grant.uid}/hermes_gateway_approvals/${approvalId}`);
  const now = Date.now();
  const nowIso = new Date(now).toISOString();
  const existingSnap = await ref.get();
  const existing = existingSnap.data();
  if (existingSnap.exists && isHermesGatewayApprovalDoc(existing)) {
    // Return the live gate (idempotent re-arm). publicApprovalView derives an
    // expired status for a stale waiting gate so the agent stops blocking.
    setNoStore(res);
    sendJSON(res, 200, { approval: publicApprovalView(existing, now) });
    return;
  }
  const doc: HermesGatewayApprovalDoc = {
    id: approvalId,
    clientId: grant.client.id,
    destinationId,
    actionId,
    toolName,
    summary,
    status: "waiting_for_approval",
    requestedAt: nowIso,
    expiresAt: gatewayApprovalExpiryISO(now, ttlMillis),
    schemaVersion: HERMES_GATEWAY_SCHEMA_VERSION,
  };
  await ref.set(stripUndefinedObject(doc), { merge: false });
  logInfo({ event: "hermes_gateway.approval_armed", client_id: grant.client.id, approval_id: approvalId });
  setNoStore(res);
  sendJSON(res, 200, { approval: publicApprovalView(doc, now) });
}

/**
 * GET /approvals — the agent polls its gates for resolution. Returns the calling
 * client's approvals (optionally one, via ?actionId=). Read-only; status is
 * derived so an expired-but-unreaped gate reads as "expired".
 */
async function handleListApprovals(req: HttpRequest, res: HttpResponse): Promise<void> {
  if (req.method !== "GET") throw httpError(405, "method_not_allowed");
  const grant = await resolveGatewayGrant(req, "hermes.gateway.read");
  const now = Date.now();
  const actionId = typeof req.query.actionId === "string" ? req.query.actionId.trim() : "";
  if (actionId) {
    const ref = db.doc(
      `users/${grant.uid}/hermes_gateway_approvals/${gatewayApprovalDocId(grant.client.id, actionId)}`,
    );
    const snap = await ref.get();
    const doc = snap.data();
    setNoStore(res);
    if (!snap.exists || !isHermesGatewayApprovalDoc(doc) || doc.clientId !== grant.client.id) {
      sendJSON(res, 404, { error: "not_found" });
      return;
    }
    sendJSON(res, 200, { approval: publicApprovalView(doc, now) });
    return;
  }
  const snap = await db
    .collection(`users/${grant.uid}/hermes_gateway_approvals`)
    .where("clientId", "==", grant.client.id)
    .get();
  const approvals = snap.docs
    .flatMap((doc): HermesGatewayApprovalDoc[] => {
      const approval = doc.data();
      return isHermesGatewayApprovalDoc(approval) ? [approval] : [];
    })
    .sort((left, right) => right.requestedAt.localeCompare(left.requestedAt))
    .slice(0, 50)
    .map((approval) => publicApprovalView(approval, now));
  setNoStore(res);
  sendJSON(res, 200, { approvals });
}

/**
 * Inner request dispatcher for the Hermes Gateway HTTP API. Pure
 * `(req, res) => Promise<void>` with no onRequest/CORS plumbing, so it is the
 * exact path production runs AND the seam tests drive directly (the wrapped
 * `burnBarHermesGateway` only adds CORS/trace middleware around this).
 */
export async function dispatchHermesGatewayRequest(req: HttpRequest, res: HttpResponse): Promise<void> {
  if (req.method === "OPTIONS") {
    res.status(204).send("");
    return;
  }
  try {
    const path = gatewayPath(req);
    if (path === "/device/start") return await handleDeviceStart(req, res);
    if (path === "/device/poll") return await handleDevicePoll(req, res);
    if (path === "/destinations") return await handleDestinations(req, res);
    if (path === "/events") return await handleEvents(req, res);
    if (path === "/messages") return await handleMessageSend(req, res);
    if (path === "/typing") return await handleTyping(req, res);
    if (path === "/runtime") return await handleRuntimeStatus(req, res);
    if (path === "/state") return await handleGatewayState(req, res);
    if (path === "/approvals") {
      return req.method === "GET" ? await handleListApprovals(req, res) : await handleArmApproval(req, res);
    }
    if (path === "/attachments/init") return await handleAttachmentInit(req, res);
    if (path === "/attachments/finalize") return await handleAttachmentFinalize(req, res);
    sendJSON(res, 404, { error: "not_found" });
  } catch (err) {
    if (isGatewayHttpError(err)) {
      sendJSON(res, err.status, stripUndefinedObject({ error: err.error, detail: err.detail }));
      return;
    }
    if (err instanceof HttpsError) {
      const status = err.code === "invalid-argument" ? 400 : err.code === "permission-denied" ? 403 : 500;
      sendJSON(res, status, { error: err.code, detail: err.message });
      return;
    }
    logError({ event: "hermes_gateway.http_failed", error: String(err) });
    sendJSON(res, 500, { error: "internal" });
  }
}

export const burnBarHermesGateway = onRequest(
  {
    region: FUNCTIONS_REGION,
    cors: true,
    maxInstances: 100,
    ...HOT_PATH_OPTIONS,
  },
  async (req, res): Promise<void> => {
    await dispatchHermesGatewayRequest(req as unknown as HttpRequest, res as unknown as HttpResponse);
  },
);

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

      // The approving PHONE publishes its own relay public key so the agent can
      // wrap reply/attachment bodies to it. Required once sealing is mandatory
      // (relay-capable pairing / past the grace cutoff); optional only for a
      // legacy in-grace pairing.
      const phoneRelay = parseRelayPublicKey(
        request.data as Record<string, unknown>,
        {
          publicKeyField: "phoneRelayPublicKey",
          keyVersionField: "phoneRelayKeyVersion",
          encryptionField: "phoneRelayEncryption",
        },
        (message) => {
          throw new HttpsError("invalid-argument", message);
        },
      );
      const phoneCapabilities = phoneRelay
        ? sanitizeGatewayRelayEnvelopeCapabilities(request.data as Record<string, unknown>)
        : undefined;
      const phoneRatchet = parseRatchetPrekeyBundle(request.data as Record<string, unknown>, "phone", (message) => {
        throw new HttpsError("invalid-argument", message);
      });

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
      const sessionRef = sessions.docs[0].ref;
      const session = recordOrUndefined(sessions.docs[0].data());
      if (!session) throw new HttpsError("failed-precondition", "Hermes Gateway pairing session is invalid.");
      const expiresAt = session.expiresAt instanceof Timestamp ? session.expiresAt.toMillis() : 0;
      if (expiresAt <= Date.now()) {
        await sessionRef.set({ status: "expired", updatedAt: Timestamp.now() }, { merge: true });
        throw new HttpsError("deadline-exceeded", "Hermes Gateway pairing code has expired.");
      }

      // The agent published its relay public key at device/start; carry it onto
      // the new client doc so the phone can wrap event bodies to it. The pair is
      // relay-capable only when BOTH keys are present.
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
      const relayCapable = !!agentRelayPublicKey && !!phoneRelay;
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
      const negotiatedCapabilities =
        agentCapabilities && phoneCapabilities
          ? negotiateGatewayRelayEnvelopeCapabilities(agentCapabilities, phoneCapabilities)
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
      const supportsRatchetV1 = agentRatchet != null && phoneRatchet != null ? true : undefined;
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
      const scopes = sanitizeHermesGatewayScopes(request.data.scopes ?? session.requestedScopes);
      const homeDestinationId = sanitizeHermesGatewayDestinationId(request.data.destinationId);
      const displayName = sanitizedGatewayDisplayName(
        request.data.displayName,
        String(session.clientName ?? "Hermes Agent"),
      );
      const clientDoc: HermesGatewayClientDoc = stripUndefinedObject({
        id: clientId,
        uid,
        displayName,
        status: "active",
        tokenHash,
        tokenPreview: tokenPreview(token),
        scopes,
        homeDestinationId,
        expiresAt: tokenExpiresAt,
        agentRelayPublicKey,
        agentRelayKeyVersion,
        agentRelayEncryption,
        agentSupportsRelayEnvelopeVersions: agentCapabilities?.supportsRelayEnvelopeVersions,
        agentPreferredRelayEnvelopeVersion: agentCapabilities?.preferredRelayEnvelopeVersion,
        agentSupportsHpkeV3: agentCapabilities?.supportsHpkeV3,
        agentSupportsSignalEnvelope: agentCapabilities?.supportsSignalEnvelope,
        agentPlatform: agentCapabilities?.platform,
        agentAppBuild: agentCapabilities?.appBuild,
        phoneRelayPublicKey: phoneRelay?.publicKey,
        phoneRelayKeyVersion: phoneRelay?.keyVersion,
        phoneRelayEncryption: phoneRelay?.encryption,
        phoneSupportsRelayEnvelopeVersions: phoneCapabilities?.supportsRelayEnvelopeVersions,
        phonePreferredRelayEnvelopeVersion: phoneCapabilities?.preferredRelayEnvelopeVersion,
        phoneSupportsHpkeV3: phoneCapabilities?.supportsHpkeV3,
        phoneSupportsSignalEnvelope: phoneCapabilities?.supportsSignalEnvelope,
        phonePlatform: phoneCapabilities?.platform,
        phoneAppBuild: phoneCapabilities?.appBuild,
        supportsRelayEnvelopeVersions: negotiatedCapabilities?.supportsRelayEnvelopeVersions,
        preferredRelayEnvelopeVersion: negotiatedCapabilities?.preferredRelayEnvelopeVersion,
        supportsHpkeV3: negotiatedCapabilities?.supportsHpkeV3,
        supportsSignalEnvelope: negotiatedCapabilities?.supportsSignalEnvelope,
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
        relayCapable: relayCapable ? true : undefined,
        createdAt: now,
        updatedAt: now,
        schemaVersion: HERMES_GATEWAY_SCHEMA_VERSION,
      }) as HermesGatewayClientDoc;

      await ensureDefaultDestination(uid, now);
      await Promise.all([
        db
          .doc(`users/${uid}/hermes_gateway_clients/${clientId}`)
          .set(stripUndefinedObject(clientDoc), { merge: false }),
        db
          .doc(`hermes_gateway_token_index/${tokenHash}`)
          .set({ uid, clientId, status: "active", createdAt: now, expiresAt: tokenExpiresAt }),
        sessionRef.set(
          stripUndefinedObject({
            status: "approved",
            uid,
            clientId,
            accessToken: token,
            scopes,
            homeDestinationId,
            // Echo the phone's relay key onto the session so device/poll returns
            // it to the agent (the agent then wraps its first reply to the phone).
            phoneRelayPublicKey: phoneRelay?.publicKey,
            phoneRelayKeyVersion: phoneRelay?.keyVersion,
            phoneRelayEncryption: phoneRelay?.encryption,
            phoneRatchetIdentityPublicKey: phoneRatchet?.identityPublicKey,
            phoneRatchetSigningPublicKey: phoneRatchet?.signingPublicKey,
            phoneRatchetSignedPreKeyPublicKey: phoneRatchet?.signedPreKeyPublicKey,
            phoneRatchetSignedPreKeyId: phoneRatchet?.signedPreKeyId,
            phoneRatchetSignedPreKeySignature: phoneRatchet?.signedPreKeySignature,
            phoneSupportsRatchetV1: phoneRatchet?.supportsRatchetV1,
            supportsRatchetV1,
            relayCapable: relayCapable ? true : undefined,
            approvedAt: now,
            updatedAt: Timestamp.now(),
          }),
          { merge: true },
        ),
      ]);
      logInfo({ event: "hermes_gateway.device_grant_approved", user_id_hash: uid.slice(0, 8), client_id: clientId });
      // Echo the agent's relay key back so the phone can seal its first event
      // without waiting for a /state round-trip. publicClientView already carries
      // both keys, so the phone reads agentRelayPublicKey straight off `client`.
      return { client: publicClientView(clientDoc), homeDestinationId };
    },
  ),
);

export const listHermesGatewayClients = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 50,
  },
  wrapCallableHandler("listHermesGatewayClients", async (request: CallableRequest<{ includeRevoked?: boolean }>) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before listing Hermes Gateway clients.");
    enforceAuthAndAppCheck(request, uid);
    await assertActiveHermesGatewayEntitlement(uid);
    const snap = await db.collection(`users/${uid}/hermes_gateway_clients`).get();
    const clients = snap.docs
      .flatMap((doc): HermesGatewayClientDoc[] => {
        const client = doc.data();
        return isHermesGatewayClientDoc(client) ? [client] : [];
      })
      .filter((client) => request.data.includeRevoked === true || client.status !== "revoked")
      .sort((left, right) => right.updatedAt.localeCompare(left.updatedAt))
      .map(publicClientView);
    return { clients };
  }),
);

const GATEWAY_REVOKE_BATCH_LIMIT = 400;

async function deleteGatewayQueryDocs(query: Query<DocumentData>): Promise<number> {
  let deleted = 0;
  for (;;) {
    const snap = await query.limit(GATEWAY_REVOKE_BATCH_LIMIT).get();
    if (snap.empty) break;
    const batch = db.batch();
    for (const doc of snap.docs) batch.delete(doc.ref);
    await batch.commit();
    deleted += snap.size;
    if (snap.size < GATEWAY_REVOKE_BATCH_LIMIT) break;
  }
  return deleted;
}

async function deleteGatewayAttachmentStorage(uid: string, clientId: string): Promise<number> {
  const bucket = getStorage().bucket();
  const prefix = `users/${uid}/hermes_gateway_attachments/${clientId}/`;
  const [files] = await bucket.getFiles({ prefix });
  if (files.length > 0) await bucket.deleteFiles({ prefix, force: true });
  return files.length;
}

async function deleteHermesGatewayClientContent(
  uid: string,
  clientId: string,
): Promise<{
  firestoreDocs: number;
  storageObjects: number;
}> {
  const [messages, attachments, approvals, typing, targetedEvents, storageObjects] = await Promise.all([
    deleteGatewayQueryDocs(db.collection(`users/${uid}/hermes_gateway_messages`).where("clientId", "==", clientId)),
    deleteGatewayQueryDocs(db.collection(`users/${uid}/hermes_gateway_attachments`).where("clientId", "==", clientId)),
    deleteGatewayQueryDocs(db.collection(`users/${uid}/hermes_gateway_approvals`).where("clientId", "==", clientId)),
    deleteGatewayQueryDocs(db.collection(`users/${uid}/hermes_gateway_typing`).where("clientId", "==", clientId)),
    deleteGatewayQueryDocs(db.collection(`users/${uid}/hermes_gateway_events`).where("targetClientId", "==", clientId)),
    deleteGatewayAttachmentStorage(uid, clientId),
  ]);
  return {
    firestoreDocs: messages + attachments + approvals + typing + targetedEvents,
    storageObjects,
  };
}

export const revokeHermesGatewayClient = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 50,
  },
  wrapCallableHandler("revokeHermesGatewayClient", async (request: CallableRequest<{ clientId?: unknown }>) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before revoking Hermes Gateway clients.");
    enforceAuthAndAppCheck(request, uid);
    await assertActiveHermesGatewayEntitlement(uid);
    const clientId = requiredIdentifier(request.data.clientId, "clientId");
    const ref = db.doc(`users/${uid}/hermes_gateway_clients/${clientId}`);
    const snap = await ref.get();
    const client = snap.data();
    if (!snap.exists || !isHermesGatewayClientDoc(client)) {
      throw new HttpsError("not-found", "Hermes Gateway client not found.");
    }
    const now = nowISO();
    await Promise.all([
      ref.set({ status: "revoked", revokedAt: now, updatedAt: now }, { merge: true }),
      db.doc(`hermes_gateway_token_index/${client.tokenHash}`).delete(),
    ]);
    const deleted = await deleteHermesGatewayClientContent(uid, clientId);
    return { success: true, clientId, deleted };
  }),
);

export const rotateHermesGatewayClientToken = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 50,
  },
  wrapCallableHandler("rotateHermesGatewayClientToken", async (request: CallableRequest<{ clientId?: unknown }>) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before rotating Hermes Gateway tokens.");
    enforceAuthAndAppCheck(request, uid);
    await assertCallableApprovalNotLocked(uid, "hermes_gateway_approve_fail");
    await assertActiveHermesGatewayEntitlement(uid);
    const clientId = requiredIdentifier(request.data.clientId, "clientId");
    const ref = db.doc(`users/${uid}/hermes_gateway_clients/${clientId}`);
    const snap = await ref.get();
    const client = snap.data();
    if (!snap.exists || !isHermesGatewayClientDoc(client)) {
      await recordCallableApprovalFailure(uid, "hermes_gateway_approve_fail");
      throw new HttpsError("not-found", "Hermes Gateway client not found.");
    }
    if (client.status !== "active") {
      throw new HttpsError("failed-precondition", "Revoked Hermes Gateway clients cannot be rotated.");
    }
    const previousTokenHash = client.tokenHash;
    const token = generateHermesGatewayBearerToken();
    const tokenHash = hashHermesGatewayBearerToken(token);
    if (tokenHash === previousTokenHash) {
      throw new HttpsError("aborted", "Token rotation collision; please retry.");
    }
    const now = nowISO();
    const tokenExpiresAt = gatewayTokenExpiryISO();
    // Atomic-enough swap: write the NEW index first (so a crash mid-rotation
    // leaves the new token usable rather than locking the client out), then
    // repoint the client doc, then delete the OLD index hash. The old token is
    // invalidated the moment the client doc's tokenHash changes because
    // resolveGatewayGrant re-derives and compares against the client doc.
    const batch = db.batch();
    batch.set(db.doc(`hermes_gateway_token_index/${tokenHash}`), {
      uid,
      clientId,
      status: "active",
      createdAt: now,
      expiresAt: tokenExpiresAt,
    });
    batch.set(
      ref,
      {
        tokenHash,
        tokenPreview: tokenPreview(token),
        expiresAt: tokenExpiresAt,
        rotatedAt: now,
        updatedAt: now,
      },
      { merge: true },
    );
    if (previousTokenHash && previousTokenHash !== tokenHash) {
      batch.delete(db.doc(`hermes_gateway_token_index/${previousTokenHash}`));
    }
    await batch.commit();
    logInfo({
      event: "hermes_gateway.token_rotated",
      user_id_hash: uid.slice(0, 8),
      client_id: clientId,
    });
    const rotated: HermesGatewayClientDoc = {
      ...client,
      tokenHash,
      tokenPreview: tokenPreview(token),
      expiresAt: tokenExpiresAt,
      rotatedAt: now,
      updatedAt: now,
    };
    return { client: publicClientView(rotated), accessToken: token, tokenType: "Bearer", expiresAt: tokenExpiresAt };
  }),
);

export const enqueueHermesGatewayEvent = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  wrapCallableHandler(
    "enqueueHermesGatewayEvent",
    async (
      request: CallableRequest<{
        destinationId?: unknown;
        threadId?: unknown;
        senderId?: unknown;
        senderDisplayName?: unknown;
        text?: unknown;
        relayEnvelope?: unknown;
        ratchetEnvelope?: unknown;
        signalEnvelope?: unknown;
        eventId?: unknown;
        eventKind?: unknown;
        modelId?: unknown;
        targetClientId?: unknown;
        attachmentIds?: unknown;
      }>,
    ) => {
      const uid = request.auth?.uid;
      if (!uid) throw new HttpsError("unauthenticated", "Sign in before sending Hermes Gateway events.");
      enforceAuthAndAppCheck(request, uid);
      await assertActiveHermesGatewayEntitlement(uid);
      const eventKind = request.data.eventKind === "model_switch" ? "model_switch" : "message";
      const requestedModelId = sanitizeHermesGatewayModelId(request.data.modelId);
      const targetClientId = request.data.targetClientId
        ? requiredIdentifier(request.data.targetClientId, "targetClientId")
        : undefined;
      let targetClient: HermesGatewayClientDoc | undefined;
      if (targetClientId) {
        targetClient = await assertActiveHermesGatewayClient(uid, targetClientId);
      }
      if (!targetClient) {
        throw new HttpsError("invalid-argument", "targetClientId is required for sealed Hermes Gateway events.");
      }
      const targetIsRelayCapable = targetClient.relayCapable === true;
      // A non-relay-capable (legacy pre-E2E) target is only tolerable while the
      // plaintext grace window is open. New deployments have it closed, so an
      // unsealed target is rejected and the client must re-pair to seal.
      if (!targetIsRelayCapable && !gatewayPlaintextWriteAllowed(targetClient.relayCapable)) {
        throw new HttpsError(
          "failed-precondition",
          "unsealed_target_unsupported: update and re-pair the Hermes Gateway client so messages stay end-to-end encrypted.",
        );
      }
      if (eventKind === "model_switch" && !targetIsRelayCapable && !requestedModelId) {
        throw new HttpsError("invalid-argument", "modelId is required for legacy Hermes Gateway model switches.");
      }
      // The phone seals the event body before this call; the server forwards the
      // opaque envelope and never reads it. A model_switch on a relay-capable
      // target ALSO travels sealed: the model command ("/model …") is private, so
      // the server REQUIRES the relayEnvelope and forwards it blindly. The agent
      // opens it and validates the requested model against its own catalog AFTER
      // decrypting — the server keeps no plaintext clientAdvertisesModel gate that
      // would force it to read the (sealed) command or leak the catalog decision.
      let sealedBody: ResolvedGatewayWriteBody = {};
      if (eventKind === "model_switch") {
        if (targetIsRelayCapable) {
          // Sealed model_switch: require the envelope (the command body is sealed
          // to the agent's relay/ratchet key). Do not require or persist a
          // cleartext modelId for relay-capable clients; the agent opens the
          // command and validates it against its own catalog after decrypting.
          sealedBody = resolveGatewayWriteBody(
            request.data.relayEnvelope,
            request.data.ratchetEnvelope,
            request.data.signalEnvelope,
            undefined,
            targetClient,
            "events",
          );
          if (!sealedBody.relayEnvelope && !sealedBody.ratchetEnvelope && !sealedBody.signalEnvelope) {
            throw new HttpsError(
              "invalid-argument",
              "ciphertext_required: provide a relayEnvelope, ratchetEnvelope, or signalEnvelope for sealed model_switch events.",
            );
          }
        }
        // Legacy (grace-window) model_switch: no sealed body. We keep the old
        // plaintext-catalog guard ONLY for these legacy clients so a typo'd model
        // surfaces an error pre-E2E; relay-capable clients defer to the agent.
        else if (requestedModelId) {
          const hasCatalog = (targetClient.runtimeModelOptions?.length ?? 0) > 0;
          if (hasCatalog && !clientAdvertisesModel(targetClient, requestedModelId)) {
            throw new HttpsError(
              "invalid-argument",
              `model_not_available: ${requestedModelId} is not in the selected client's advertised models.`,
            );
          }
        }
      } else {
        const relayClient = targetClient ?? { id: targetClientId ?? "broadcast", relayCapable: undefined };
        sealedBody = resolveGatewayWriteBody(
          request.data.relayEnvelope,
          request.data.ratchetEnvelope,
          request.data.signalEnvelope,
          request.data.text,
          relayClient,
          "events",
        );
        if (
          !sealedBody.relayEnvelope &&
          !sealedBody.ratchetEnvelope &&
          !sealedBody.signalEnvelope &&
          !sealedBody.legacyText
        ) {
          throw new HttpsError(
            "invalid-argument",
            "text is required: provide a relayEnvelope, ratchetEnvelope, or signalEnvelope (sealed event body).",
          );
        }
      }
      const destinationId = sanitizeHermesGatewayDestinationId(request.data.destinationId);
      const attachmentIds = sanitizedAttachmentIds(request.data.attachmentIds);
      await requireUploadedGatewayAttachments({ uid, clientId: targetClientId, destinationId, attachmentIds });
      const eventId =
        sealedBody.relayEnvelope != null || sealedBody.ratchetEnvelope != null || sealedBody.signalEnvelope != null
          ? requireSafeGatewayEventId(request.data.eventId)
          : `evt_${randomBytes(12).toString("hex")}`;
      const now = nowISO();
      const eventRef = db.doc(`users/${uid}/hermes_gateway_events/${eventId}`);
      let sequence = 0;
      await db.runTransaction(async (tx) => {
        const stateRef = db.doc(`users/${uid}/hermes_gateway_state/cursors`);
        const stateSnap = await tx.get(stateRef);
        // (Remediation R9) Mirror the message-path create-if-absent 409 guard: a
        // replayed client-supplied eventId must not clobber a stored event or
        // re-bump the sequence counter. Reads precede writes in a transaction.
        const existingEvent = await tx.get(eventRef);
        if (existingEvent.exists) {
          throw new HttpsError("already-exists", "Hermes Gateway event already enqueued.");
        }
        const current = Number(stateSnap.get("eventSequence") ?? 0);
        sequence = Number.isFinite(current) ? current + 1 : 1;
        tx.set(
          stateRef,
          { eventSequence: sequence, updatedAt: now, schemaVersion: HERMES_GATEWAY_SCHEMA_VERSION },
          { merge: true },
        );
        tx.set(
          eventRef,
          stripUndefinedObject({
            id: eventId,
            sequence,
            kind: eventKind,
            destinationId,
            targetClientId,
            // senderId is a non-PII routing id. The private fields
            // (text/senderDisplayName/threadId/modelId) live ONLY inside the
            // envelope for relay-capable clients. Model switches do not carry a
            // plaintext command body or thread id.
            threadId:
              sealedBody.relayEnvelope ||
              sealedBody.ratchetEnvelope ||
              sealedBody.signalEnvelope ||
              eventKind === "model_switch"
                ? undefined
                : boundedTrimmedString(request.data.threadId, "threadId", 160, false),
            senderId: boundedTrimmedString(request.data.senderId, "senderId", 160, false) ?? "burnbar-user",
            senderDisplayName:
              sealedBody.relayEnvelope ||
              sealedBody.ratchetEnvelope ||
              sealedBody.signalEnvelope ||
              eventKind === "model_switch"
                ? undefined
                : boundedTrimmedString(request.data.senderDisplayName, "senderDisplayName", 80, false),
            text: sealedBody.legacyText,
            relayEnvelope: sealedBody.relayEnvelope,
            ratchetEnvelope: sealedBody.ratchetEnvelope,
            signalEnvelope: sealedBody.signalEnvelope,
            modelId: targetIsRelayCapable ? undefined : requestedModelId,
            attachmentIds,
            createdAt: now,
            schemaVersion: HERMES_GATEWAY_SCHEMA_VERSION,
          }),
        );
        // Optimistically mark the switch in flight so /state reports "switching…"
        // until the runtime republishes the applied model (or the TTL lapses).
        if (eventKind === "model_switch" && requestedModelId && targetClientId && !targetIsRelayCapable) {
          tx.set(
            db.doc(`users/${uid}/hermes_gateway_clients/${targetClientId}`),
            { pendingModelId: requestedModelId, pendingModelRequestedAt: now, updatedAt: now },
            { merge: true },
          );
        }
      });
      return stripUndefinedObject({
        id: eventId,
        sequence,
        targetClientId,
        pendingModelId: eventKind === "model_switch" && !targetIsRelayCapable ? requestedModelId : undefined,
      });
    },
  ),
);

/**
 * Set a paired client's human-in-the-loop oversight mode. "supervised" arms an
 * approval gate before each risky agent action; "autonomous" runs unattended.
 * The runtime reads this via /state and obeys it. Default (unset) is supervised.
 */
export const setHermesGatewayOversightMode = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 50,
  },
  wrapCallableHandler(
    "setHermesGatewayOversightMode",
    async (request: CallableRequest<{ clientId?: unknown; mode?: unknown }>) => {
      const uid = request.auth?.uid;
      if (!uid) throw new HttpsError("unauthenticated", "Sign in before changing Hermes Gateway oversight.");
      enforceAuthAndAppCheck(request, uid);
      await assertActiveHermesGatewayEntitlement(uid);
      const clientId = requiredIdentifier(request.data.clientId, "clientId");
      const mode = sanitizeHermesGatewayOversightMode(request.data.mode);
      if (!mode) throw new HttpsError("invalid-argument", "mode must be 'supervised' or 'autonomous'.");
      await assertActiveHermesGatewayClient(uid, clientId);
      const now = nowISO();
      await db
        .doc(`users/${uid}/hermes_gateway_clients/${clientId}`)
        .set({ oversightMode: mode, updatedAt: now }, { merge: true });
      logInfo({ event: "hermes_gateway.oversight_mode_set", client_id: clientId, mode });
      return { clientId, oversightMode: mode };
    },
  ),
);

/**
 * Resolve a Hermes Gateway oversight gate from a TRUSTED NATIVE device.
 *
 * This reuses the exact hardened approval semantics of the CLI-agent mission
 * primitive — App-Check-bound caller, a trusted native escrow device, single
 * transactional resolution, and a server-stamped `approvedByDeviceId` — but
 * targets the gateway's own `hermes_gateway_approvals` collection (the agent
 * arms gates over a bearer token and can never self-approve). It does NOT touch
 * the E2E-sealed `cli_agent_mission_requests` collection, which is client-created
 * and cannot be armed by a server-side gateway action.
 */
export const respondHermesGatewayApproval = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  wrapCallableHandler(
    "respondHermesGatewayApproval",
    async (request: CallableRequest<{ approvalId?: unknown; approve?: unknown; deviceId?: unknown }>) => {
      const uid = request.auth?.uid;
      if (!uid) throw new HttpsError("unauthenticated", "Sign in before responding to an oversight request.");
      enforceHighRiskComputerUseCallable(request, uid);
      const approvalId = boundedTrimmedString(request.data.approvalId, "approvalId", 160, true);
      const deviceId = boundedTrimmedString(request.data.deviceId, "deviceId", 160, true);
      if (typeof request.data.approve !== "boolean") {
        throw new HttpsError("invalid-argument", "approve must be a boolean.");
      }
      const approve = request.data.approve;

      const approvalRef = db.doc(`users/${uid}/hermes_gateway_approvals/${approvalId}`);
      const deviceRef = db.doc(`users/${uid}/escrow_devices/${deviceId}`);

      const result = await db.runTransaction(async (transaction) => {
        const [approvalSnap, deviceSnap] = await Promise.all([
          transaction.get(approvalRef),
          transaction.get(deviceRef),
        ]);
        const approval = approvalSnap.data();
        if (!approvalSnap.exists || !isHermesGatewayApprovalDoc(approval)) {
          throw new HttpsError("not-found", "Oversight request was not found.");
        }
        if (approval.status !== "waiting_for_approval") {
          throw new HttpsError("failed-precondition", "Oversight request has already been resolved.");
        }
        if (isHermesGatewayApprovalExpired(approval.expiresAt)) {
          throw new HttpsError("failed-precondition", "Oversight request has expired.");
        }
        if (
          !deviceSnap.exists ||
          deviceSnap.get("trustState") !== "trusted" ||
          !NATIVE_ESCROW_PLATFORMS.has(deviceSnap.get("platform"))
        ) {
          throw new HttpsError(
            "permission-denied",
            "Oversight approvals require a trusted native device. Trust this device first.",
          );
        }
        transaction.set(
          approvalRef,
          {
            status: approve ? "approved" : "rejected",
            respondedAt: nowISO(),
            approvedByDeviceId: deviceId,
          },
          { merge: true },
        );
        return { status: approve ? "approved" : ("rejected" as HermesGatewayApprovalDoc["status"]) };
      });

      logInfo({
        event: "hermes_gateway.approval_resolved",
        approval_id: approvalId,
        approved_by_device_id: deviceId,
        status: result.status,
      });
      return { ok: true, approvalId, status: result.status, approvedByDeviceId: deviceId };
    },
  ),
);

/**
 * Reap oversight gates left unanswered past their TTL by flipping them to
 * "expired" so the phone UI and the agent both see a terminal state. Resolution
 * paths already fail-close on expiry (publicApprovalView derives "expired"), so
 * this is a tidy-up sweep, not a correctness dependency.
 */
export const reapHermesGatewayApprovals = onSchedule(
  {
    schedule: "every 5 minutes",
    timeZone: "UTC",
    region: FUNCTIONS_REGION,
    timeoutSeconds: 120,
  },
  async () => {
    const now = Date.now();
    const snap = await db
      .collectionGroup("hermes_gateway_approvals")
      .where("status", "==", "waiting_for_approval")
      .limit(400)
      .get();
    let reaped = 0;
    let batch = db.batch();
    for (const doc of snap.docs) {
      const approval = doc.data();
      if (!isHermesGatewayApprovalDoc(approval) || !isHermesGatewayApprovalExpired(approval.expiresAt, now)) continue;
      batch.set(doc.ref, { status: "expired", respondedAt: new Date(now).toISOString() }, { merge: true });
      reaped += 1;
      if (reaped % 400 === 0) {
        await batch.commit();
        batch = db.batch();
      }
    }
    if (reaped % 400 !== 0) await batch.commit();
    if (reaped > 0) logInfo({ event: "hermes_gateway.approvals_reaped", count: reaped });
  },
);
