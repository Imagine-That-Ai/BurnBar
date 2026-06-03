/**
 * @fileoverview BurnBar Cloud Hermes Gateway contracts and pure helpers.
 */

import { HttpsError } from "firebase-functions/v2/https";
import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import { isRecord, recordOrUndefined, stripUndefinedObject } from "./guards.js";

export const HERMES_GATEWAY_SCHEMA_VERSION = 2;
export const HERMES_GATEWAY_DEVICE_SESSION_TTL_MS = 10 * 60 * 1000;
export const HERMES_GATEWAY_TOKEN_BYTES = 32;
// Bearer tokens expire 90 days after issuance/rotation. Tokens minted before
// this field existed have no expiresAt and are grandfathered as non-expiring
// until their next successful use (which backfills a default expiry) or an
// explicit rotation.
export const HERMES_GATEWAY_TOKEN_TTL_MS = 90 * 24 * 60 * 60 * 1000;
export const HERMES_GATEWAY_MAX_EVENT_TEXT = 32_000;
export const HERMES_GATEWAY_MAX_MESSAGE_TEXT = 64_000;
export const HERMES_GATEWAY_MAX_ATTACHMENT_BYTES = 50 * 1024 * 1024;
export const HERMES_GATEWAY_DEFAULT_DESTINATION_ID = "burnbar:home";
export const HERMES_GATEWAY_DEFAULT_DESTINATION_DOC_ID = "home";

// Wire protocol version of the gateway HTTP surface, surfaced verbatim by the
// /state route. Distinct from HERMES_GATEWAY_SCHEMA_VERSION (which versions the
// Firestore document shapes): clients use this to gate features that depend on
// a newer gateway contract without inspecting individual document fields.
export const HERMES_GATEWAY_PROTOCOL_VERSION = 2;
// A client counts as "online" when it last checked in within this window.
// Presence is DERIVED from lastSeenAt at read time and never persisted — a poll
// bumps lastSeenAt on every authenticated request, so a stored online flag would
// cause continuous write amplification and stale-on-crash presence.
export const HERMES_GATEWAY_PRESENCE_WINDOW_MS = 90 * 1000;
// A requested model switch the runtime has not acknowledged within this window
// is treated as settled (the pending marker is ignored), so a dropped/invalid
// switch never pins the client in a permanent "switching…" state.
export const HERMES_GATEWAY_PENDING_MODEL_TTL_MS = 2 * 60 * 1000;
// A supervised oversight gate left unanswered past this window is reaped to
// "expired" so a risky action never blocks the agent forever.
export const HERMES_GATEWAY_APPROVAL_TTL_MS = 5 * 60 * 1000;
export const HERMES_GATEWAY_MAX_APPROVAL_SUMMARY = 2_000;

// ---------------------------------------------------------------------------
// Gateway relay E2EE envelope (schema 2+). The phone seals event bodies to the
// agent's relay public key and the agent seals reply bodies to the phone's relay
// public key using the byte-exact HermesRelayCrypto contract
// ("p256-hkdf-sha256-aesgcm", keyVersion 1). The server is a blind
// store-and-forward: it validates the envelope SHAPE only and never decrypts.
// ---------------------------------------------------------------------------

// Wire-format constant mirrored verbatim from HermesRelayCrypto.algorithm. Every
// relay envelope and every published relay public key advertises this exact
// string; any other value is rejected at validation time.
export const HERMES_GATEWAY_RELAY_ENCRYPTION = "p256-hkdf-sha256-aesgcm";
// X9.63 uncompressed P-256 public key: 65 bytes (0x04 ‖ X(32) ‖ Y(32)), base64.
export const HERMES_GATEWAY_RELAY_PUBLIC_KEY_BYTES = 65;
// payloadCiphertext base64 cap (matches the relay-request precedent in
// firestore.rules). A sealed event/message/manifest payload is small; the cap is
// generous so a full 32 KB event body plus GCM overhead fits comfortably.
export const HERMES_GATEWAY_MAX_RELAY_PAYLOAD_B64 = 900_000;
// wrappedKey base64 cap. The wrapped symmetric key is a fixed ~125 bytes
// (ephPubX963(65) ‖ nonce(12) ‖ ct(32) ‖ tag(16)); 4096 leaves ample headroom.
export const HERMES_GATEWAY_MAX_RELAY_WRAPPED_KEY_B64 = 4_096;
// The ONLY relay key version whose crypto exists today (keyVersion 1 of the
// "p256-hkdf-sha256-aesgcm" contract). Until a v2 wrapper ships, the server must
// reject every other version on both the write (requireGatewayRelayEnvelope) and
// the read (sanitizeGatewayRelayEnvelope) side so a forged/future version can
// never slip past a permissive range check. Rotation = a future SIGNED protocol.
export const HERMES_GATEWAY_RELAY_KEY_VERSION = 1;
// Historical cutoff for the now-closed schema-1 plaintext migration. New writes
// are sealed-only; reads keep a legacy plaintext fallback so old queued docs can
// still render while backfills/scrubbers drain them.
export const HERMES_GATEWAY_GRACE_WINDOW_CUTOFF = "2026-06-03T00:00:00.000Z";

/**
 * The plaintext grace window is closed. Keep the helper for old callers/tests,
 * but never approve a new server-readable body regardless of wall-clock time.
 */
