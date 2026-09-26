/**
 * @fileoverview Shared TypeScript types for OpenBurnBar Cloud Functions v2.
 *
 * Extracted from src/types/legacy.ts (the strangler "leftovers" bucket) and
 * grouped by domain. Re-exported verbatim from src/types/legacy.ts so every
 * existing `import ... from "../types/legacy"` keeps resolving unchanged.
 */

// ---------------------------------------------------------------------------
// Firestore: hermes_connections / hermes_pairings
// ---------------------------------------------------------------------------

export type HermesConnectionMode = "local" | "directURL" | "relayLink";

export type HermesConnectionStatus = "pending" | "online" | "offline" | "unauthorized" | "revoked" | "degraded";

export interface HermesConnectionDoc {
  id: string;
  displayName: string;
  mode: HermesConnectionMode;
  status: HermesConnectionStatus;
  profileName?: string;
  endpointURL?: string;
  advertisedModel?: string;
  relayPublicKey?: string;
  relayKeyVersion?: number;
  relayEncryption?: string;
  capabilities: string[];
  lastSeenAt?: string;
  createdAt: string;
  updatedAt: string;
  schemaVersion: number;
}

export interface HermesPairingDoc {
  id: string;
  status: "pending" | "completed" | "expired" | "revoked";
  codeHash: string;
  failedAttempts?: number;
  requestedByDeviceId?: string;
  requestedByPlatform?: "ios" | "ipados" | "macos" | "web";
  displayName?: string;
  connectionId?: string;
  expiresAt: string;
  expireAt?: import("firebase-admin/firestore").Timestamp;
  createdAt: string;
  updatedAt: string;
  schemaVersion: number;
}

export interface HermesConnectionAuditEventDoc {
  id: string;
  eventType:
    | "pairing_created"
    | "pairing_completed"
    | "pairing_failed"
    | "connection_created"
    | "connection_revoked"
    | "connection_status_updated";
  connectionId?: string;
  pairingId?: string;
  actorDeviceId?: string;
  observedAt: string;
  detail?: Record<string, unknown>;
  schemaVersion: number;
  expireAt?: import("firebase-admin/firestore").Timestamp;
}

// ---------------------------------------------------------------------------
// Firestore: iroh transport pairing records
// ---------------------------------------------------------------------------

/**
 * Iroh transport pairing record. Published by the trusted macOS/Linux host once it
 * has bootstrapped an iroh endpoint and signed the dialable NodeAddr fields
 * with the user's
 * Ed25519 pairing key (`provider_accounts/{uid}.irohPairingPublicKey`).
 *
 * Lives at:
 *   /users/{uid}/iroh_pairing/{connectionId}
 *
 * Read-side (iOS / iPadOS / Android and server route resolution):
 *   1. Look up the user's `irohPairingPublicKey` (32 raw bytes, base64).
 *   2. Verify `signature` over
 *      `openburnbar.iroh.pairing.v1|{uid}|{connectionId}|{nodeId}|{relayURL}|{directAddresses}|{publishedAtMillis}`.
 *   3. Reject records older than `IROH_PAIRING_FRESHNESS_MS` (3 minutes) or with
 *      a `protocolVersion` newer than the client understands.
 *   4. Dial `nodeId` plus the signed relay/direct addresses over the QUIC ALPN advertised by
 *      `IrohRelayProtocol.alpn`.
 *
 * Firestore rules keep owner read access, but live writes are server-owned and
 * must flow through `publishIrohPairingRecord` / `revokeIrohPairingRecord`.
 * Publication verifies ownership and trusted host escrow-device state. Readers
 * verify freshness, key shape, and proof-of-possession before using the route.
 */
export interface IrohPairingRecordDoc {
  /** Stable connection ID (matches the host-side Hermes connection id). */
  id: string;

  /** Canonical lowercase-hex NodeId (64 chars); legacy readers may also accept 52-char base32. */
  nodeId: string;

  /** Home relay URL selected by the host endpoint. Required for reliable mobile dialing. */
  relayURL?: string;

  /** Optional direct socket addresses observed by the host endpoint. */
  directAddresses?: string[];

  /** Milliseconds since epoch when the host signed and published the record. */
  publishedAtMillis: number;

  /** Frame schema version the host is willing to speak. Default 1. */
  protocolVersion?: number;

