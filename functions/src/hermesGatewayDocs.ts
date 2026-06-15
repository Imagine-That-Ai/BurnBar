/**
 * @fileoverview BurnBar Cloud Hermes Gateway Firestore document guards, public
 * views, and read-side serializers. Split out of hermesGateway.ts (max-lines);
 * the original module re-exports every symbol here so existing imports resolve
 * byte-identically. The sealed-envelope shape validators these depend on live in
 * ./hermesGatewayEnvelope.js.
 */

import { recordOrUndefined, stripUndefinedObject } from "./guards.js";
import {
  HERMES_GATEWAY_SCHEMA_VERSION,
  effectiveOversightMode,
  isHermesGatewayApprovalExpired,
  isSha256Hex,
  sanitizeHermesGatewayModelId,
} from "./hermesGatewayCore.js";
import {
  sanitizeGatewayRatchetEnvelope,
  sanitizeGatewayRelayEnvelope,
  sanitizeGatewaySignalEnvelope,
} from "./hermesGatewayEnvelope.js";
import type {
  HermesGatewayApprovalDoc,
  HermesGatewayAttachmentManifestDoc,
  HermesGatewayClientDoc,
  HermesGatewayEventDoc,
  HermesGatewayModelOptionDoc,
} from "./types/generated/hermes-gateway.js";

function isOptionalString(value: unknown): boolean {
  return typeof value === "string" || value === undefined;
}

function isOptionalNumber(value: unknown): boolean {
  return typeof value === "number" || value === undefined;
}

function isOptionalBoolean(value: unknown): boolean {
  return typeof value === "boolean" || value === undefined;
}

function isOptionalNumberArray(value: unknown): boolean {
  return value === undefined || (Array.isArray(value) && value.every((item) => typeof item === "number"));
}

/**
 * Validate the optional AGENT relay-pairing fields (schema 2+). Split out of
 * hasValidOptionalRelayFields so each cohesive field group stays under the
 * complexity ceiling; the accept/reject set is byte-identical.
 */
function hasValidAgentRelayFields(record: Record<string, unknown>): boolean {
  return (
    isOptionalString(record.agentRelayPublicKey) &&
    isOptionalNumber(record.agentRelayKeyVersion) &&
    isOptionalString(record.agentRelayEncryption) &&
    isOptionalNumberArray(record.agentSupportsRelayEnvelopeVersions) &&
    isOptionalNumber(record.agentPreferredRelayEnvelopeVersion) &&
    isOptionalBoolean(record.agentSupportsHpkeV3) &&
    isOptionalBoolean(record.agentSupportsSignalEnvelope) &&
    isOptionalString(record.agentPlatform) &&
    isOptionalString(record.agentAppBuild) &&
    isOptionalString(record.agentRatchetIdentityPublicKey) &&
    isOptionalString(record.agentRatchetSigningPublicKey) &&
    isOptionalString(record.agentRatchetSignedPreKeyPublicKey) &&
    isOptionalString(record.agentRatchetSignedPreKeyId) &&
    isOptionalString(record.agentRatchetSignedPreKeySignature) &&
    isOptionalBoolean(record.agentSupportsRatchetV1)
  );
}

/**
 * Validate the optional PHONE relay-pairing fields (schema 2+). Split out of
 * hasValidOptionalRelayFields; the accept/reject set is byte-identical.
 */
function hasValidPhoneRelayFields(record: Record<string, unknown>): boolean {
  return (
    isOptionalString(record.phoneRelayPublicKey) &&
    isOptionalNumber(record.phoneRelayKeyVersion) &&
    isOptionalString(record.phoneRelayEncryption) &&
    isOptionalNumberArray(record.phoneSupportsRelayEnvelopeVersions) &&
    isOptionalNumber(record.phonePreferredRelayEnvelopeVersion) &&
    isOptionalBoolean(record.phoneSupportsHpkeV3) &&
    isOptionalBoolean(record.phoneSupportsSignalEnvelope) &&
    isOptionalString(record.phonePlatform) &&
    isOptionalString(record.phoneAppBuild) &&
    isOptionalString(record.phoneRatchetIdentityPublicKey) &&
    isOptionalString(record.phoneRatchetSigningPublicKey) &&
    isOptionalString(record.phoneRatchetSignedPreKeyPublicKey) &&
    isOptionalString(record.phoneRatchetSignedPreKeyId) &&
    isOptionalString(record.phoneRatchetSignedPreKeySignature) &&
    isOptionalBoolean(record.phoneSupportsRatchetV1)
  );
}