export function isWithinGatewayGraceWindow(_now = Date.now()): boolean {
  return false;
}

/**
 * New gateway writes are sealed-only. Legacy plaintext remains a read fallback,
 * not a write path.
 */
export function gatewayPlaintextWriteAllowed(_relayCapable: unknown, _now = Date.now()): boolean {
  return false;
}

export const HERMES_GATEWAY_SCOPES = ["hermes.gateway.read", "hermes.gateway.write", "hermes.gateway.manage"] as const;
export const HERMES_GATEWAY_DEFAULT_SCOPES = ["hermes.gateway.read", "hermes.gateway.write"] as const;

export type HermesGatewayScope = (typeof HERMES_GATEWAY_SCOPES)[number];

export type HermesGatewayClientStatus = "active" | "revoked";
export type HermesGatewayDeviceSessionStatus = "pending" | "approved" | "denied" | "expired";
export type HermesGatewayDestinationKind = "home" | "chat" | "thread";
export type HermesGatewayEventKind = "message" | "model_switch";
export type HermesGatewayMessageKind = "agent_message" | "typing";
export type HermesGatewayAttachmentStatus = "pending_upload" | "uploaded" | "failed" | "expired" | "rejected";
// Human-in-the-loop oversight toggle. "supervised" arms an approval gate before
// each risky agent action; "autonomous" lets the agent run unattended. The safe
// default (supervised) applies whenever the field is unset.
export type HermesGatewayOversightMode = "supervised" | "autonomous";
export const HERMES_GATEWAY_DEFAULT_OVERSIGHT_MODE: HermesGatewayOversightMode = "supervised";
export type HermesGatewayApprovalStatus = "waiting_for_approval" | "approved" | "rejected" | "expired";

export interface HermesGatewayModelOptionDoc {
  providerId: string;
  providerName: string;
  modelId: string;
  displayName: string;
}

/**
 * Per-document sealed sub-object carried by E2EE gateway docs (schema 2+).
 * `payloadCiphertext` is the AES-256-GCM `.combined` seal of the direction's
 * private JSON payload; `wrappedKey` is the per-payload symmetric key wrapped to
 * the recipient's relay public key. Mirrors the relay-request precedent
 * (HermesRelayRequestDoc) so the server's opaque store-and-forward treatment is
 * identical. The server validates SHAPE only (requireGatewayRelayEnvelope) and
 * never has the recipient private key, so it can never decrypt.
 */
export interface GatewayRelayEnvelopeDoc {
  payloadCiphertext: string;
  wrappedKey: string;
  relayEncryption: string;
  relayKeyVersion: number;
}

export interface HermesGatewayClientDoc {
  id: string;
  uid: string;
  displayName: string;
  status: HermesGatewayClientStatus;
  tokenHash: string;
  tokenPreview: string;
  scopes: HermesGatewayScope[];
  homeDestinationId: string;
  expiresAt?: string;
  rotatedAt?: string;
  lastSeenAt?: string;
  // Relay E2EE pairing material (schema 2+). The AGENT publishes its relay
  // public key at device/start (and re-publishes via /runtime); the PHONE
  // publishes its own at approveHermesGatewayDeviceGrant. Phone→agent event
  // bodies are wrapped to agentRelayPublicKey; agent→phone reply/attachment
  // bodies are wrapped to phoneRelayPublicKey. X9.63 uncompressed base64 (65B).
  agentRelayPublicKey?: string;
  agentRelayKeyVersion?: number;
  agentRelayEncryption?: string;
  phoneRelayPublicKey?: string;
  phoneRelayKeyVersion?: number;
  phoneRelayEncryption?: string;
  // True once BOTH endpoints have published a relay public key. New gateway
  // writes require this sealed path; legacy schema-1 plaintext is read-only.
  relayCapable?: boolean;
  runtimeModelId?: string;
  runtimeProviderId?: string;
  runtimeModelOptions?: HermesGatewayModelOptionDoc[];
  runtimeUpdatedAt?: string;
  // Free-form version string the runtime self-reports via /runtime (e.g. the
  // Hermes Agent build id). Surfaced in /state for truthful "gateway version".
  agentVersion?: string;
  // Optimistic model-switch marker: set when a switch is enqueued, cleared once
  // the runtime republishes runtimeModelId matching it (or after the TTL).
  pendingModelId?: string;
  pendingModelRequestedAt?: string;
  // Human-in-the-loop oversight toggle. Unset is treated as "supervised".
  oversightMode?: HermesGatewayOversightMode;
  revokedAt?: string;
  createdAt: string;
  updatedAt: string;
  schemaVersion: number;
}

export interface HermesGatewayApprovalDoc {
  id: string;
  clientId: string;
  destinationId: string;
  // Stable per-action identifier chosen by the agent so a retried arm request is
  // idempotent and the runtime can correlate the resolution with its action.
  actionId: string;
  toolName?: string;
  summary: string;
  status: HermesGatewayApprovalStatus;
  requestedAt: string;
  expiresAt: string;
  respondedAt?: string;
  // Bound by the server to the trusted native device that resolved the gate —
  // never written by the client (mirrors cli_agent_mission_requests).
  approvedByDeviceId?: string;
  schemaVersion: number;
}