  /**
   * Base64 Ed25519 signature over the canonical AAD string. The signing key
   * is the user's `irohPairingPublicKey`, persisted in native host secret custody.
   */
  signature: string;

  /** Server-stamped time (Cloud Functions/iOS adopt ISO 8601). */
  createdAt: string;
  updatedAt: string;

  /** Document schema version for forward compatibility. */
  schemaVersion: number;
}

/** Max age (ms) clients trust a signed `IrohPairingRecordDoc`. Matches Swift/Android 3-minute policy. */
export const IROH_PAIRING_FRESHNESS_MS = 3 * 60 * 1000;

/** Canonical AAD prefix the Mac signs. Mirrors `IrohPairingSignature` in
 *  Swift: `openburnbar.iroh.pairing.v\(protocolVersion)` interpolated into
 *  `IrohPairingSignature.canonicalPayload`.
 */
export const IROH_PAIRING_SIGNATURE_PREFIX = "openburnbar.iroh.pairing.v1";

/**
 * Singleton document published by the trusted host through `publishIrohPairingPublicKey`
 * at `users/{uid}/iroh_pairing_keys/host` containing the Ed25519 public half of
 * the pairing key. iOS clients fetch this once per session and verify every
 * `IrohPairingRecordDoc.signature` against it before dialing a NodeId.
 *
 * Why a dedicated collection (not a field on `provider_accounts/*`):
 *   - Provider accounts are per-account, the pairing key is per-user.
 *   - Querying for "any provider_accounts doc with the field set" is racy if
 *     a user has multiple accounts.
 *   - A dedicated path lets `firestore.rules` constrain the schema tightly
 *     (only the 5 fields below are allowed).
 */
export interface IrohPairingPublicKeyDoc {
  /** Role identifier — today always `"host"`; reserved for future client roles. */
  id: string;

  /** Base64 of the 32-byte Ed25519 public key. */
  publicKeyBase64: string;

  /** Milliseconds since epoch when the host wrote/refreshed the doc. */
  publishedAtMillis: number;

  /** Frame schema version the key is bound to. Default 1. */
  protocolVersion: number;

  /** Document schema version for forward compatibility. */
  schemaVersion: number;
}

/** Role id of the singleton iroh_pairing_keys document the Mac publishes. */
export const IROH_PAIRING_KEY_HOST_ROLE = "host";

/**
 * Phone-control authority key. Published by iOS/iPadOS/Android through
 * `publishPhoneControlAuthority` before it opens the Computer Use
 * `control.input` stream; read by the Mac when it receives `control.classify`.
 *
 * Lives at:
 *   /users/{uid}/iroh_pairing/{connectionId}/controllers/{peerNodeId}
 *
 * This keeps the Ed25519 verification root out of the stream it is supposed
 * to authenticate. Firestore rules keep owner read access but reject direct
 * client writes; the callable requires `connectionId` to name the current
 * pairing record and `deviceId` to refer to a trusted escrow device in the
 * same user namespace.
 */
export type ComputerUsePhoneAuthorityDoc =
  import("../generated/computer-use.js").ComputerUsePhoneAuthorityDoc & {
    /** Document id; equals `peerNodeId`. */
    id: string;
  };

/**
 * Relay sender key used by authenticated relay request envelopes. Published by
 * iOS/iPadOS/Android through `publishRelaySenderKey`, then read by the Mac
 * before opening any Mac-bound `HermesRelayOperation`.
 *
 * Lives at:
 *   /users/{uid}/relay_sender_keys/{deviceId}
 *
 * Firestore rules keep owner read access but reject direct client writes. The
 * callable verifies App Check, high-risk nonce, trusted native escrow-device
 * state, P-256 key shape, key-id derivation, fresh publication time, proof of
 * possession, and verified Signal identity readback.
 */
export interface RelaySenderKeyDoc {
  /** Document id; equals `deviceId`. */
  id: string;

  /** Trusted native iOS/iPadOS/Android escrow device that owns the sender key. */
  deviceId: string;

  /** Stable phone-control peer id bound to the sender key. */
  peerNodeId: string;

  /** `relay-v3-` plus the expected SHA-256-derived key digest suffix. */
  keyId: string;

  /** Base64 of the uncompressed X9.63 P-256 public key (65 bytes, 0x04-prefixed). */
  publicKeyBase64: string;