/**
 * Validate the optional NEGOTIATED-intersection relay fields (schema 2+). Split
 * out of hasValidOptionalRelayFields; the accept/reject set is byte-identical.
 */
function hasValidNegotiatedRelayFields(record: Record<string, unknown>): boolean {
  return (
    isOptionalBoolean(record.supportsRatchetV1) &&
    isOptionalNumberArray(record.supportsRelayEnvelopeVersions) &&
    isOptionalNumber(record.preferredRelayEnvelopeVersion) &&
    isOptionalBoolean(record.supportsHpkeV3) &&
    isOptionalBoolean(record.supportsSignalEnvelope) &&
    isOptionalBoolean(record.relayCapable)
  );
}

/**
 * Tolerate the optional relay-pairing fields (schema 2+) on a client doc: when
 * present each must be the right primitive type; absent is fine (legacy schema-1
 * clients carry none). Factored out so the client-doc guard stays readable.
 */
function hasValidOptionalRelayFields(record: Record<string, unknown>): boolean {
  return hasValidAgentRelayFields(record) && hasValidPhoneRelayFields(record) && hasValidNegotiatedRelayFields(record);
}

/**
 * Validate the required scalar core of a client doc (identity, status, token
 * hash/preview, signing-key + PoP fields, scopes, destination, expiry/rotation).
 * Split out of isHermesGatewayClientDoc to keep that guard under the complexity
 * ceiling; the accept/reject set is byte-identical.
 */
function hasValidClientDocCore(record: Record<string, unknown>): boolean {
  return (
    typeof record.id === "string" &&
    typeof record.uid === "string" &&
    typeof record.displayName === "string" &&
    (record.status === "active" || record.status === "revoked") &&
    isSha256Hex(record.tokenHash) &&
    typeof record.tokenPreview === "string" &&
    isOptionalString(record.agentClientSigningPublicKeyBase64) &&
    isOptionalString(record.agentClientSigningKeyId) &&
    isOptionalBoolean(record.popRequired) &&
    isOptionalNumber(record.popVersion) &&
    Array.isArray(record.scopes) &&
    typeof record.homeDestinationId === "string" &&
    isOptionalString(record.expiresAt) &&
    isOptionalString(record.rotatedAt)
  );
}

export function isHermesGatewayClientDoc(raw: unknown): raw is HermesGatewayClientDoc {
  const record = recordOrUndefined(raw);
  if (!record) return false;
  return (
    hasValidClientDocCore(record) &&
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
    isOptionalString(record.updatedAt) &&
    typeof record.expiresAt === "string" &&
    isOptionalString(record.uploadedAt) &&
    isOptionalString(record.finalizedAt) &&
    (isSha256Hex(record.sha256) || record.sha256 === undefined) &&
    isOptionalString(record.storageGeneration)
  );
}

function hasValidAttachmentManifestEnvelopes(record: Record<string, unknown>): boolean {
  return (
    (record.relayEnvelope === undefined || sanitizeGatewayRelayEnvelope(record.relayEnvelope) !== undefined) &&
    (record.ratchetEnvelope === undefined || sanitizeGatewayRatchetEnvelope(record.ratchetEnvelope) !== undefined) &&
    (record.signalEnvelope === undefined ||
      sanitizeGatewaySignalEnvelope(record.signalEnvelope, "transport") !== undefined)
  );
}

