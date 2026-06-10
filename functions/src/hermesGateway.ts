/**
 * @fileoverview BurnBar Cloud Hermes Gateway contracts and pure helpers.
 */

import { HttpsError } from "firebase-functions/v2/https";
import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import {
  SIGNAL_AT_REST_ENCRYPTION,
  SIGNAL_ENVELOPE_FORMAT_VERSION,
  SIGNAL_MAX_KEY_WRAP_B64,
  SIGNAL_MAX_MESSAGE_B64,
  SIGNAL_MAX_RECIPIENT_WRAPS,
  SIGNAL_RELAY_KEY_VERSION,
  SIGNAL_TRANSPORT_ENCRYPTION,
  sanitizeSignalEnvelope,
  type SignalAtRestKeyDelivery,
  type SignalAtRestWrap,
  type SignalBinding,
  type SignalCiphertextLayer,
  type SignalEnvelope,
  type SignalEnvelopeMode,
  type SignalEnvelopeScope,
  type SignalMessageType,
  type SignalRecipientKind,
  type SignalTransportKeyDelivery,
} from "@openburnbar/signal-envelope-contracts";
import { isRecord, recordOrUndefined, stripUndefinedObject } from "./guards.js";

export const HERMES_GATEWAY_SCHEMA_VERSION = 2;
export const HERMES_GATEWAY_DEVICE_SESSION_TTL_MS = 10 * 60 * 1000;
export const HERMES_GATEWAY_TOKEN_BYTES = 32;
// Gateway access tokens are only bearer-compatible as an index hint; every HTTP
// request must also prove possession of the client signing key pinned at pairing.
// Tokens without expiresAt/signing-key material are legacy credentials and fail
// closed until the client re-pairs.
export const HERMES_GATEWAY_TOKEN_TTL_MS = 24 * 60 * 60 * 1000;
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
// Presence is DERIVED from lastSeenAt at read time and never persisted — a stored
// online flag would cause continuous write amplification and stale-on-crash
// presence. Authenticated requests bump lastSeenAt, but the bump is COALESCED to
// the interval below so a 1s poller costs one write per ~30s instead of one per
// request.
export const HERMES_GATEWAY_PRESENCE_WINDOW_MS = 90 * 1000;
// Skip the per-request lastSeenAt bump while the stored value is fresher than
// this. Must stay <= PRESENCE_WINDOW_MS / 3 so any client polling faster than
// the coalesce interval keeps a 2x margin inside the presence window and never
// flips offline because of a skipped write.
export const HERMES_GATEWAY_LAST_SEEN_COALESCE_MS = HERMES_GATEWAY_PRESENCE_WINDOW_MS / 3;
// A requested model switch the runtime has not acknowledged within this window
// is treated as settled (the pending marker is ignored), so a dropped/invalid
// switch never pins the client in a permanent "switching…" state.
export const HERMES_GATEWAY_PENDING_MODEL_TTL_MS = 2 * 60 * 1000;
// A supervised oversight gate left unanswered past this window is reaped to
// "expired" so a risky action never blocks the agent forever.
export const HERMES_GATEWAY_APPROVAL_TTL_MS = 5 * 60 * 1000;
export const HERMES_GATEWAY_MIN_APPROVAL_TTL_MS = 5 * 1000;
export const HERMES_GATEWAY_MAX_APPROVAL_TTL_MS = HERMES_GATEWAY_APPROVAL_TTL_MS;
export const HERMES_GATEWAY_MAX_APPROVAL_SUMMARY = 2_000;

// ---------------------------------------------------------------------------
// Gateway relay E2EE envelope (schema 2+). The phone seals event bodies to the
// agent's relay public key and the agent seals reply bodies to the phone's relay
// public key using the byte-exact HermesRelayCrypto contract
// ("p256-hkdf-sha256-aesgcm", keyVersion 1). The server is a blind
// store-and-forward: it validates the envelope SHAPE only and never decrypts.
// ---------------------------------------------------------------------------