  /** Authenticated relay request version. Must be 3 for live command traffic. */
  relayKeyVersion: 3;

  /** Today always `hpke-auth-p256-hkdfsha256-aes256gcm`. */
  relayEncryption: "hpke-auth-p256-hkdfsha256-aes256gcm";

  /** Matched Signal identity key version from the trusted-device binding. */
  signalIdentityKeyVersion: number;

  /** Matched verified Signal identity fingerprint. */
  signalIdentityFingerprint: string;

  /** Live command traffic requires verified, non-TOFU Signal identity. */
  signalIdentityVerification: "verified";

  /** Active until the device, sender key, or Signal identity is revoked. */
  status: "active" | "revoked";

  /** Milliseconds since epoch when the phone published/refreshed the doc. */
  publishedAtMillis: number;

  /** Server-stamped time. */
  createdAt: string;
  updatedAt: string;

  /** Document schema version for forward compatibility. */
  schemaVersion: number;
}

/**
 * Public verification root for queued agent capability grants. Published by
 * iOS/iPadOS/Android through `publishAgentGrantAuthority`; read by the Mac
 * before applying a live or queued grant.
 *
 * Lives at:
 *   /users/{uid}/agent_grant_authorities/{deviceId}
 */
export interface AgentGrantAuthorityDoc {
  /** Document id; equals `deviceId`. */
  id: string;

  /** Trusted native iOS/iPadOS/Android escrow device that owns the key. */
  deviceId: string;

  /** Stable peer id derived from the Ed25519 public key. */
  peerNodeId: string;

  /** Base64 of the 32-byte Ed25519 public key. */
  publicKeyBase64: string;

  /** Server-owned authority family. */
  authorityKind: "agent_capability_grant";

  /** Active until the device or authority key is revoked. */
  status: "active" | "revoked";

  /** Milliseconds since epoch when the phone published/refreshed the doc. */
  publishedAtMillis: number;

  /** Server-stamped time. */
  createdAt: string;
  updatedAt: string;

  /** Document schema version for forward compatibility. */
  schemaVersion: number;
}

/**
 * Public readback record for a Mac trusted-device audit-export signer.
 *
 * Lives under the escrow device that owns the local Keychain private key:
 *   /users/{uid}/escrow_devices/{deviceId}/computer_use_audit_export_signers/{publicKeySHA256Hex}
 *
 * The detached `.sig.json` sidecar can prove the archive was signed by a
 * private key, but this Firestore record proves whether the corresponding
 * public key was published by a currently trusted macOS escrow device. Device
 * revocation invalidates every child signer by revoking the parent
 * `escrow_devices/{deviceId}` document.
 */
export interface ComputerUseAuditExportSignerPublicKeyDoc {
  /** Document id; equals `publicKeySHA256Hex`. */
  id: string;

  /** Owner namespace; equals the parent user id. */
  userId: string;

  /** Parent escrow device id. Parent must be trusted macOS. */
  deviceId: string;

  /** Stable local signer identifier copied into `.sig.json`. */
  signerIdentifier: string;

  /** OpenBurnBar signer family. */
  signerKind: "openburnbar_trusted_device";

  /** Trust root implemented by the daemon's Keychain-backed signer provider. */
  trustRoot: "openburnbar-trusted-device-keychain-v1";

  /** Signature algorithm for the detached archive signature. */
  algorithm: "ed25519";

  /** Base64 of the 32-byte Ed25519 public key. */
  publicKeyBase64: string;

  /** SHA-256 hex digest of the raw public key. Equals the document id. */
  publicKeySHA256Hex: string;

  /** Active until the parent escrow device is revoked or this doc is revoked. */
  status: "active" | "revoked";

  /** Milliseconds since epoch when the Mac published/refreshed the doc. */
  publishedAtMillis: number;

  /** Optional last time a verifier confirmed this record during readback. */
  lastReadbackAtMillis?: number;

  /** Explicit signer-level revocation timestamp, if any. */
  revokedAt?: import("firebase-admin/firestore").Timestamp;

  /** Device that initiated signer-level revocation, if any. */
  revokedByDeviceId?: string;

  /** Document schema version for forward compatibility. */
  schemaVersion: number;
}