export function isHermesGatewayAttachmentManifestDoc(raw: unknown): raw is HermesGatewayAttachmentManifestDoc {
  const record = recordOrUndefined(raw);
  if (!record) return false;
  const status = record.status;
  return (
    typeof record.id === "string" &&
    typeof record.clientId === "string" &&
    isOptionalString(record.destinationId) &&
    // fileName is sealed (schema 2+) so it is optional now; a legacy schema-1
    // manifest still carries a plaintext fileName. relayEnvelope/ratchetEnvelope
    // are present on sealed manifests and validated when read.
    isOptionalString(record.fileName) &&
    hasValidAttachmentManifestEnvelopes(record) &&
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

type SerializedGatewayEventEnvelopes = {
  relayEnvelope: ReturnType<typeof sanitizeGatewayRelayEnvelope>;
  ratchetEnvelope: ReturnType<typeof sanitizeGatewayRatchetEnvelope>;
  signalEnvelope: ReturnType<typeof sanitizeGatewaySignalEnvelope>;
  isSealedDoc: boolean;
  hasLegacyText: boolean;
  legacyText: string | undefined;
  hasModelSwitchRoute: boolean;
};

/**
 * Resolve the sealed/legacy state of a candidate event doc. A doc is "sealed"
 * once it carries a valid relay/ratchet/signal envelope OR advertises
 * schemaVersion >= 2; for ANY sealed doc the private plaintext fields MUST be
 * dropped. Legacy plaintext is surfaced ONLY for an unsealed schema-1 doc. Split
 * out so serializeHermesGatewayEvent stays under the complexity ceiling.
 */
function resolveGatewayEventEnvelopes(record: Record<string, unknown>): SerializedGatewayEventEnvelopes {
  const relayEnvelope = sanitizeGatewayRelayEnvelope(record.relayEnvelope);
  const ratchetEnvelope = sanitizeGatewayRatchetEnvelope(record.ratchetEnvelope);
  const signalEnvelope = sanitizeGatewaySignalEnvelope(record.signalEnvelope, "transport");
  const schemaVersion = typeof record.schemaVersion === "number" ? record.schemaVersion : NaN;
  const isSealedDoc =
    relayEnvelope !== undefined || ratchetEnvelope !== undefined || signalEnvelope !== undefined || schemaVersion >= 2;
  const hasLegacyText = !isSealedDoc && typeof record.text === "string";
  const legacyText = hasLegacyText && typeof record.text === "string" ? record.text : undefined;
  const isModelSwitch = record.kind === "model_switch";
  const hasModelSwitchRoute = isModelSwitch && typeof record.modelId === "string";
  return {
    relayEnvelope,
    ratchetEnvelope,
    signalEnvelope,
    isSealedDoc,
    hasLegacyText,
    legacyText,
    hasModelSwitchRoute,
  };
}

/**
 * Whether the candidate event record carries at least one routable body: a
 * model-switch route, a sealed envelope, or legacy plaintext. Split out so the
 * required-field guard in serializeHermesGatewayEvent stays under the complexity
 * ceiling; the accept/reject set is byte-identical.
 */
function hasGatewayEventRoutableBody(envelopes: SerializedGatewayEventEnvelopes): boolean {
  return (
    envelopes.hasModelSwitchRoute ||
    Boolean(envelopes.relayEnvelope) ||
    Boolean(envelopes.ratchetEnvelope) ||
    Boolean(envelopes.signalEnvelope) ||
    envelopes.hasLegacyText
  );
}

export function serializeHermesGatewayEvent(raw: unknown): HermesGatewayEventDoc | undefined {
  const record = recordOrUndefined(raw);
  if (!record) return undefined;
  const envelopes = resolveGatewayEventEnvelopes(record);
  const { relayEnvelope, ratchetEnvelope, signalEnvelope, isSealedDoc, legacyText } = envelopes;
  if (
    typeof record.id !== "string" ||
    typeof record.sequence !== "number" ||
    (record.kind !== "message" && record.kind !== "model_switch") ||
    typeof record.destinationId !== "string" ||
    typeof record.senderId !== "string" ||
    !hasGatewayEventRoutableBody(envelopes) ||
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
    popVersion: typeof client.popVersion === "number" ? client.popVersion : 1,
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
    isOptionalString(record.toolName) &&
    typeof record.summary === "string" &&
    (status === "waiting_for_approval" || status === "approved" || status === "rejected" || status === "expired") &&
    typeof record.requestedAt === "string" &&
    typeof record.expiresAt === "string" &&
    isOptionalString(record.respondedAt) &&
    isOptionalString(record.approvedByDeviceId) &&
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