export interface HermesGatewayDestinationDoc {
  id: string;
  displayName: string;
  kind: HermesGatewayDestinationKind;
  status: "active" | "archived";
  isDefault: boolean;
  createdAt: string;
  updatedAt: string;
  schemaVersion: number;
}

export interface HermesGatewayEventDoc {
  id: string;
  sequence: number;
  kind: HermesGatewayEventKind;
  destinationId: string;
  targetClientId?: string;
  // threadId / senderDisplayName / text are PRIVATE (schema 2+): they live
  // inside relayEnvelope.payloadCiphertext, sealed to the agent's relay key.
  // They remain typed as optional only so the LEGACY plaintext read fallback
  // can still surface a pre-migration schema-1 doc.
  threadId?: string;
  senderId: string;
  senderDisplayName?: string;
  text?: string;
  modelId?: string;
  attachmentIds: string[];
  // Sealed body for schema 2+ events. Absent on legacy schema-1 docs.
  relayEnvelope?: GatewayRelayEnvelopeDoc;
  createdAt: string;
  schemaVersion: number;
}

export interface HermesGatewayMessageDoc {
  id: string;
  clientId: string;
  kind: HermesGatewayMessageKind;
  destinationId: string;
  threadId?: string;
  replyToEventId?: string;
  // text is PRIVATE (schema 2+): sealed inside relayEnvelope to the phone's
  // relay key. Kept optional for the legacy schema-1 plaintext read fallback.
  text?: string;
  // Sealed reply body for schema 2+ messages. Absent on legacy schema-1 docs.
  relayEnvelope?: GatewayRelayEnvelopeDoc;
  attachmentIds: string[];
  createdAt: string;
  schemaVersion: number;
}

export interface HermesGatewayAttachmentManifestDoc {
  id: string;
  clientId: string;
  destinationId?: string;
  // fileName is PRIVATE (schema 2+): sealed inside relayEnvelope (alongside
  // byteCount/contentType). Optional for the legacy schema-1 read fallback.
  fileName?: string;
  contentType: string;
  byteCount: number;
  storagePath: string;
  status: HermesGatewayAttachmentStatus;
  // Sealed manifest body ({fileName,byteCount,contentType}) + the wrapped
  // attachment-body key, for schema 2+ encrypted uploads. The agent seals the
  // bytes with a per-attachment key before the signed-URL upload, so Storage
  // holds ciphertext and the server's sha256 is a ciphertext integrity check.
  relayEnvelope?: GatewayRelayEnvelopeDoc;
  createdAt: string;
  updatedAt?: string;
  expiresAt: string;
  uploadedAt?: string;
  finalizedAt?: string;
  sha256?: string;
  storageGeneration?: string;
  schemaVersion: number;
}

const USER_CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
const TOKEN_PREFIX = "obb_hgw_";

export function randomHermesGatewayUserCode(): string {
  const bytes = randomBytes(8);
  const chars = Array.from(bytes, (byte) => USER_CODE_ALPHABET[byte % USER_CODE_ALPHABET.length]);
  return `${chars.slice(0, 4).join("")}-${chars.slice(4).join("")}`;
}

export function canonicalHermesGatewayUserCode(raw: unknown): string | undefined {
  if (typeof raw !== "string") return undefined;
  const value = raw.replace(/[^A-Za-z0-9]/g, "").toUpperCase();
  return value.length === 8 ? `${value.slice(0, 4)}-${value.slice(4)}` : undefined;
}

export function generateHermesGatewayDeviceCode(): string {
  return `hgw_${randomBytes(24).toString("hex")}`;
}

export function generateHermesGatewayDeviceSecret(): string {
  return randomBytes(32).toString("base64url");
}

export function generateHermesGatewayBearerToken(): string {
  return `${TOKEN_PREFIX}${randomBytes(HERMES_GATEWAY_TOKEN_BYTES).toString("base64url")}`;
}

export function gatewayTokenExpiryISO(fromMillis = Date.now()): string {
  return new Date(fromMillis + HERMES_GATEWAY_TOKEN_TTL_MS).toISOString();
}

/**
 * Fail-closed expiry check. A missing/empty expiresAt is grandfathered as
 * non-expiring (returns false). An UNPARSEABLE expiresAt is treated as expired
 * (returns true) so corrupt data cannot keep a token alive forever.
 */
export function isHermesGatewayTokenExpired(expiresAt: unknown, now = Date.now()): boolean {
  if (expiresAt == null || expiresAt === "") return false;
  if (typeof expiresAt !== "string") return true;
  const ms = Date.parse(expiresAt);
  if (!Number.isFinite(ms)) return true;
  return ms <= now;
}

/**
 * Derive online/offline from a client's lastSeenAt. Fail-closed: a missing or
 * unparseable timestamp reads as OFFLINE so a stopped gateway never shows online.
 * Pure — presence is computed at read time and is never persisted.
 */
export function isHermesGatewayClientOnline(lastSeenAt: unknown, now = Date.now()): boolean {
  if (typeof lastSeenAt !== "string" || lastSeenAt === "") return false;
  const ms = Date.parse(lastSeenAt);
  if (!Number.isFinite(ms)) return false;
  return now - ms <= HERMES_GATEWAY_PRESENCE_WINDOW_MS;
}