/**
 * Audit event the Mac (or the Cloud Functions hosted runner) writes when an
 * iroh stream is opened, closed, or falls back to a non-iroh relay. Surfaces
 * transport health to the user's audit log without exposing payload bytes.
 */
export interface IrohTransportAuditEventDoc {
  id: string;
  connectionId: string;
  /** Logical reason this event was emitted. */
  eventType:
    | "iroh_stream_opened"
    | "iroh_stream_closed"
    | "iroh_stream_failed"
    | "iroh_pairing_published"
    | "iroh_pairing_verified"
    | "iroh_pairing_rejected"
    | "iroh_fallback_to_wss"
    | "iroh_fallback_to_firestore";
  /** Observed RTT (ms) of the most recent ping on this stream, if known. */
  rttMillis?: number;
  /**
   * Logical transport actually used for the payload. Mirrors the
   * `HermesCompositeRelayTransport` selector.
   */
  transport?: "iroh-direct" | "iroh-relay" | "wss" | "firestore";
  observedAt: string;
  /**
   * Optional structured detail (e.g., `{ "reason": "alpn_mismatch" }`).
   * Strings only; never contains payload bytes.
   */
  detail?: Record<string, string>;
  schemaVersion: number;
  expireAt?: import("firebase-admin/firestore").Timestamp;
}

/** Daily operator rollup of `users/{uid}/iroh_audit_events/*`. */
export interface IrohTransportDailyRollupDoc {
  id: string;
  date: string;
  windowStart: string;
  windowEnd: string;
  generatedAt: string;
  totalEvents: number;
  uniqueUsers: number;
  uniqueConnections: number;
  eventCounts: Record<IrohTransportAuditEventDoc["eventType"], number>;
  transportCounts: Record<NonNullable<IrohTransportAuditEventDoc["transport"]>, number>;
  streamOpens: number;
  streamCloses: number;
  streamFailures: number;
  wssFallbacks: number;
  firestoreFallbacks: number;
  successRate: number;
  fallbackRate: number;
  directShare: number;
  relayShare: number;
  rttMillis: {
    count: number;
    p50?: number;
    p95?: number;
    p99?: number;
  };
  schemaVersion: number;
}

export type HermesRelayOperation =
  | "chatCompletions"
  | "cliAgentChat"
  | "models"
  | "sessions"
  | "sessionDetail"
  | "profiles"
  | "jobs";

export type HermesRelayRequestStatus =
  | "pending"
  | "claimed"
  | "streaming"
  | "completed"
  | "failed"
  | "cancelled"
  | "expired";

export type HermesRelayRequestDoc = Omit<
  import("../generated/hermes-relay.js").HermesRelayRequestDoc,
  "operation" | "status"
> & {
  id: string;
  connectionId: string;
  operation: HermesRelayOperation;
  status: HermesRelayRequestStatus;
  method: "GET" | "POST";
  path?: string;
  sessionId?: string;
  body?: string;
  payloadCiphertext?: string;
  wrappedKey?: string;
  enc?: string;
  senderPublicKey?: string;
  senderDeviceId?: string;
  senderPeerNodeId?: string;
  senderCounter?: number;
  keyId?: string;
  relayEncryption?: string;
  relayKeyVersion?: number;
  error?: string;
  chunkCount: number;
  claimedAt?: string;
  claimedBy?: string;
  completedAt?: string;
  createdAt: string;
  updatedAt?: string;
  expiresAt: string;
  expireAt?: import("firebase-admin/firestore").Timestamp;
  schemaVersion: number;
};

export type HermesRelayChunkDoc = import("../generated/hermes-relay.js").HermesRelayChunkDoc & {
  id: string;
  sequence: number;
  kind: "sse" | "data" | "error";
  data?: string;
  text?: string;
  error?: string;
  ciphertext?: string;
  createdAt: string;
  updatedAt?: string;
  schemaVersion: number;
};

// ---------------------------------------------------------------------------
// Firestore: hermes_gateway_* platform adapter collections
// ---------------------------------------------------------------------------
// MIGRATED to the schema-sync canon (TypeSpec strangler, WP4-SCHEMACANON).
// The runtime registry lives in functions/src/hermesGateway.ts and is pinned
// byte-for-byte to functions/src/types/generated/hermes-gateway.ts by the
// compile-time Equals assertions in functions/src/types/generatedParity.ts.
// Import gateway doc types from "../types/generated/hermes-gateway.js" (or via
// functions/src/hermesGateway.ts for the named unions + helpers) — do NOT
// re-declare them here.

