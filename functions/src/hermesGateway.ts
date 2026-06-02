/**
 * @fileoverview BurnBar Cloud Hermes Gateway contracts and pure helpers.
 */

import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import { isRecord, recordOrUndefined } from "./guards.js";

export const HERMES_GATEWAY_SCHEMA_VERSION = 1;
export const HERMES_GATEWAY_DEVICE_SESSION_TTL_MS = 10 * 60 * 1000;
export const HERMES_GATEWAY_TOKEN_BYTES = 32;
export const HERMES_GATEWAY_MAX_EVENT_TEXT = 32_000;
export const HERMES_GATEWAY_MAX_MESSAGE_TEXT = 64_000;
export const HERMES_GATEWAY_MAX_ATTACHMENT_BYTES = 50 * 1024 * 1024;
export const HERMES_GATEWAY_DEFAULT_DESTINATION_ID = "burnbar:home";
export const HERMES_GATEWAY_DEFAULT_DESTINATION_DOC_ID = "home";

export const HERMES_GATEWAY_SCOPES = ["hermes.gateway.read", "hermes.gateway.write", "hermes.gateway.manage"] as const;
export const HERMES_GATEWAY_DEFAULT_SCOPES = ["hermes.gateway.read", "hermes.gateway.write"] as const;

export type HermesGatewayScope = (typeof HERMES_GATEWAY_SCOPES)[number];

export type HermesGatewayClientStatus = "active" | "revoked";
export type HermesGatewayDeviceSessionStatus = "pending" | "approved" | "denied" | "expired";
export type HermesGatewayDestinationKind = "home" | "chat" | "thread";
export type HermesGatewayEventKind = "message" | "model_switch";
export type HermesGatewayMessageKind = "agent_message" | "typing";

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
  lastSeenAt?: string;
  runtimeModelId?: string;
  runtimeProviderId?: string;
  runtimeModelOptions?: HermesGatewayModelOptionDoc[];
  runtimeUpdatedAt?: string;
  revokedAt?: string;
  createdAt: string;
  updatedAt: string;
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
  status: "pending_upload" | "uploaded" | "failed";
  createdAt: string;
  expiresAt: string;
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
    typeof record.createdAt === "string" &&
    typeof record.updatedAt === "string" &&
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
    const providerId = typeof record.providerId === "string" && record.providerId.trim()
      ? record.providerId.trim().slice(0, 80)
      : "hermes";
    const providerName = typeof record.providerName === "string" && record.providerName.trim()
      ? record.providerName.trim().slice(0, 120)
      : providerId;
    const displayName = typeof record.displayName === "string" && record.displayName.trim()
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
    lastSeenAt: client.lastSeenAt,
    runtimeModelId: client.runtimeModelId,
    runtimeProviderId: client.runtimeProviderId,
    runtimeModelOptions: client.runtimeModelOptions,
    runtimeUpdatedAt: client.runtimeUpdatedAt,
    revokedAt: client.revokedAt,
    createdAt: client.createdAt,
    updatedAt: client.updatedAt,
    schemaVersion: client.schemaVersion,
  };
}

export function isRecordWithString(value: unknown, key: string): boolean {
  return isRecord(value) && typeof value[key] === "string" && value[key].trim().length > 0;
}