/**
 * Strict, case-insensitive membership test against a client's advertised model
 * catalog. Returns false when the model is absent. Callers decide how to treat an
 * empty/unknown catalog (the gateway allows a switch when no catalog is published
 * yet, so custom model ids are not blocked before the runtime reports inventory).
 */
export function clientAdvertisesModel(
  client: Pick<HermesGatewayClientDoc, "runtimeModelOptions">,
  modelId: string,
): boolean {
  const options = client.runtimeModelOptions;
  if (!Array.isArray(options) || options.length === 0) return false;
  const target = modelId.trim().toLowerCase();
  if (!target) return false;
  return options.some(
    (option) => typeof option?.modelId === "string" && option.modelId.trim().toLowerCase() === target,
  );
}

/**
 * Resolve a client's effective oversight mode, defaulting to the safe option
 * (supervised) whenever the field is unset or invalid.
 */
export function effectiveOversightMode(raw: unknown): HermesGatewayOversightMode {
  return raw === "autonomous" ? "autonomous" : HERMES_GATEWAY_DEFAULT_OVERSIGHT_MODE;
}

export function sanitizeHermesGatewayOversightMode(raw: unknown): HermesGatewayOversightMode | undefined {
  if (raw === "autonomous" || raw === "supervised") return raw;
  return undefined;
}

/**
 * Whether a client's pending-model marker should still be shown as "switching".
 * A pending switch older than the TTL, or one the runtime has already applied
 * (runtimeModelId matches, case-insensitively), is considered settled.
 */
export function pendingModelSwitchInFlight(
  client: Pick<HermesGatewayClientDoc, "pendingModelId" | "pendingModelRequestedAt" | "runtimeModelId">,
  now = Date.now(),
): boolean {
  const pending = typeof client.pendingModelId === "string" ? client.pendingModelId.trim() : "";
  if (!pending) return false;
  const applied = typeof client.runtimeModelId === "string" ? client.runtimeModelId.trim() : "";
  if (applied && applied.toLowerCase() === pending.toLowerCase()) return false;
  const requestedAt =
    typeof client.pendingModelRequestedAt === "string" ? Date.parse(client.pendingModelRequestedAt) : NaN;
  if (!Number.isFinite(requestedAt)) return false;
  return now - requestedAt <= HERMES_GATEWAY_PENDING_MODEL_TTL_MS;
}

export function gatewayApprovalExpiryISO(fromMillis = Date.now()): string {
  return new Date(fromMillis + HERMES_GATEWAY_APPROVAL_TTL_MS).toISOString();
}

/**
 * Fail-closed expiry check for an oversight gate. A missing expiresAt reads as
 * expired so a malformed gate cannot block an agent indefinitely.
 */
export function isHermesGatewayApprovalExpired(expiresAt: unknown, now = Date.now()): boolean {
  if (typeof expiresAt !== "string" || expiresAt === "") return true;
  const ms = Date.parse(expiresAt);
  if (!Number.isFinite(ms)) return true;
  return ms <= now;
}

/**
 * An oversight gate is still actionable (a device may approve/deny it) only while
 * it is waiting and unexpired.
 */
export function isHermesGatewayApprovalActionable(
  approval: Pick<HermesGatewayApprovalDoc, "status" | "expiresAt">,
  now = Date.now(),
): boolean {
  return approval.status === "waiting_for_approval" && !isHermesGatewayApprovalExpired(approval.expiresAt, now);
}

export function sanitizeHermesGatewayApprovalSummary(raw: unknown): string {
  if (typeof raw !== "string") return "";
  return raw.replace(/\s+/g, " ").trim().slice(0, HERMES_GATEWAY_MAX_APPROVAL_SUMMARY);
}

export function hashHermesGatewayBearerToken(token: string): string {
  return sha256Hex(token);
}

export function hashHermesGatewayDeviceSecret(secret: string): string {
  return sha256Hex(secret);
}

export function sha256Hex(value: string): string {
  return createHash("sha256").update(value).digest("hex");
}

export function isSha256Hex(value: unknown): value is string {
  return typeof value === "string" && /^[a-f0-9]{64}$/i.test(value.trim());
}

export function safeEqualHex(left: unknown, right: unknown): boolean {
  if (!isSha256Hex(left) || !isSha256Hex(right)) return false;
  const leftBuffer = Buffer.from(left, "hex");
  const rightBuffer = Buffer.from(right, "hex");
  return leftBuffer.length === rightBuffer.length && timingSafeEqual(leftBuffer, rightBuffer);
}

export function tokenPreview(token: string): string {
  return token.length <= 10 ? token : `${token.slice(0, 8)}...${token.slice(-4)}`;
}

/**
 * Validate a published relay public key: a base64 X9.63 uncompressed P-256 key
 * (exactly 65 bytes, first byte 0x04). Returns the canonical (trimmed) base64 on
 * success, or undefined for any malformed/absent value — callers decide whether a
 * missing key is fatal (post-cutoff pairing) or tolerable (legacy pairing).
 */