// ---------------------------------------------------------------------------
// Firestore: pi_agent_connections / pi_agent_pairings
// ---------------------------------------------------------------------------

export type PiAgentConnectionMode = "local" | "directURL" | "relayLink";

export type PiAgentConnectionStatus = "pending" | "online" | "offline" | "unauthorized" | "revoked" | "degraded";

export interface PiAgentInstanceDoc {
  id: string;
  displayName: string;
  endpointURL?: string;
  status: PiAgentConnectionStatus;
  modelName?: string;
  capabilities: string[];
  lastSeenAt?: string;
  schemaVersion: number;
}

export interface PiAgentRuntimeModelDoc {
  id: string;
  providerID: string;
  providerName: string;
  modelID: string;
  displayName: string;
  instanceID?: string;
  schemaVersion: number;
}

export interface PiAgentSessionDoc {
  id: string;
  title?: string;
  preview?: string;
  source?: string;
  model?: string;
  instanceID?: string;
  startedAt?: string;
  lastActiveAt?: string;
  endedAt?: string;
  isActive: boolean;
  messageCount: number;
  toolCallCount: number;
  inputTokens: number;
  outputTokens: number;
  schemaVersion: number;
}

export interface PiAgentConnectionDoc {
  id: string;
  displayName: string;
  mode: PiAgentConnectionMode;
  status: PiAgentConnectionStatus;
  endpointURL?: string;
  advertisedModel?: string;
  selectedInstanceID?: string;
  relayPublicKey?: string;
  relayKeyVersion?: number;
  relayEncryption?: string;
  realtimeRelayURL?: string;
  realtimeRelayStatus?: string;
  realtimeRelayLastSeenAt?: string;
  realtimeRelayProtocolVersion?: number;
  capabilities: string[];
  instances?: PiAgentInstanceDoc[];
  models?: PiAgentRuntimeModelDoc[];
  lastSeenAt?: string;
  createdAt: string;
  updatedAt?: string;
  schemaVersion: number;
}

export interface PiAgentPairingDoc {
  id: string;
  status: "pending" | "completed" | "expired" | "revoked";
  codeHash: string;
  failedAttempts?: number;
  requestedByDeviceId?: string;
  requestedByPlatform?: "ios" | "ipados" | "android" | "macos" | "web";
  displayName?: string;
  connectionId?: string;
  expiresAt: string;
  expireAt?: import("firebase-admin/firestore").Timestamp;
  createdAt: string;
  updatedAt: string;
  schemaVersion: number;
}

export interface PiAgentConnectionAuditEventDoc {
  id: string;
  eventType:
    | "pairing_created"
    | "pairing_completed"
    | "pairing_failed"
    | "connection_created"
    | "connection_revoked"
    | "connection_status_updated";
  connectionId?: string;
  pairingId?: string;
  actorDeviceId?: string;
  observedAt: string;
  detail?: Record<string, unknown>;
  schemaVersion: number;
  expireAt?: import("firebase-admin/firestore").Timestamp;
}

export type PiAgentRelayOperation = "chatCompletions" | "models" | "sessions" | "sessionDetail";

export type PiAgentRelayRequestStatus =
  | "pending"
  | "claimed"
  | "streaming"
  | "completed"
  | "failed"
  | "cancelled"
  | "expired";

export interface PiAgentRelayRequestDoc {
  id: string;
  connectionId: string;
  operation: PiAgentRelayOperation;
  status: PiAgentRelayRequestStatus;
  method: "GET" | "POST";
  payloadCiphertext: string;
  wrappedKey: string;
  relayEncryption: string;
  relayKeyVersion: number;
  error?: string;
  chunkCount: number;
  claimedAt?: string;
  claimedBy?: string;
  completedAt?: string;
  createdAt: string;
  updatedAt: string;
  expiresAt: string;
  expireAt?: import("firebase-admin/firestore").Timestamp;
  schemaVersion: number;
}

export interface PiAgentRelayChunkDoc {
  id: string;
  requestId: string;
  sequence: number;
  kind: "sse" | "data" | "error";
  ciphertext: string;
  createdAt: string;
  updatedAt?: string;
  schemaVersion: number;
}
