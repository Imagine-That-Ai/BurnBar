/**
 * @fileoverview BurnBar Cloud Hermes Gateway core constants and leaf pure
 * helpers: token/code generation, expiry + presence checks, oversight + approval
 * TTL, hashing, scope + destination + cursor sanitizers. Split out of
 * hermesGateway.ts (max-lines); the original module re-exports every symbol here
 * so existing imports resolve byte-identically. Holds no envelope/doc logic.
 */

import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import type { HermesGatewayApprovalDoc, HermesGatewayClientDoc } from "./types/generated/hermes-gateway.js";

export const HERMES_GATEWAY_SCHEMA_VERSION = 2;
export const HERMES_GATEWAY_DEVICE_SESSION_TTL_MS = 10 * 60 * 1000;
const HERMES_GATEWAY_TOKEN_BYTES = 32;
// Gateway access tokens are only bearer-compatible as an index hint; every HTTP
// request must also prove possession of the client signing key pinned at pairing.
// Tokens without expiresAt/signing-key material are legacy credentials and fail
// closed until the client re-pairs.
export const HERMES_GATEWAY_TOKEN_TTL_MS = 24 * 60 * 60 * 1000;
export const HERMES_GATEWAY_MAX_EVENT_TEXT = 32_000;
export const HERMES_GATEWAY_MAX_MESSAGE_TEXT = 64_000;
export const HERMES_GATEWAY_MAX_ATTACHMENT_BYTES = 50 * 1024 * 1024;
export const HERMES_GATEWAY_DEFAULT_DESTINATION_ID = "burnbar:home";
const HERMES_GATEWAY_DEFAULT_DESTINATION_DOC_ID = "home";

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
const HERMES_GATEWAY_MAX_APPROVAL_TTL_MS = HERMES_GATEWAY_APPROVAL_TTL_MS;
const HERMES_GATEWAY_MAX_APPROVAL_SUMMARY = 2_000;

export const HERMES_GATEWAY_SCOPES = ["hermes.gateway.read", "hermes.gateway.write", "hermes.gateway.manage"] as const;
const HERMES_GATEWAY_DEFAULT_SCOPES = ["hermes.gateway.read", "hermes.gateway.write"] as const;

export type HermesGatewayScope = (typeof HERMES_GATEWAY_SCOPES)[number];

// Human-in-the-loop oversight toggle. "supervised" arms an approval gate before
// each risky agent action; "autonomous" lets the agent run unattended. The safe
// default (supervised) applies whenever the field is unset.
type HermesGatewayOversightMode = "supervised" | "autonomous";
const HERMES_GATEWAY_DEFAULT_OVERSIGHT_MODE: HermesGatewayOversightMode = "supervised";

const USER_CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
const TOKEN_PREFIX = "obb_hgw_";

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