// Wire-format constants mirrored verbatim from HermesRelayCrypto. v2 uses the
// authenticated 2-DH wrap; v3 uses RFC 9180 HPKE Auth mode for the content-key
// wrap while keeping payload/attachment AES-GCM unchanged. The server validates
// shape only and never decrypts either version.
export const HERMES_GATEWAY_RELAY_ENCRYPTION = "p256-hkdf-sha256-aesgcm";
export const HERMES_GATEWAY_RELAY_ENCRYPTION_V3 = "hpke-auth-p256-hkdfsha256-aes256gcm";
// X9.63 uncompressed P-256 public key: 65 bytes (0x04 ‖ X(32) ‖ Y(32)), base64.
export const HERMES_GATEWAY_RELAY_PUBLIC_KEY_BYTES = 65;
// payloadCiphertext base64 cap (matches the relay-request precedent in
// firestore.rules). A sealed event/message/manifest payload is small; the cap is
// generous so a full 32 KB event body plus GCM overhead fits comfortably.
export const HERMES_GATEWAY_MAX_RELAY_PAYLOAD_B64 = 900_000;
// wrappedKey base64 cap. The wrapped symmetric key is a fixed ~125 bytes
// (ephPubX963(65) ‖ nonce(12) ‖ ct(32) ‖ tag(16)); 4096 leaves ample headroom.
export const HERMES_GATEWAY_MAX_RELAY_WRAPPED_KEY_B64 = 4_096;
// HPKE v3 `enc` is a 65-byte P-256 public key; this leaves base64 padding room
// while still rejecting unbounded relay-controlled strings.
export const HERMES_GATEWAY_MAX_RELAY_ENC_B64 = 256;
// The DEFAULT relay key version a freshly published key / envelope advertises
// when none is supplied. v2 adds an optional senderPublicKey wire HINT (the
// sealing peer's ephemeral/identity X9.63 key); clients bind the PINNED key, not
// this hint, so the server still treats the envelope as opaque ciphertext.
export const HERMES_GATEWAY_RELAY_PUBLIC_KEY_VERSION = 1;
export const HERMES_GATEWAY_RELAY_KEY_VERSION = 2;
export const HERMES_GATEWAY_PREFERRED_RELAY_ENVELOPE_VERSION = 3;
export const HERMES_GATEWAY_PRODUCTION_RELAY_KEY_VERSIONS = new Set([2, 3]);
// Every relay key version whose wire shape the BLIND relay accepts on both the
// write (requireGatewayRelayEnvelope / parseRelayPublicKey) and the read
// (sanitizeGatewayRelayEnvelope) side. v1 is the original
// "p256-hkdf-sha256-aesgcm" contract; v2 adds sender-authenticated 2-DH; v3 is
// RFC 9180 HPKE Auth. A version outside this set is a forged/future value and is
// rejected at every gate so it can never slip past a permissive range check.
export const HERMES_GATEWAY_SUPPORTED_RELAY_KEY_VERSIONS = new Set([1, 2, 3]);
export const HERMES_GATEWAY_RATCHET_PROTOCOL_VERSION = 1;
export const HERMES_GATEWAY_RATCHET_ALGORITHM = "OpenBurnBar-HermesRatchet-v1-P256-HKDFSHA256-AESGCM";
export const HERMES_GATEWAY_MAX_RATCHET_CIPHERTEXT_B64 = HERMES_GATEWAY_MAX_RELAY_PAYLOAD_B64;
export const HERMES_GATEWAY_MAX_RATCHET_ID = 160;
export const HERMES_GATEWAY_MAX_RATCHET_COUNTER = 1_000_000_000;
export const HERMES_GATEWAY_SIGNAL_ENVELOPE_FORMAT_VERSION = SIGNAL_ENVELOPE_FORMAT_VERSION;
export const HERMES_GATEWAY_SIGNAL_RELAY_KEY_VERSION = SIGNAL_RELAY_KEY_VERSION;
// The official-libsignal transport envelope rides relay key VERSION 4 — the next
// rung above the bespoke HPKE-Auth v3 relay envelope. It is a SEPARATE wire family
// (a `signalEnvelope` doc validated by the @openburnbar/signal-envelope-contracts
// sanitizer), NOT a new shape of the v1/v2/v3 `relayEnvelope` ladder. The name is
// surfaced for clients/tests/runbooks; the byte-exact value is pinned by the
// contract's SIGNAL_RELAY_KEY_VERSION so the two can never drift.
export const HERMES_GATEWAY_RELAY_KEY_VERSION_SIGNAL = SIGNAL_RELAY_KEY_VERSION;
export const HERMES_GATEWAY_SIGNAL_TRANSPORT_ENCRYPTION = SIGNAL_TRANSPORT_ENCRYPTION;
export const HERMES_GATEWAY_SIGNAL_AT_REST_ENCRYPTION = SIGNAL_AT_REST_ENCRYPTION;
// Signal-envelope version ladder, kept parallel to the relay-envelope ladder
// (HERMES_GATEWAY_SUPPORTED_RELAY_KEY_VERSIONS / *_PRODUCTION_*). SUPPORTED is the
// set of signal relayKeyVersions whose wire shape the BLIND relay tolerates on the
// READ side (sanitizeGatewaySignalEnvelope / requireGatewaySignalEnvelope) so a
// stored or staged v4 doc is recognized as sealed and passed through opaque.
// PRODUCTION is the set a NEW write may negotiate/emit — deliberately EMPTY while
// the libsignal cross-language runtime readiness gate is open, so v4 is read-
// tolerant but never producible (flag OFF). Activation flips v4 into PRODUCTION.
// (Remediation R12) It is INTENTIONAL and EXPECTED for SUPPORTED to be non-empty
// ({4}) while PRODUCTION is empty — that is the stable read-tolerant staging state,
// NOT a misconfiguration or drift. Do not "fix" the asymmetry by emptying SUPPORTED.
export const HERMES_GATEWAY_SUPPORTED_SIGNAL_ENVELOPE_VERSIONS = new Set([HERMES_GATEWAY_RELAY_KEY_VERSION_SIGNAL]);
export const HERMES_GATEWAY_PRODUCTION_SIGNAL_ENVELOPE_VERSIONS = new Set<number>();
export const HERMES_GATEWAY_SIGNAL_REQUIRED_ENV = "OPENBURNBAR_GATEWAY_SIGNAL_REQUIRED";
export const HERMES_GATEWAY_MAX_SIGNAL_MESSAGE_B64 = SIGNAL_MAX_MESSAGE_B64;
export const HERMES_GATEWAY_MAX_SIGNAL_KEY_WRAP_B64 = SIGNAL_MAX_KEY_WRAP_B64;
export const HERMES_GATEWAY_MAX_SIGNAL_RECIPIENT_WRAPS = SIGNAL_MAX_RECIPIENT_WRAPS;
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

export function gatewaySignalRequiredMode(env: NodeJS.ProcessEnv = process.env): boolean {
  return env[HERMES_GATEWAY_SIGNAL_REQUIRED_ENV] === "true";
}

export function productionGatewaySignalEnvelopeVersions(): Set<number> {
  return gatewaySignalRequiredMode()
    ? new Set([HERMES_GATEWAY_RELAY_KEY_VERSION_SIGNAL])
    : new Set(HERMES_GATEWAY_PRODUCTION_SIGNAL_ENVELOPE_VERSIONS);
}

export function productionGatewayRelayKeyVersions(): Set<number> {
  return gatewaySignalRequiredMode() ? new Set() : new Set(HERMES_GATEWAY_PRODUCTION_RELAY_KEY_VERSIONS);
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
  // HPKE v3 only: encapsulated key (DHKEM(P-256) X9.63, base64). v1/v2 keep the
  // historical layout where the ephemeral public key is carried inside
  // wrappedKey.
  enc?: string;
  // OPTIONAL wire HINT (relay key v2+): the sealing peer's X9.63 uncompressed
  // P-256 public key (65B, base64). The BLIND relay round-trips it verbatim and
  // never uses it for crypto — clients bind the PINNED relay key, not this hint.
  // Required for a v2 envelope, absent on a v1 envelope (legacy/back-compat).
  senderPublicKey?: string;
}

export interface GatewayRatchetHeaderDoc {
  version: number;
  algorithm: string;
  sessionID: string;
  senderDeviceID: string;
  receiverDeviceID: string;
  ratchetPublicKeyBase64: string;
  previousChainLength: number;
  messageNumber: number;
  epoch: number;
}

