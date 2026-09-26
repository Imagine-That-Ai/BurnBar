/**
 * @fileoverview BurnBar Cloud Hermes Gateway contracts and pure helpers.
 *
 * This module is the stable public entry point for the hermes-gateway domain.
 * Its implementation is split across cohesive sibling modules to stay within the
 * max-lines / complexity budgets, and every symbol is re-exported here verbatim
 * so existing `import ... from "./hermesGateway.js"` callers resolve identically:
 *   - ./hermesGatewayCore.js     constants + leaf pure helpers (tokens, presence,
 *                                oversight, approval TTL, hashing, scopes, …)
 *   - ./hermesGatewayEnvelope.js sealed-envelope shape validators (relay v1/v2/v3,
 *                                ratchet v1, official-libsignal v4) + capabilities
 *   - ./hermesGatewayDocs.js     Firestore document guards, public views, and
 *                                read-side serializers
 */

export * from "./hermesGatewayCore.js";
export * from "./hermesGatewayEnvelope.js";
export * from "./hermesGatewayDocs.js";

// ---------------------------------------------------------------------------
// Firestore document shapes (hermes-gateway domain) — re-exported verbatim from
// the generated TypeSpec canon. tools/schema-sync/typespec/domains/
// hermes-gateway.tsp is the single source of truth; `npm --prefix
// tools/schema-sync run emit` regenerates
// functions/src/types/generated/hermes-gateway.ts and check-tsp-canon.mjs pins
// the emitted file to the .tsp. These interfaces were hand-maintained
// duplicates here until functions/src/types/generatedParity.ts proved them
// exactly type-identical to the canon (WP4-SCHEMACANON); the hand copies are
// folded into these re-exports (WP5-GW-REEXPORT). To change a doc shape, edit
// the .tsp and re-emit — never the generated file, never a local copy here.
//
// Field-level invariants preserved from the former hand-written definitions:
//
// GatewayRelayEnvelopeDoc — per-document sealed sub-object carried by E2EE
//   gateway docs (schema 2+). `payloadCiphertext` is the AES-256-GCM
//   `.combined` seal of the direction's private JSON payload; `wrappedKey` is
//   the per-payload symmetric key wrapped to the recipient's relay public key.
//   Mirrors the relay-request precedent (HermesRelayRequestDoc) so the server's
//   opaque store-and-forward treatment is identical: the server validates SHAPE
//   only (requireGatewayRelayEnvelope) and never has the recipient private key,
//   so it can never decrypt. `enc` (HPKE v3 only) is the encapsulated key
//   (DHKEM(P-256) X9.63, base64); v1/v2 keep the historical layout where the
//   ephemeral public key is carried inside `wrappedKey`. `senderPublicKey` is
//   an OPTIONAL wire HINT (relay key v2+): the sealing peer's X9.63
//   uncompressed P-256 public key (65B, base64) — the BLIND relay round-trips
//   it verbatim and never uses it for crypto; clients bind the PINNED relay
//   key, not this hint. Required for a v2 envelope, absent on a v1 envelope
//   (legacy/back-compat).
//
// HermesGatewayClientDoc —
//   `popVersion` (L2): proof-of-possession version the client signs with.
//     Absent / 1 ⇒ PoP v1 (query string NOT integrity-protected). 2 ⇒ PoP v2
//     (query bound into the signature). Once a client registers 2, the server
//     refuses a v1 downgrade.
//   Relay E2EE pairing material (schema 2+): the AGENT publishes its relay
//     public key at device/start (and re-publishes via /runtime); the PHONE
//     publishes its own at approveHermesGatewayDeviceGrant. Phone→agent event
//     bodies are wrapped to agentRelayPublicKey; agent→phone reply/attachment
//     bodies are wrapped to phoneRelayPublicKey. X9.63 uncompressed base64
//     (65B).
//   `agentSupportsSignalEnvelope` / `phoneSupportsSignalEnvelope`:
//     official-libsignal (relay v4) capability bit. Persisted only so the
//     negotiated intersection round-trips; defaults to false (absent) and stays
//     false for every shipping client until the libsignal runtime readiness
//     gate is complete.
//   Ratcheted E2EE pairing material (Phase 6): the public prekey fields let
//     endpoints negotiate a reviewed Double-Ratchet-style v1 session without
//     the blind relay seeing session secrets. The server stores and echoes
//     public material only; private identity, signing, prekey, and session
//     state live in device Keychain/Keystore storage.
//   `supportsRelayEnvelopeVersions` / `preferredRelayEnvelopeVersion`:
//     negotiated intersection of the agent and phone gateway envelope versions.
//     New senders choose preferredRelayEnvelopeVersion when sealing to this
//     client. `supportsSignalEnvelope` is the negotiated AND of both endpoints'
//     bits — false unless BOTH sides advertise it, which no shipping client
//     does yet (flag OFF).
//   `relayCapable`: true once BOTH endpoints have published a relay public key.
//     New gateway writes require this sealed path; legacy schema-1 plaintext is
//     read-only.
//   `agentVersion`: free-form version string the runtime self-reports via
//     /runtime (e.g. the Hermes Agent build id). Surfaced in /state for a
//     truthful "gateway version".
//   `pendingModelId` / `pendingModelRequestedAt`: optimistic model-switch
//     marker — set when a switch is enqueued, cleared once the runtime
//     republishes a matching runtimeModelId (or after the TTL).
//   `oversightMode`: human-in-the-loop toggle; unset is treated as
//     "supervised".
//
// HermesGatewayApprovalDoc — `actionId` is a stable per-action identifier
//   chosen by the agent so a retried arm request is idempotent and the runtime
//   can correlate the resolution with its action. `approvedByDeviceId` is bound
//   by the server to the trusted native device that resolved the gate — never
//   written by the client (mirrors cli_agent_mission_requests).
//
// HermesGatewayEventDoc — threadId / senderDisplayName / text are PRIVATE
//   (schema 2+): they live inside relayEnvelope.payloadCiphertext, sealed to
//   the agent's relay key. They remain typed as optional only so the LEGACY
//   plaintext read fallback can still surface a pre-migration schema-1 doc.
//   relayEnvelope is the sealed body for schema 2+ events (absent on legacy
//   schema-1 docs); ratchetEnvelope is the Phase 6 v1-session body, mutually
//   exclusive with relayEnvelope on new writes; signalEnvelope is the official
//   libsignal envelope v1, read-tolerant only while runtime readiness is not
//   green (new production writes reject it until every libsignal
//   cross-language runtime gate is complete).
//
// HermesGatewayMessageDoc — text is PRIVATE (schema 2+): sealed inside
//   relayEnvelope to the phone's relay key, optional only for the legacy
//   schema-1 plaintext read fallback. The envelope-field semantics mirror
//   HermesGatewayEventDoc above.
//
// HermesGatewayAttachmentManifestDoc — fileName is PRIVATE (schema 2+): sealed
//   inside relayEnvelope alongside byteCount/contentType, optional only for the
//   legacy schema-1 read fallback. relayEnvelope carries the sealed manifest
//   body ({fileName,byteCount,contentType}) + the wrapped attachment-body key
//   for schema 2+ encrypted uploads: the agent seals the bytes with a
//   per-attachment key before the signed-URL upload, so Storage holds
//   ciphertext and the server's sha256 is a ciphertext integrity check. The
//   uploaded bytes remain opaque ciphertext for ratchetEnvelope manifests too;
//   the relay validates envelope shape only and never decrypts. signalEnvelope
//   stays read-tolerant-only until activation so staged clients cannot assume
//   Signal was used.
// ---------------------------------------------------------------------------
export type {
  GatewayRatchetEnvelopeDoc,
  GatewayRatchetHeaderDoc,
  GatewayRelayEnvelopeDoc,
  HermesGatewayApprovalDoc,
  HermesGatewayAttachmentManifestDoc,
  HermesGatewayClientDoc,
  HermesGatewayDestinationDoc,
  HermesGatewayEventDoc,
  HermesGatewayMessageDoc,
  HermesGatewayModelOptionDoc,
} from "./types/generated/hermes-gateway.js";
