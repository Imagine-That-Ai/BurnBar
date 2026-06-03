/**
 * @fileoverview BurnBar Cloud Hermes Gateway contracts and pure helpers.
 */

import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import { isRecord, recordOrUndefined } from "./guards.js";

export const HERMES_GATEWAY_SCHEMA_VERSION = 1;
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
export const HERMES_GATEWAY_PROTOCOL_VERSION = 1;
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
  threadId?: string;
  senderId: string;
  senderDisplayName?: string;
  text: string;
  modelId?: string;
  attachmentIds: string[];
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
  text?: string;
  attachmentIds: string[];
  createdAt: string;
  schemaVersion: number;
}

export interface HermesGatewayAttachmentManifestDoc {
  id: string;
  clientId: string;
  destinationId?: string;
  fileName: string;
  contentType: string;
  byteCount: number;
  storagePath: string;
  status: HermesGatewayAttachmentStatus;
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
    typeof record.createdAt === "string" &&
    typeof record.updatedAt === "string" &&
    typeof record.schemaVersion === "number"
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
    typeof record.fileName === "string" &&
    typeof record.contentType === "string" &&
    typeof record.byteCount === "number" &&
    Number.isFinite(record.byteCount) &&
    typeof record.storagePath === "string" &&
    (status === "pending_upload" ||
      status === "uploaded" ||
      status === "failed" ||
      status === "expired" ||
      status === "rejected") &&
    typeof record.createdAt === "string" &&
    (typeof record.updatedAt === "string" || record.updatedAt === undefined) &&
    typeof record.expiresAt === "string" &&
    (typeof record.uploadedAt === "string" || record.uploadedAt === undefined) &&
    (typeof record.finalizedAt === "string" || record.finalizedAt === undefined) &&
    (isSha256Hex(record.sha256) || record.sha256 === undefined) &&
    (typeof record.storageGeneration === "string" || record.storageGeneration === undefined) &&
    typeof record.schemaVersion === "number"
  );
}

export function serializeHermesGatewayEvent(raw: unknown): HermesGatewayEventDoc | undefined {
  const record = recordOrUndefined(raw);
  if (!record) return undefined;
  if (
    typeof record.id !== "string" ||
    typeof record.sequence !== "number" ||
    (record.kind !== "message" && record.kind !== "model_switch") ||
    typeof record.destinationId !== "string" ||
    typeof record.senderId !== "string" ||
    typeof record.text !== "string" ||
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
    threadId: typeof record.threadId === "string" ? record.threadId : undefined,
    senderId: record.senderId,
    senderDisplayName: typeof record.senderDisplayName === "string" ? record.senderDisplayName : undefined,
    text: record.text,
    modelId: typeof record.modelId === "string" ? record.modelId : undefined,
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