export function isGatewayRelayPublicKeyB64(raw: unknown): string | undefined {
  if (typeof raw !== "string") return undefined;
  const value = raw.trim();
  if (!value || value.length > 256 || !/^[A-Za-z0-9+/=]+$/u.test(value)) return undefined;
  let decoded: Buffer;
  try {
    decoded = Buffer.from(value, "base64");
  } catch {
    return undefined;
  }
  // Reject base64 that round-trips to a different string (non-canonical padding)
  // or to the wrong key length / point format.
  if (decoded.length !== HERMES_GATEWAY_RELAY_PUBLIC_KEY_BYTES || decoded[0] !== 0x04) return undefined;
  return value;
}

/**
 * Validate a per-document relay envelope (schema 2+). Mirrors requireSealedText:
 * checks the algorithm constant, the key version range, and the base64 shape +
 * size caps of payloadCiphertext / wrappedKey. The server never decrypts; this is
 * a pure SHAPE gate. Throws HttpsError("invalid-argument") on any violation — the
 * gateway HTTP wrapper maps HttpsError to a 400, so both the callable and HTTP
 * surfaces reject malformed envelopes identically.
 */
export function requireGatewayRelayEnvelope(raw: unknown, fieldName: string): GatewayRelayEnvelopeDoc {
  const record = recordOrUndefined(raw);
  if (!record) {
    throw new HttpsError("invalid-argument", `${fieldName} must be a relay envelope.`);
  }
  const relayEncryption = typeof record.relayEncryption === "string" ? record.relayEncryption.trim() : "";
  if (relayEncryption !== HERMES_GATEWAY_RELAY_ENCRYPTION) {
    throw new HttpsError(
      "invalid-argument",
      `${fieldName}.relayEncryption must be ${HERMES_GATEWAY_RELAY_ENCRYPTION}.`,
    );
  }
  const relayKeyVersion =
    typeof record.relayKeyVersion === "number" ? Math.floor(record.relayKeyVersion) : Number(record.relayKeyVersion);
  // Only keyVersion 1 crypto exists; reject every other version (no v2 wrapper
  // shipped yet) so a forged future version can never be accepted as sealed.
  if (relayKeyVersion !== HERMES_GATEWAY_RELAY_KEY_VERSION) {
    throw new HttpsError(
      "invalid-argument",
      `${fieldName}.relayKeyVersion must be ${HERMES_GATEWAY_RELAY_KEY_VERSION}.`,
    );
  }
  const payloadCiphertext = typeof record.payloadCiphertext === "string" ? record.payloadCiphertext.trim() : "";
  if (
    !payloadCiphertext ||
    payloadCiphertext.length > HERMES_GATEWAY_MAX_RELAY_PAYLOAD_B64 ||
    !/^[A-Za-z0-9+/=]+$/u.test(payloadCiphertext)
  ) {
    throw new HttpsError("invalid-argument", `${fieldName}.payloadCiphertext must be base64 within the size cap.`);
  }
  const wrappedKey = typeof record.wrappedKey === "string" ? record.wrappedKey.trim() : "";
  if (
    !wrappedKey ||
    wrappedKey.length > HERMES_GATEWAY_MAX_RELAY_WRAPPED_KEY_B64 ||
    !/^[A-Za-z0-9+/=]+$/u.test(wrappedKey)
  ) {
    throw new HttpsError("invalid-argument", `${fieldName}.wrappedKey must be base64 within the size cap.`);
  }
  return { payloadCiphertext, wrappedKey, relayEncryption, relayKeyVersion };
}

/**
 * Non-throwing shape check used by read-side serializers (serializeHermesGateway-
 * Event) to pass through a stored envelope verbatim without rejecting the whole
 * doc. Applies the SAME validation semantics as requireGatewayRelayEnvelope
 * (algorithm constant, the single supported key version, base64 + size caps) so
 * the read path can never surface a malformed/forged envelope that the write path
 * would have rejected — a corrupt, backfilled, or admin-written doc that fails any
 * check is treated as unreadable (returns undefined) rather than passed through.
 */
export function sanitizeGatewayRelayEnvelope(raw: unknown): GatewayRelayEnvelopeDoc | undefined {
  const record = recordOrUndefined(raw);
  if (!record) return undefined;
  const relayEncryption = typeof record.relayEncryption === "string" ? record.relayEncryption.trim() : "";
  if (relayEncryption !== HERMES_GATEWAY_RELAY_ENCRYPTION) return undefined;
  const relayKeyVersion =
    typeof record.relayKeyVersion === "number" ? Math.floor(record.relayKeyVersion) : Number(record.relayKeyVersion);
  if (relayKeyVersion !== HERMES_GATEWAY_RELAY_KEY_VERSION) return undefined;
  const payloadCiphertext = typeof record.payloadCiphertext === "string" ? record.payloadCiphertext.trim() : "";
  if (
    !payloadCiphertext ||
    payloadCiphertext.length > HERMES_GATEWAY_MAX_RELAY_PAYLOAD_B64 ||
    !/^[A-Za-z0-9+/=]+$/u.test(payloadCiphertext)
  ) {
    return undefined;
  }
  const wrappedKey = typeof record.wrappedKey === "string" ? record.wrappedKey.trim() : "";
  if (
    !wrappedKey ||
    wrappedKey.length > HERMES_GATEWAY_MAX_RELAY_WRAPPED_KEY_B64 ||
    !/^[A-Za-z0-9+/=]+$/u.test(wrappedKey)
  ) {
    return undefined;
  }
  return { payloadCiphertext, wrappedKey, relayEncryption, relayKeyVersion };
}