export interface GatewayRatchetEnvelopeDoc {
  header: GatewayRatchetHeaderDoc;
  ciphertextBase64: string;
}

export type GatewaySignalEnvelopeMode = SignalEnvelopeMode;
export type GatewaySignalEnvelopeScope = SignalEnvelopeScope;
export type GatewaySignalMessageType = SignalMessageType;
export type GatewaySignalCiphertextLayerDoc = SignalCiphertextLayer;
export type GatewaySignalBindingDoc = SignalBinding;
export type GatewaySignalTransportKeyDeliveryDoc = SignalTransportKeyDelivery;
export type GatewaySignalRecipientKind = SignalRecipientKind;
export type GatewaySignalAtRestWrapDoc = SignalAtRestWrap;
export type GatewaySignalAtRestKeyDeliveryDoc = SignalAtRestKeyDelivery;
export type GatewaySignalEnvelopeDoc = SignalEnvelope;

export interface HermesGatewayClientDoc {
  id: string;
  uid: string;
  displayName: string;
  status: HermesGatewayClientStatus;
  tokenHash: string;
  tokenPreview: string;
  agentClientSigningPublicKeyBase64?: string;
  agentClientSigningKeyId?: string;
  popRequired?: boolean;
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
  agentSupportsRelayEnvelopeVersions?: number[];
  agentPreferredRelayEnvelopeVersion?: number;
  agentSupportsHpkeV3?: boolean;
  // Official-libsignal (relay v4) capability bit. Persisted only so the negotiated
  // intersection round-trips; defaults to false (absent) and stays false for every
  // shipping client until the libsignal runtime readiness gate is complete.
  agentSupportsSignalEnvelope?: boolean;
  agentPlatform?: string;
  agentAppBuild?: string;
  phoneRelayPublicKey?: string;
  phoneRelayKeyVersion?: number;
  phoneRelayEncryption?: string;
  phoneSupportsRelayEnvelopeVersions?: number[];
  phonePreferredRelayEnvelopeVersion?: number;
  phoneSupportsHpkeV3?: boolean;
  phoneSupportsSignalEnvelope?: boolean;
  phonePlatform?: string;
  phoneAppBuild?: string;
  // Ratcheted E2EE pairing material (Phase 6). These public prekey fields let
  // endpoints negotiate a reviewed Double-Ratchet-style v1 session without the
  // blind relay seeing session secrets. The server stores and echoes public
  // material only; private identity, signing, prekey, and session state live in
  // device Keychain/Keystore storage.
  agentRatchetIdentityPublicKey?: string;
  agentRatchetSigningPublicKey?: string;
  agentRatchetSignedPreKeyPublicKey?: string;
  agentRatchetSignedPreKeyId?: string;
  agentRatchetSignedPreKeySignature?: string;
  agentSupportsRatchetV1?: boolean;
  phoneRatchetIdentityPublicKey?: string;
  phoneRatchetSigningPublicKey?: string;
  phoneRatchetSignedPreKeyPublicKey?: string;
  phoneRatchetSignedPreKeyId?: string;
  phoneRatchetSignedPreKeySignature?: string;
  phoneSupportsRatchetV1?: boolean;
  supportsRatchetV1?: boolean;
  // Negotiated intersection of the agent and phone gateway envelope versions.
  // New senders choose preferredRelayEnvelopeVersion when sealing to this client.
  supportsRelayEnvelopeVersions?: number[];
  preferredRelayEnvelopeVersion?: number;
  supportsHpkeV3?: boolean;
  // Negotiated AND of both endpoints' supportsSignalEnvelope — false unless BOTH
  // sides advertise it, which no shipping client does yet (flag OFF).
  supportsSignalEnvelope?: boolean;
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
  // Ratcheted body for Phase 6 v1 sessions. Mutually exclusive with
  // relayEnvelope on new writes; the blind relay validates shape only.
  ratchetEnvelope?: GatewayRatchetEnvelopeDoc;
  // Official libsignal envelope v1, read-tolerant only while runtime readiness is
  // not green. New production writes reject this field until every libsignal
  // cross-language runtime gate is complete.
  signalEnvelope?: GatewaySignalEnvelopeDoc;
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
  // Ratcheted reply body for Phase 6 v1 sessions. Mutually exclusive with
  // relayEnvelope on new writes; the blind relay validates shape only.
  ratchetEnvelope?: GatewayRatchetEnvelopeDoc;
  // Official libsignal envelope v1, read-tolerant only while runtime readiness is
  // not green. New production writes reject this field until activation.
  signalEnvelope?: GatewaySignalEnvelopeDoc;
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
  // Ratcheted manifest body for Phase 6 v1 sessions. The uploaded attachment
  // bytes remain opaque ciphertext; the relay validates this manifest envelope
  // shape only and never decrypts.
  ratchetEnvelope?: GatewayRatchetEnvelopeDoc;
  // Official libsignal envelope v1 for future attachment manifests, read-tolerant
  // only while runtime readiness is not green. Production writes reject it until
  // activation so staged clients cannot assume Signal was used.
  signalEnvelope?: GatewaySignalEnvelopeDoc;
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
 * Fail-closed expiry check. Missing, empty, or unparsable expiresAt values are
 * expired so corrupt or legacy token docs cannot keep a bearer credential alive.
 */
export function isHermesGatewayTokenExpired(expiresAt: unknown, now = Date.now()): boolean {
  if (expiresAt == null || expiresAt === "") return true;
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
 * Whether the per-request lastSeenAt bump may be skipped because the stored
 * value is already fresh (within HERMES_GATEWAY_LAST_SEEN_COALESCE_MS). Fail-open
 * to WRITING: a missing, unparseable, or future timestamp returns false so the
 * next request always repairs lastSeenAt and presence never sticks stale.
 */
export function shouldCoalesceHermesGatewayLastSeen(lastSeenAt: unknown, now = Date.now()): boolean {
  if (typeof lastSeenAt !== "string" || lastSeenAt === "") return false;
  const ms = Date.parse(lastSeenAt);
  if (!Number.isFinite(ms)) return false;
  const age = now - ms;
  return age >= 0 && age < HERMES_GATEWAY_LAST_SEEN_COALESCE_MS;
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

export function sanitizeHermesGatewayApprovalTTL(raw: unknown): number {
  if (raw === undefined || raw === null || raw === "") return HERMES_GATEWAY_APPROVAL_TTL_MS;
  const seconds = typeof raw === "number" ? raw : typeof raw === "string" ? Number(raw.trim()) : NaN;
  if (!Number.isFinite(seconds) || seconds <= 0) return HERMES_GATEWAY_APPROVAL_TTL_MS;
  const millis = Math.floor(seconds * 1000);
  return Math.min(HERMES_GATEWAY_MAX_APPROVAL_TTL_MS, Math.max(HERMES_GATEWAY_MIN_APPROVAL_TTL_MS, millis));
}

export function gatewayApprovalExpiryISO(fromMillis = Date.now(), ttlMillis = HERMES_GATEWAY_APPROVAL_TTL_MS): string {
  const boundedTTL = sanitizeHermesGatewayApprovalTTL(ttlMillis / 1000);
  return new Date(fromMillis + boundedTTL).toISOString();
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

function gatewayBase64Within(raw: unknown, maxLength: number): string | undefined {
  if (typeof raw !== "string") return undefined;
  const value = raw.trim();
  if (!value || value.length > maxLength || !/^[A-Za-z0-9+/=]+$/u.test(value)) return undefined;
  try {
    Buffer.from(value, "base64");
  } catch {
    return undefined;
  }
  return value;
}

function gatewayRatchetID(raw: unknown): string | undefined {
  if (typeof raw !== "string") return undefined;
  const value = raw.trim();
  if (!value || value.length > HERMES_GATEWAY_MAX_RATCHET_ID || /[\r\n/]/u.test(value)) return undefined;
  return value;
}

function gatewayRatchetCounter(raw: unknown): number | undefined {
  const value = typeof raw === "number" ? Math.floor(raw) : Number(raw);
  if (!Number.isSafeInteger(value) || value < 0 || value > HERMES_GATEWAY_MAX_RATCHET_COUNTER) return undefined;
  return value;
}

function sanitizeGatewayRatchetHeader(raw: unknown): GatewayRatchetHeaderDoc | undefined {
  const record = recordOrUndefined(raw);
  if (!record) return undefined;
  const version = gatewayRatchetCounter(record.version);
  const algorithm = typeof record.algorithm === "string" ? record.algorithm.trim() : "";
  const sessionID = gatewayRatchetID(record.sessionID);
  const senderDeviceID = gatewayRatchetID(record.senderDeviceID);
  const receiverDeviceID = gatewayRatchetID(record.receiverDeviceID);
  const ratchetPublicKeyBase64 = isGatewayRelayPublicKeyB64(record.ratchetPublicKeyBase64);
  const previousChainLength = gatewayRatchetCounter(record.previousChainLength);
  const messageNumber = gatewayRatchetCounter(record.messageNumber);
  const epoch = gatewayRatchetCounter(record.epoch);
  if (
    version !== HERMES_GATEWAY_RATCHET_PROTOCOL_VERSION ||
    algorithm !== HERMES_GATEWAY_RATCHET_ALGORITHM ||
    !sessionID ||
    !senderDeviceID ||
    !receiverDeviceID ||
    !ratchetPublicKeyBase64 ||
    previousChainLength === undefined ||
    messageNumber === undefined ||
    epoch === undefined
  ) {
    return undefined;
  }
  return {
    version,
    algorithm,
    sessionID,
    senderDeviceID,
    receiverDeviceID,
    ratchetPublicKeyBase64,
    previousChainLength,
    messageNumber,
    epoch,
  };
}

export function sanitizeGatewayRatchetEnvelope(raw: unknown): GatewayRatchetEnvelopeDoc | undefined {
  const record = recordOrUndefined(raw);
  if (!record) return undefined;
  const header = sanitizeGatewayRatchetHeader(record.header);
  const ciphertextBase64 = gatewayBase64Within(record.ciphertextBase64, HERMES_GATEWAY_MAX_RATCHET_CIPHERTEXT_B64);
  if (!header || !ciphertextBase64) return undefined;
  return { header, ciphertextBase64 };
}

export function requireGatewayRatchetEnvelope(raw: unknown, fieldName: string): GatewayRatchetEnvelopeDoc {
  const envelope = sanitizeGatewayRatchetEnvelope(raw);
  if (!envelope) {
    throw new HttpsError(
      "invalid-argument",
      `${fieldName} must be a Hermes ratchet v${HERMES_GATEWAY_RATCHET_PROTOCOL_VERSION} envelope.`,
    );
  }
  return envelope;
}

export function requireProductionGatewayRatchetEnvelope(
  raw: unknown,
  fieldName: string,
): GatewayRatchetEnvelopeDoc {
  if (gatewaySignalRequiredMode()) {
    throw new HttpsError(
      "failed-precondition",
      `${fieldName} is rejected in Signal-required gateway mode; write a Signal envelope instead.`,
    );
  }
  return requireGatewayRatchetEnvelope(raw, fieldName);
}

/**
 * Non-throwing SHAPE check for an official-libsignal `signalEnvelope` (relay key
 * version 4). Delegates to the in-tree contract's {@link sanitizeSignalEnvelope}
 * (base64 + cap + capability validation, fully OPAQUE — the server never holds a
 * Signal session key and can never decrypt). Mirrors {@link sanitizeGatewayRelay-
 * Envelope}: a doc is read-tolerated ONLY when its relayKeyVersion is in
 * {@link HERMES_GATEWAY_SUPPORTED_SIGNAL_ENVELOPE_VERSIONS}, so a forged/future
 * signal version fails closed to "unreadable" (returns undefined) rather than
 * slipping through on a permissive range check.
 */
export function sanitizeGatewaySignalEnvelope(
  raw: unknown,
  expectedMode?: GatewaySignalEnvelopeMode,
): GatewaySignalEnvelopeDoc | undefined {
  const envelope = sanitizeSignalEnvelope(raw, expectedMode);
  if (!envelope) return undefined;
  // A transport signal envelope pins relayKeyVersion via the contract; an at-rest
  // envelope omits it. Read-tolerate ONLY versions in the SUPPORTED set; an at-rest
  // (undefined) envelope is governed by its own mode/scheme checks in the contract.
  if (
    envelope.relayKeyVersion !== undefined &&
    !HERMES_GATEWAY_SUPPORTED_SIGNAL_ENVELOPE_VERSIONS.has(envelope.relayKeyVersion)
  ) {
    return undefined;
  }
  return envelope;
}

export function requireGatewaySignalEnvelope(
  raw: unknown,
  fieldName: string,
  expectedMode?: GatewaySignalEnvelopeMode,
): GatewaySignalEnvelopeDoc {
  const envelope = sanitizeGatewaySignalEnvelope(raw, expectedMode);
  if (!envelope) {
    throw new HttpsError(
      "invalid-argument",
      `${fieldName} must be a Signal envelope v${HERMES_GATEWAY_SIGNAL_ENVELOPE_FORMAT_VERSION}.`,
    );
  }
  return envelope;
}

/**
 * WRITE-path guard for a `signalEnvelope`. Validates the SHAPE first (so a
 * malformed envelope is rejected as invalid-argument like every other write), then
 * fail-closes: a relayKeyVersion that is read-SUPPORTED but NOT in
 * {@link HERMES_GATEWAY_PRODUCTION_SIGNAL_ENVELOPE_VERSIONS} is rejected for new
 * writes. That set is EMPTY while the libsignal runtime readiness gate is open, so
 * NO client can negotiate or emit a v4 signal envelope (flag OFF). Mirrors
 * {@link requireProductionGatewayRelayEnvelope}; activation is a one-line set edit.
 */
export function requireProductionGatewaySignalEnvelope(raw: unknown, fieldName: string): GatewaySignalEnvelopeDoc {
  const envelope = requireGatewaySignalEnvelope(raw, fieldName, "transport");
  const version = envelope.relayKeyVersion ?? HERMES_GATEWAY_RELAY_KEY_VERSION_SIGNAL;
  const productionVersions = productionGatewaySignalEnvelopeVersions();
  if (!productionVersions.has(version)) {
    throw new HttpsError(
      "failed-precondition",
      `${fieldName} is valid, but Signal envelope writes are disabled until the libsignal runtime readiness gate is complete.`,
    );
  }
  return envelope;
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
  const relayKeyVersion =
    typeof record.relayKeyVersion === "number" ? Math.floor(record.relayKeyVersion) : Number(record.relayKeyVersion);
  // Accept only a version whose wire shape exists (v1, v2, or v3); reject every other
  // value so a forged/future version can never be accepted as sealed.
  if (!HERMES_GATEWAY_SUPPORTED_RELAY_KEY_VERSIONS.has(relayKeyVersion)) {
    throw new HttpsError(
      "invalid-argument",
      `${fieldName}.relayKeyVersion must be one of ${[...HERMES_GATEWAY_SUPPORTED_RELAY_KEY_VERSIONS].join(", ")}.`,
    );
  }
  const relayEncryption = typeof record.relayEncryption === "string" ? record.relayEncryption.trim() : "";
  const expectedRelayEncryption =
    relayKeyVersion === HERMES_GATEWAY_PREFERRED_RELAY_ENVELOPE_VERSION
      ? HERMES_GATEWAY_RELAY_ENCRYPTION_V3
      : HERMES_GATEWAY_RELAY_ENCRYPTION;
  if (relayEncryption !== expectedRelayEncryption) {
    throw new HttpsError(
      "invalid-argument",
      `${fieldName}.relayEncryption must be ${expectedRelayEncryption} for relayKeyVersion ${relayKeyVersion}.`,
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
  const enc = typeof record.enc === "string" ? record.enc.trim() : "";
  if (relayKeyVersion === HERMES_GATEWAY_PREFERRED_RELAY_ENVELOPE_VERSION) {
    if (!enc || enc.length > HERMES_GATEWAY_MAX_RELAY_ENC_B64 || !/^[A-Za-z0-9+/=]+$/u.test(enc)) {
      throw new HttpsError(
        "invalid-argument",
        `${fieldName}.enc must be base64 within the size cap for relayKeyVersion ${relayKeyVersion}.`,
      );
    }
  } else if (record.enc != null) {
    throw new HttpsError("invalid-argument", `${fieldName}.enc is only valid for relayKeyVersion 3.`);
  }
  // senderPublicKey is the v2 wire HINT (a base64 X9.63 P-256 key). REQUIRE it for
  // a v2 envelope and reject a malformed value; tolerate its absence for v1.
  const senderPublicKey = isGatewayRelayPublicKeyB64(record.senderPublicKey);
  if (relayKeyVersion >= 2) {
    if (!senderPublicKey) {
      throw new HttpsError(
        "invalid-argument",
        `${fieldName}.senderPublicKey must be a base64 X9.63 P-256 public key (65 bytes, 0x04-prefixed) for relayKeyVersion ${relayKeyVersion}.`,
      );
    }
  } else if (record.senderPublicKey != null && !senderPublicKey) {
    // A v1 envelope carrying a present-but-malformed hint is still a malformed
    // write; reject it rather than silently dropping a forged value.
    throw new HttpsError(
      "invalid-argument",
      `${fieldName}.senderPublicKey must be a base64 X9.63 P-256 public key (65 bytes, 0x04-prefixed).`,
    );
  }
  const envelope: GatewayRelayEnvelopeDoc = {
    payloadCiphertext,
    wrappedKey,
    relayEncryption,
    relayKeyVersion,
  };
  if (enc) envelope.enc = enc;
  if (senderPublicKey) envelope.senderPublicKey = senderPublicKey;
  return envelope;
}

/**
 * WRITE-path guard. Every NEW gateway write (a sealed message, attachment init,
 * or sealed control event) MUST use an authenticated production envelope: v2
 * 2-DH or v3 HPKE Auth. {@link requireGatewayRelayEnvelope} deliberately stays
 * v1-tolerant for the READ / legacy-sanitizer path so already-stored v1 docs are
 * not bricked; the trust boundary rejects new legacy envelopes.
 */
export function requireProductionGatewayRelayEnvelope(raw: unknown, fieldName: string): GatewayRelayEnvelopeDoc {
  if (gatewaySignalRequiredMode()) {
    throw new HttpsError(
      "failed-precondition",
      `${fieldName} is rejected in Signal-required gateway mode; write a Signal envelope instead.`,
    );
  }
  const envelope = requireGatewayRelayEnvelope(raw, fieldName);
  const productionVersions = productionGatewayRelayKeyVersions();
  if (!productionVersions.has(envelope.relayKeyVersion)) {
    throw new HttpsError(
      "invalid-argument",
      `${fieldName}.relayKeyVersion must be one of ${[...productionVersions].join(", ")} for new gateway writes.`,
    );
  }
  return envelope;
}

export const requireV2GatewayRelayEnvelope = requireProductionGatewayRelayEnvelope;

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
  const relayKeyVersion =
    typeof record.relayKeyVersion === "number" ? Math.floor(record.relayKeyVersion) : Number(record.relayKeyVersion);
  if (!HERMES_GATEWAY_SUPPORTED_RELAY_KEY_VERSIONS.has(relayKeyVersion)) return undefined;
  const relayEncryption = typeof record.relayEncryption === "string" ? record.relayEncryption.trim() : "";
  const expectedRelayEncryption =
    relayKeyVersion === HERMES_GATEWAY_PREFERRED_RELAY_ENVELOPE_VERSION
      ? HERMES_GATEWAY_RELAY_ENCRYPTION_V3
      : HERMES_GATEWAY_RELAY_ENCRYPTION;
  if (relayEncryption !== expectedRelayEncryption) return undefined;
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
  const enc = typeof record.enc === "string" ? record.enc.trim() : "";
  if (relayKeyVersion === HERMES_GATEWAY_PREFERRED_RELAY_ENVELOPE_VERSION) {
    if (!enc || enc.length > HERMES_GATEWAY_MAX_RELAY_ENC_B64 || !/^[A-Za-z0-9+/=]+$/u.test(enc)) return undefined;
  } else if (record.enc != null) {
    return undefined;
  }
  // Mirror requireGatewayRelayEnvelope's senderPublicKey contract exactly so the
  // read path round-trips precisely what the write path accepted (and rejects
  // precisely what it would have rejected). A v2 envelope MUST carry a valid hint;
  // a present-but-malformed hint (any version) fails closed to "unreadable".
  const senderPublicKey = isGatewayRelayPublicKeyB64(record.senderPublicKey);
  if (relayKeyVersion >= 2) {
    if (!senderPublicKey) return undefined;
  } else if (record.senderPublicKey != null && !senderPublicKey) {
    return undefined;
  }
  const envelope: GatewayRelayEnvelopeDoc = {
    payloadCiphertext,
    wrappedKey,
    relayEncryption,
    relayKeyVersion,
  };
  if (enc) envelope.enc = enc;
  if (senderPublicKey) envelope.senderPublicKey = senderPublicKey;
  return envelope;
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

export interface HermesGatewayRelayEnvelopeCapabilities {
  supportsRelayEnvelopeVersions: number[];
  preferredRelayEnvelopeVersion: number;
  supportsHpkeV3: boolean;
  // Whether this endpoint can seal/open the official-libsignal `signalEnvelope`
  // (relay key v4). Defaults FALSE and stays FALSE for every shipping client until
  // the libsignal runtime readiness gate is complete — no negotiated pairing can
  // become Signal-capable while either side is false, and v4 is never folded into
  // the relay-envelope version ladder, so preferredRelayEnvelopeVersion can never
  // become 4. Purely a forward-compat capability bit (flag OFF).
  supportsSignalEnvelope: boolean;
  platform?: string;
  appBuild?: string;
}

function sanitizeGatewayCapabilityText(raw: unknown, max: number): string | undefined {
  if (typeof raw !== "string") return undefined;
  const value = raw.trim();
  return value ? value.slice(0, max) : undefined;
}

export function sanitizeGatewayRelayEnvelopeCapabilities(
  raw: Record<string, unknown> | undefined,
  throwError: (message: string) => never = (message) => {
    throw new HttpsError("invalid-argument", message);
  },
): HermesGatewayRelayEnvelopeCapabilities {
  const versionField = raw?.supportsRelayEnvelopeVersions;
  let supportsRelayEnvelopeVersions: number[];
  if (versionField == null) {
    supportsRelayEnvelopeVersions = [HERMES_GATEWAY_RELAY_KEY_VERSION];
  } else if (Array.isArray(versionField)) {
    const versions: number[] = [];
    for (const item of versionField) {
      const version = typeof item === "number" ? Math.floor(item) : Number(item);
      if (!HERMES_GATEWAY_PRODUCTION_RELAY_KEY_VERSIONS.has(version)) {
        throwError(
          `supportsRelayEnvelopeVersions must contain only ${[...HERMES_GATEWAY_PRODUCTION_RELAY_KEY_VERSIONS].join(", ")}.`,
        );
      }
      if (!versions.includes(version)) versions.push(version);
    }
    if (!versions.length) {
      throwError("supportsRelayEnvelopeVersions must include at least one production relay envelope version.");
    }
    supportsRelayEnvelopeVersions = versions.sort((a, b) => a - b);
  } else {
    throwError("supportsRelayEnvelopeVersions must be an array.");
  }

  const rawSupportsHpkeV3 = raw?.supportsHpkeV3;
  if (rawSupportsHpkeV3 != null && typeof rawSupportsHpkeV3 !== "boolean") {
    throwError("supportsHpkeV3 must be a boolean.");
  }
  const versionListIncludesV3 = supportsRelayEnvelopeVersions.includes(HERMES_GATEWAY_PREFERRED_RELAY_ENVELOPE_VERSION);
  if (rawSupportsHpkeV3 === true && !versionListIncludesV3) {
    throwError("supportsHpkeV3=true requires supportsRelayEnvelopeVersions to include 3.");
  }
  if (rawSupportsHpkeV3 === false && versionListIncludesV3) {
    throwError("supportsHpkeV3=false is inconsistent with supportsRelayEnvelopeVersions including 3.");
  }
  const supportsHpkeV3 = rawSupportsHpkeV3 ?? versionListIncludesV3;

  // supportsSignalEnvelope is the official-libsignal (relay v4) capability bit. It
  // defaults FALSE and stays FALSE: a client may only assert it true once v4 is in
  // HERMES_GATEWAY_PRODUCTION_SIGNAL_ENVELOPE_VERSIONS (empty today), so any true
  // value is rejected fail-closed while the runtime readiness gate is open. This
  // keeps the flag OFF — no shipping client can become Signal-capable yet.
  const rawSupportsSignalEnvelope = raw?.supportsSignalEnvelope;
  if (rawSupportsSignalEnvelope != null && typeof rawSupportsSignalEnvelope !== "boolean") {
    throwError("supportsSignalEnvelope must be a boolean.");
  }
  if (gatewaySignalRequiredMode() && rawSupportsSignalEnvelope !== true) {
    throwError("supportsSignalEnvelope=true is required in Signal-required gateway mode.");
  }
  if (
    rawSupportsSignalEnvelope === true &&
    !gatewaySignalRequiredMode() &&
    productionGatewaySignalEnvelopeVersions().size === 0
  ) {
    throwError("supportsSignalEnvelope is not yet negotiable: Signal envelope writes are disabled.");
  }
  const supportsSignalEnvelope = rawSupportsSignalEnvelope === true;

  const rawPreferred = raw?.preferredRelayEnvelopeVersion;
  const preferredRelayEnvelopeVersion =
    rawPreferred == null
      ? Math.max(...supportsRelayEnvelopeVersions)
      : typeof rawPreferred === "number"
        ? Math.floor(rawPreferred)
        : Number(rawPreferred);
  if (!supportsRelayEnvelopeVersions.includes(preferredRelayEnvelopeVersion)) {
    throwError("preferredRelayEnvelopeVersion must be included in supportsRelayEnvelopeVersions.");
  }
  // Defense in depth: the signal envelope (v4) is a SEPARATE wire family and is
  // never folded into the relay-envelope ladder, so the preferred RELAY version can
  // never be the signal version. Re-assert it so a future ladder edit can never
  // silently let production select v4 (which has no relay-envelope wire shape).
  if (preferredRelayEnvelopeVersion === HERMES_GATEWAY_RELAY_KEY_VERSION_SIGNAL) {
    throwError("preferredRelayEnvelopeVersion must not be the Signal envelope version.");
  }

  const capabilities: HermesGatewayRelayEnvelopeCapabilities = {
    supportsRelayEnvelopeVersions,
    preferredRelayEnvelopeVersion,
    supportsHpkeV3,
    supportsSignalEnvelope,
  };
  const platform = sanitizeGatewayCapabilityText(raw?.clientPlatform ?? raw?.platform, 80);
  const appBuild = sanitizeGatewayCapabilityText(raw?.clientAppBuild ?? raw?.appBuild, 80);
  if (platform) capabilities.platform = platform;
  if (appBuild) capabilities.appBuild = appBuild;
  return capabilities;
}

export function negotiateGatewayRelayEnvelopeCapabilities(
  agent: HermesGatewayRelayEnvelopeCapabilities,
  phone: HermesGatewayRelayEnvelopeCapabilities,
): HermesGatewayRelayEnvelopeCapabilities {
  const shared = agent.supportsRelayEnvelopeVersions
    .filter((version) => phone.supportsRelayEnvelopeVersions.includes(version))
    .sort((a, b) => a - b);
  if (!shared.length) {
    throw new HttpsError(
      "invalid-argument",
      "No shared Hermes Gateway relay envelope version exists for this pairing.",
    );
  }
  // The shared set is an intersection of two PRODUCTION ladders (each already
  // excludes the Signal version), so Math.max can never be v4. The Signal
  // capability negotiates as the AND of both endpoints — false unless BOTH advertise
  // it, which no shipping client does while the runtime readiness gate is open.
  const preferredRelayEnvelopeVersion = Math.max(...shared);
  return {
    supportsRelayEnvelopeVersions: shared,
    preferredRelayEnvelopeVersion,
    supportsHpkeV3: shared.includes(HERMES_GATEWAY_PREFERRED_RELAY_ENVELOPE_VERSION),
    supportsSignalEnvelope: agent.supportsSignalEnvelope && phone.supportsSignalEnvelope,
  };
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
  const optionalBoolean = (value: unknown) => typeof value === "boolean" || value === undefined;
  const optionalNumberArray = (value: unknown) =>
    value === undefined || (Array.isArray(value) && value.every((item) => typeof item === "number"));
  return (
    optionalString(record.agentRelayPublicKey) &&
    optionalNumber(record.agentRelayKeyVersion) &&
    optionalString(record.agentRelayEncryption) &&
    optionalNumberArray(record.agentSupportsRelayEnvelopeVersions) &&
    optionalNumber(record.agentPreferredRelayEnvelopeVersion) &&
    optionalBoolean(record.agentSupportsHpkeV3) &&
    optionalBoolean(record.agentSupportsSignalEnvelope) &&
    optionalString(record.agentPlatform) &&
    optionalString(record.agentAppBuild) &&
    optionalString(record.phoneRelayPublicKey) &&
    optionalNumber(record.phoneRelayKeyVersion) &&
    optionalString(record.phoneRelayEncryption) &&
    optionalNumberArray(record.phoneSupportsRelayEnvelopeVersions) &&
    optionalNumber(record.phonePreferredRelayEnvelopeVersion) &&
    optionalBoolean(record.phoneSupportsHpkeV3) &&
    optionalBoolean(record.phoneSupportsSignalEnvelope) &&
    optionalString(record.phonePlatform) &&
    optionalString(record.phoneAppBuild) &&
    optionalString(record.agentRatchetIdentityPublicKey) &&
    optionalString(record.agentRatchetSigningPublicKey) &&
    optionalString(record.agentRatchetSignedPreKeyPublicKey) &&
    optionalString(record.agentRatchetSignedPreKeyId) &&
    optionalString(record.agentRatchetSignedPreKeySignature) &&
    optionalBoolean(record.agentSupportsRatchetV1) &&
    optionalString(record.phoneRatchetIdentityPublicKey) &&
    optionalString(record.phoneRatchetSigningPublicKey) &&
    optionalString(record.phoneRatchetSignedPreKeyPublicKey) &&
    optionalString(record.phoneRatchetSignedPreKeyId) &&
    optionalString(record.phoneRatchetSignedPreKeySignature) &&
    optionalBoolean(record.phoneSupportsRatchetV1) &&
    optionalBoolean(record.supportsRatchetV1) &&
    optionalNumberArray(record.supportsRelayEnvelopeVersions) &&
    optionalNumber(record.preferredRelayEnvelopeVersion) &&
    optionalBoolean(record.supportsHpkeV3) &&
    optionalBoolean(record.supportsSignalEnvelope) &&
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
	    (typeof record.agentClientSigningPublicKeyBase64 === "string" ||
	      record.agentClientSigningPublicKeyBase64 === undefined) &&
	    (typeof record.agentClientSigningKeyId === "string" || record.agentClientSigningKeyId === undefined) &&
	    (typeof record.popRequired === "boolean" || record.popRequired === undefined) &&
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
    // manifest still carries a plaintext fileName. relayEnvelope/ratchetEnvelope
    // are present on sealed manifests and validated when read.
    (typeof record.fileName === "string" || record.fileName === undefined) &&
    (record.relayEnvelope === undefined || sanitizeGatewayRelayEnvelope(record.relayEnvelope) !== undefined) &&
    (record.ratchetEnvelope === undefined || sanitizeGatewayRatchetEnvelope(record.ratchetEnvelope) !== undefined) &&
    (record.signalEnvelope === undefined ||
      sanitizeGatewaySignalEnvelope(record.signalEnvelope, "transport") !== undefined) &&
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
  const ratchetEnvelope = sanitizeGatewayRatchetEnvelope(record.ratchetEnvelope);
  const signalEnvelope = sanitizeGatewaySignalEnvelope(record.signalEnvelope, "transport");
  // A doc is "sealed" once it carries a valid relayEnvelope/ratchetEnvelope OR
  // advertises schemaVersion >= 2. For ANY sealed doc the private fields (text /
  // senderDisplayName / threadId) MUST be dropped, even if a backfilled, admin-
  // written, or corrupt doc still has them as siblings of the envelope — keeping
  // them would re-expose plaintext the sealed-doc invariant promises is gone.
  // Legacy plaintext is surfaced ONLY for an unsealed schema-1 doc.
  const schemaVersion = typeof record.schemaVersion === "number" ? record.schemaVersion : NaN;
  const isSealedDoc =
    relayEnvelope !== undefined || ratchetEnvelope !== undefined || signalEnvelope !== undefined || schemaVersion >= 2;
  const hasLegacyText = !isSealedDoc && typeof record.text === "string";
  const legacyText = hasLegacyText && typeof record.text === "string" ? record.text : undefined;
  const isModelSwitch = record.kind === "model_switch";
  const hasModelSwitchRoute = isModelSwitch && typeof record.modelId === "string";
  if (
    typeof record.id !== "string" ||
    typeof record.sequence !== "number" ||
    (record.kind !== "message" && record.kind !== "model_switch") ||
    typeof record.destinationId !== "string" ||
    typeof record.senderId !== "string" ||
    (!hasModelSwitchRoute && !relayEnvelope && !ratchetEnvelope && !signalEnvelope && !hasLegacyText) ||
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
    text: legacyText,
    modelId: typeof record.modelId === "string" ? record.modelId : undefined,
    relayEnvelope,
    ratchetEnvelope,
    signalEnvelope,
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
    agentClientSigningKeyId: client.agentClientSigningKeyId,
    popRequired: client.popRequired === true,
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
    relayPublicKey: client.agentRelayPublicKey,
    relayKeyVersion: client.agentRelayKeyVersion,
    relayEncryption: client.agentRelayEncryption,
    agentRelayPublicKey: client.agentRelayPublicKey,
    agentRelayKeyVersion: client.agentRelayKeyVersion,
    agentRelayEncryption: client.agentRelayEncryption,
    agentSupportsRelayEnvelopeVersions: client.agentSupportsRelayEnvelopeVersions,
    agentPreferredRelayEnvelopeVersion: client.agentPreferredRelayEnvelopeVersion,
    agentSupportsHpkeV3: client.agentSupportsHpkeV3,
    agentSupportsSignalEnvelope: client.agentSupportsSignalEnvelope,
    agentPlatform: client.agentPlatform,
    agentAppBuild: client.agentAppBuild,
    phoneRelayPublicKey: client.phoneRelayPublicKey,
    phoneRelayKeyVersion: client.phoneRelayKeyVersion,
    phoneRelayEncryption: client.phoneRelayEncryption,
    phoneSupportsRelayEnvelopeVersions: client.phoneSupportsRelayEnvelopeVersions,
    phonePreferredRelayEnvelopeVersion: client.phonePreferredRelayEnvelopeVersion,
    phoneSupportsHpkeV3: client.phoneSupportsHpkeV3,
    phoneSupportsSignalEnvelope: client.phoneSupportsSignalEnvelope,
    phonePlatform: client.phonePlatform,
    phoneAppBuild: client.phoneAppBuild,
    agentRatchetIdentityPublicKey: client.agentRatchetIdentityPublicKey,
    agentRatchetSigningPublicKey: client.agentRatchetSigningPublicKey,
    agentRatchetSignedPreKeyPublicKey: client.agentRatchetSignedPreKeyPublicKey,
    agentRatchetSignedPreKeyId: client.agentRatchetSignedPreKeyId,
    agentRatchetSignedPreKeySignature: client.agentRatchetSignedPreKeySignature,
    agentSupportsRatchetV1: client.agentSupportsRatchetV1,
    phoneRatchetIdentityPublicKey: client.phoneRatchetIdentityPublicKey,
    phoneRatchetSigningPublicKey: client.phoneRatchetSigningPublicKey,
    phoneRatchetSignedPreKeyPublicKey: client.phoneRatchetSignedPreKeyPublicKey,
    phoneRatchetSignedPreKeyId: client.phoneRatchetSignedPreKeyId,
    phoneRatchetSignedPreKeySignature: client.phoneRatchetSignedPreKeySignature,
    phoneSupportsRatchetV1: client.phoneSupportsRatchetV1,
    supportsRatchetV1: client.supportsRatchetV1,
    supportsRelayEnvelopeVersions: client.supportsRelayEnvelopeVersions,
    preferredRelayEnvelopeVersion: client.preferredRelayEnvelopeVersion,
    supportsHpkeV3: client.supportsHpkeV3,
    supportsSignalEnvelope: client.supportsSignalEnvelope,
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