export function bearerTokenFromAuthorizationHeader(raw: unknown): string | undefined {
  if (typeof raw !== "string") return undefined;
  const match = /^Bearer\s+(.+)$/i.exec(raw.trim());
  return match?.[1]?.trim() || undefined;
}

export function sanitizeHermesGatewayScopes(raw: unknown): HermesGatewayScope[] {
  const requested = Array.isArray(raw) ? raw : [];
  const allowed = new Set<string>(HERMES_GATEWAY_SCOPES);
  const scopes = requested.filter((item): item is HermesGatewayScope => typeof item === "string" && allowed.has(item));
  return scopes.length ? Array.from(new Set(scopes)) : [...HERMES_GATEWAY_DEFAULT_SCOPES];
}

export function hasHermesGatewayScope(scopes: readonly string[], scope: HermesGatewayScope): boolean {
  return scopes.includes(scope);
}

export function sanitizeHermesGatewayDestinationId(raw: unknown): string {
  if (typeof raw !== "string") return HERMES_GATEWAY_DEFAULT_DESTINATION_ID;
  const value = raw.trim();
  if (!value || value.length > 160 || value.includes("/")) return HERMES_GATEWAY_DEFAULT_DESTINATION_ID;
  return value;
}

export function sanitizeHermesGatewayModelId(raw: unknown): string | undefined {
  if (typeof raw !== "string") return undefined;
  const value = raw.trim();
  if (!value || value.length > 180 || /[\r\n]/.test(value)) return undefined;
  return value;
}

export function destinationDocId(destinationId: string): string {
  if (destinationId === HERMES_GATEWAY_DEFAULT_DESTINATION_ID) return HERMES_GATEWAY_DEFAULT_DESTINATION_DOC_ID;
  const safe = destinationId
    .toLowerCase()
    .replace(/[^a-z0-9_-]/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "");
  return safe || HERMES_GATEWAY_DEFAULT_DESTINATION_DOC_ID;
}

export function parseHermesGatewayCursor(raw: unknown): number {
  const value = typeof raw === "string" ? Number(raw) : typeof raw === "number" ? raw : 0;
  return Number.isFinite(value) && value > 0 ? Math.floor(value) : 0;
}

export function clampHermesGatewayLimit(raw: unknown, fallback = 50): number {
  const value = typeof raw === "string" ? Number(raw) : typeof raw === "number" ? raw : fallback;
  if (!Number.isFinite(value)) return fallback;
  return Math.max(1, Math.min(100, Math.floor(value)));
}

/**
 * Tolerate the optional relay-pairing fields (schema 2+) on a client doc: when
 * present each must be the right primitive type; absent is fine (legacy schema-1
 * clients carry none). Factored out so the client-doc guard stays readable.
 */
function hasValidOptionalRelayFields(record: Record<string, unknown>): boolean {
  const optionalString = (value: unknown) => typeof value === "string" || value === undefined;
  const optionalNumber = (value: unknown) => typeof value === "number" || value === undefined;
  return (
    optionalString(record.agentRelayPublicKey) &&
    optionalNumber(record.agentRelayKeyVersion) &&
    optionalString(record.agentRelayEncryption) &&
    optionalString(record.phoneRelayPublicKey) &&
    optionalNumber(record.phoneRelayKeyVersion) &&
    optionalString(record.phoneRelayEncryption) &&
    (typeof record.relayCapable === "boolean" || record.relayCapable === undefined)
  );
}

export function isHermesGatewayClientDoc(raw: unknown): raw is HermesGatewayClientDoc {
  const record = recordOrUndefined(raw);
  if (!record) return false;
  return (
    typeof record.id === "string" &&
    typeof record.uid === "string" &&
    typeof record.displayName === "string" &&
    (record.status === "active" || record.status === "revoked") &&
    isSha256Hex(record.tokenHash) &&
    typeof record.tokenPreview === "string" &&
    Array.isArray(record.scopes) &&
    typeof record.homeDestinationId === "string" &&
    (typeof record.expiresAt === "string" || record.expiresAt === undefined) &&
    (typeof record.rotatedAt === "string" || record.rotatedAt === undefined) &&
    hasValidOptionalRelayFields(record) &&
    typeof record.createdAt === "string" &&
    typeof record.updatedAt === "string" &&
    typeof record.schemaVersion === "number"
  );
}

/**
 * Tolerate the optional/timestamp tail of an attachment manifest (created/uploaded/
 * finalized timestamps, sha256, storageGeneration). Factored out so the manifest
 * guard's body stays under the complexity ceiling.
 */
function hasValidAttachmentManifestTail(record: Record<string, unknown>): boolean {
  return (
    typeof record.createdAt === "string" &&
    (typeof record.updatedAt === "string" || record.updatedAt === undefined) &&
    typeof record.expiresAt === "string" &&
    (typeof record.uploadedAt === "string" || record.uploadedAt === undefined) &&
    (typeof record.finalizedAt === "string" || record.finalizedAt === undefined) &&
    (isSha256Hex(record.sha256) || record.sha256 === undefined) &&
    (typeof record.storageGeneration === "string" || record.storageGeneration === undefined)
  );
}

export function isHermesGatewayAttachmentManifestDoc(raw: unknown): raw is HermesGatewayAttachmentManifestDoc {
  const record = recordOrUndefined(raw);
  if (!record) return false;
  const status = record.status;
  return (
    typeof record.id === "string" &&
    typeof record.clientId === "string" &&
    (typeof record.destinationId === "string" || record.destinationId === undefined) &&
    // fileName is sealed (schema 2+) so it is optional now; a legacy schema-1
    // manifest still carries a plaintext fileName. relayEnvelope is present on
    // sealed manifests and validated by sanitizeGatewayRelayEnvelope when read.
    (typeof record.fileName === "string" || record.fileName === undefined) &&
    (record.relayEnvelope === undefined || sanitizeGatewayRelayEnvelope(record.relayEnvelope) !== undefined) &&
    typeof record.contentType === "string" &&
    typeof record.byteCount === "number" &&
    Number.isFinite(record.byteCount) &&
    typeof record.storagePath === "string" &&
    (status === "pending_upload" ||
      status === "uploaded" ||
      status === "failed" ||
      status === "expired" ||
      status === "rejected") &&
    hasValidAttachmentManifestTail(record) &&
    typeof record.schemaVersion === "number"
  );
}

export function serializeHermesGatewayTypingDoc(params: {
  clientId: string;
  destinationId: string;
  createdAt: string;
  expiresAt: string;
}): Record<string, unknown> {
  return stripUndefinedObject({
    id: params.clientId,
    clientId: params.clientId,
    kind: "typing",
    destinationId: params.destinationId,
    // No top-level threadId: it is private conversation-routing metadata for
    // gateway chats. Typing is ephemeral and destination-scoped, so storing the
    // thread id would create a plaintext side channel.
    createdAt: params.createdAt,
    expiresAt: params.expiresAt,
    schemaVersion: HERMES_GATEWAY_SCHEMA_VERSION,
  });
}

export function serializeHermesGatewayEvent(raw: unknown): HermesGatewayEventDoc | undefined {
  const record = recordOrUndefined(raw);
  if (!record) return undefined;
  const relayEnvelope = sanitizeGatewayRelayEnvelope(record.relayEnvelope);
  // A doc is "sealed" once it carries a valid relayEnvelope OR advertises
  // schemaVersion >= 2. For ANY sealed doc the private fields (text /
  // senderDisplayName / threadId) MUST be dropped, even if a backfilled, admin-
  // written, or corrupt doc still has them as siblings of the envelope — keeping
  // them would re-expose plaintext the sealed-doc invariant promises is gone.
  // Legacy plaintext is surfaced ONLY for an unsealed schema-1 doc.
  const schemaVersion = typeof record.schemaVersion === "number" ? record.schemaVersion : NaN;
  const isSealedDoc = relayEnvelope !== undefined || schemaVersion >= 2;
  const hasLegacyText = !isSealedDoc && typeof record.text === "string";
  const isModelSwitch = record.kind === "model_switch";
  const hasModelSwitchRoute = isModelSwitch && typeof record.modelId === "string";
  if (
    typeof record.id !== "string" ||
    typeof record.sequence !== "number" ||
    (record.kind !== "message" && record.kind !== "model_switch") ||
    typeof record.destinationId !== "string" ||
    typeof record.senderId !== "string" ||
    (!hasModelSwitchRoute && !relayEnvelope && !hasLegacyText) ||
    !Array.isArray(record.attachmentIds) ||
    typeof record.createdAt !== "string" ||
    typeof record.schemaVersion !== "number"
  ) {
    return undefined;
  }
  return {
    id: record.id,
    sequence: record.sequence,
    kind: record.kind,
    destinationId: record.destinationId,
    targetClientId: typeof record.targetClientId === "string" ? record.targetClientId : undefined,
    // threadId/senderDisplayName/text are echoed ONLY for an unsealed legacy
    // schema-1 doc (read fallback). For a sealed doc they are UNCONDITIONALLY
    // omitted — the agent recovers them by opening relayEnvelope with its relay
    // private key — so a stray plaintext sibling can never leak through.
    threadId: !isSealedDoc && typeof record.threadId === "string" ? record.threadId : undefined,
    senderId: record.senderId,
    senderDisplayName:
      !isSealedDoc && typeof record.senderDisplayName === "string" ? record.senderDisplayName : undefined,
    text: hasLegacyText ? (record.text as string) : undefined,
    modelId: typeof record.modelId === "string" ? record.modelId : undefined,
    relayEnvelope,
    attachmentIds: record.attachmentIds.filter((item): item is string => typeof item === "string"),
    createdAt: record.createdAt,
    schemaVersion: record.schemaVersion,
  };
}

export function makeHermesGatewaySSE(events: HermesGatewayEventDoc[], nextCursor: number): string {
  const lines: string[] = [];
  for (const event of events) {
    lines.push(`id: ${event.sequence}`);
    lines.push("event: message");
    lines.push(`data: ${JSON.stringify(event)}`);
    lines.push("");
  }
  lines.push("event: cursor");
  lines.push(`data: ${JSON.stringify({ nextCursor })}`);
  lines.push("");
  return lines.join("\n");
}

export function sanitizedAttachmentIds(raw: unknown): string[] {
  if (!Array.isArray(raw)) return [];
  return raw
    .filter((item): item is string => typeof item === "string")
    .map((item) => item.trim())
    .filter((item) => item.length > 0 && item.length <= 160 && !item.includes("/"))
    .slice(0, 16);
}

export function sanitizedGatewayDisplayName(raw: unknown, fallback: string): string {
  return typeof raw === "string" && raw.trim().length > 0 ? raw.trim().slice(0, 80) : fallback;
}

export function sanitizeHermesGatewayModelOptions(raw: unknown): HermesGatewayModelOptionDoc[] {
  if (!Array.isArray(raw)) return [];
  const seen = new Set<string>();
  const options: HermesGatewayModelOptionDoc[] = [];
  for (const item of raw) {
    const record = recordOrUndefined(item);
    if (!record) continue;
    const modelId = sanitizeHermesGatewayModelId(record.modelId);
    if (!modelId || seen.has(modelId.toLowerCase())) continue;
    const providerId =
      typeof record.providerId === "string" && record.providerId.trim()
        ? record.providerId.trim().slice(0, 80)
        : "hermes";
    const providerName =
      typeof record.providerName === "string" && record.providerName.trim()
        ? record.providerName.trim().slice(0, 120)
        : providerId;
    const displayName =
      typeof record.displayName === "string" && record.displayName.trim()
        ? record.displayName.trim().slice(0, 180)
        : modelId;
    seen.add(modelId.toLowerCase());
    options.push({ providerId, providerName, modelId, displayName });
    if (options.length >= 100) break;
  }
  return options;
}

export function publicClientView(client: HermesGatewayClientDoc): Record<string, unknown> {
  return {
    id: client.id,
    displayName: client.displayName,
    status: client.status,
    tokenPreview: client.tokenPreview,
    scopes: client.scopes,
    homeDestinationId: client.homeDestinationId,
    expiresAt: client.expiresAt,
    rotatedAt: client.rotatedAt,
    lastSeenAt: client.lastSeenAt,
    // Surface BOTH relay public keys so the phone (reading /state or the clients
    // collection) can wrap its first event to the agent, and the agent (polling
    // /state) can wrap its first reply to the phone, without an extra round-trip.
    // These are PUBLIC keys — safe to echo; the private halves never leave the
    // owning device. relayCapable tells readers whether sealing is required.
    agentRelayPublicKey: client.agentRelayPublicKey,
    agentRelayKeyVersion: client.agentRelayKeyVersion,
    agentRelayEncryption: client.agentRelayEncryption,
    phoneRelayPublicKey: client.phoneRelayPublicKey,
    phoneRelayKeyVersion: client.phoneRelayKeyVersion,
    phoneRelayEncryption: client.phoneRelayEncryption,
    relayCapable: client.relayCapable === true,
    runtimeModelId: client.runtimeModelId,
    runtimeProviderId: client.runtimeProviderId,
    runtimeModelOptions: client.runtimeModelOptions,
    runtimeUpdatedAt: client.runtimeUpdatedAt,
    agentVersion: client.agentVersion,
    pendingModelId: client.pendingModelId,
    pendingModelRequestedAt: client.pendingModelRequestedAt,
    oversightMode: effectiveOversightMode(client.oversightMode),
    revokedAt: client.revokedAt,
    createdAt: client.createdAt,
    updatedAt: client.updatedAt,
    schemaVersion: client.schemaVersion,
  };
}

export function isHermesGatewayApprovalDoc(raw: unknown): raw is HermesGatewayApprovalDoc {
  const record = recordOrUndefined(raw);
  if (!record) return false;
  const status = record.status;
  return (
    typeof record.id === "string" &&
    typeof record.clientId === "string" &&
    typeof record.destinationId === "string" &&
    typeof record.actionId === "string" &&
    (typeof record.toolName === "string" || record.toolName === undefined) &&
    typeof record.summary === "string" &&
    (status === "waiting_for_approval" || status === "approved" || status === "rejected" || status === "expired") &&
    typeof record.requestedAt === "string" &&
    typeof record.expiresAt === "string" &&
    (typeof record.respondedAt === "string" || record.respondedAt === undefined) &&
    (typeof record.approvedByDeviceId === "string" || record.approvedByDeviceId === undefined) &&
    typeof record.schemaVersion === "number"
  );
}

export function publicApprovalView(approval: HermesGatewayApprovalDoc, now = Date.now()): Record<string, unknown> {
  const expired = approval.status === "waiting_for_approval" && isHermesGatewayApprovalExpired(approval.expiresAt, now);
  return {
    id: approval.id,
    clientId: approval.clientId,
    destinationId: approval.destinationId,
    actionId: approval.actionId,
    toolName: approval.toolName,
    summary: approval.summary,
    // Surface a derived "expired" status to readers even before the reaper has
    // rewritten the stored status, so a stale gate never reads as still-waiting.
    status: expired ? "expired" : approval.status,
    requestedAt: approval.requestedAt,
    expiresAt: approval.expiresAt,
    respondedAt: approval.respondedAt,
    approvedByDeviceId: approval.approvedByDeviceId,
    schemaVersion: approval.schemaVersion,
  };
}

export function isRecordWithString(value: unknown, key: string): boolean {
  return isRecord(value) && typeof value[key] === "string" && value[key].trim().length > 0;
}
