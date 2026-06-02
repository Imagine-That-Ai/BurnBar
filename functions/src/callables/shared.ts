/**
 * @fileoverview Shared helpers, constants, and provider registry for Cloud Function callables.
 */

import { FieldValue, Timestamp, type WriteBatch } from "firebase-admin/firestore";
import { getStorage } from "firebase-admin/storage";
import { HttpsError } from "firebase-functions/v2/https";
import { defineSecret } from "firebase-functions/params";
import type { Firestore } from "firebase-admin/firestore";
import { createHash, randomBytes } from "node:crypto";
import Stripe from "stripe";

import { getConfig } from "../config.js";
import { stripeWithResilience } from "../resilienceHelpers.js";
import { storeCredential } from "../secrets.js";
import { providerAccountSecretRefPath, refreshUserProviderAccountQuota, refreshUserProviderQuota } from "../quota.js";
import { upsertDeviceLink } from "../domains/device-links/index.js";
import { minimaxAdapter } from "../providers/minimax.js";
import { zaiAdapter } from "../providers/zai.js";
import { xaiAdapter } from "../providers/xai.js";
import { mimoAdapter } from "../providers/mimo.js";
import { kimiAdapter } from "../providers/kimi.js";
import { factoryAdapter } from "../providers/factory.js";
import { cursorAdapter } from "../providers/cursor.js";
import { openaiAdapter } from "../providers/openai.js";
import type {
  Provider,
  CredentialKind,
  ProviderAccountDoc,
  ProviderAccountConnectContext,
  ProviderAccountSecretRefDoc,
  ProviderConnectionDoc,
  QuotaSnapshotDoc,
  HermesConnectionAuditEventDoc,
  PiAgentConnectionAuditEventDoc,
  ProjectMemoryFreshness,
  CloudVaultBlobEnvelopeDoc,
} from "../types.js";
import {
  isRecord,
  isTimestampWithToMillis,
  jsonObject,
  optionalStringField,
  recordOrUndefined,
  stripUndefinedObject,
} from "../guards.js";
import { logError } from "../logging.js";
import { auth, db } from "../adminRuntime.js";
import {
  allowanceDocPath,
  CLOUD_PRO_ALLOWANCE_SCHEMA_VERSION,
  monthKeyForDate,
  unitsForCloudProTopUp,
  type CloudProTopUpKind,
} from "../cloudProAllowanceCore.js";
import { loadCloudProAllowanceConfig } from "../cloudProAllowanceRemoteConfig.js";
import { assertCloudFeatureNotSuspended } from "../cloudFeatureSuspensions.js";

// ---------------------------------------------------------------------------
// Provider adapter registry
// ---------------------------------------------------------------------------
export function backendAdapterFor(provider: Provider) {
  switch (provider) {
    case "openai":
      return openaiAdapter;
    case "minimax":
      return minimaxAdapter;
    case "zai":
      return zaiAdapter;
    case "factory":
      return factoryAdapter;
    case "cursor":
      return cursorAdapter;
    case "xai":
      return xaiAdapter;
    case "mimo":
      return mimoAdapter;
    case "kimi":
      return kimiAdapter;
    default:
      return undefined;
  }
}

export const ALLOWED_PROVIDERS = new Set<string>([
  "openai",
  "minimax",
  "zai",
  "factory",
  "cursor",
  "claude-code",
  "codex",
  "opencode",
  "antigravity",
  "xai",
  "mimo",
  "kimi",
]);

export const CONNECTION_SCHEMA_VERSION = 1;
export const ACCOUNT_SCHEMA_VERSION = 2;
export const HERMES_SCHEMA_VERSION = 1;
export const HERMES_PAIRING_TTL_MS = 10 * 60 * 1000;
export const HERMES_PAIRING_AUDIT_TTL_MS = 90 * 24 * 60 * 60 * 1000;
export const HERMES_MAX_FAILED_PAIRING_ATTEMPTS = 5;
export const PI_AGENT_SCHEMA_VERSION = 1;
export const PI_AGENT_PAIRING_TTL_MS = 10 * 60 * 1000;
export const PI_AGENT_PAIRING_AUDIT_TTL_MS = 90 * 24 * 60 * 60 * 1000;
export const PI_AGENT_MAX_FAILED_PAIRING_ATTEMPTS = 5;
export const HOSTED_QUOTA_PROVIDERS = new Set<string>(["codex"]);
export const SELF_HOSTED_QUOTA_PROVIDERS = new Set<string>(["claude-code", "codex", "opencode", "antigravity"]);
export const BURNBAR_PRO_ENTITLEMENT_ID = "burnbar_pro";
export const BURNBAR_PRO_MAX_ENTITLEMENT_ID = "burnbar_pro_max";
export const BURNBAR_ULTRA_ENTITLEMENT_ID = "burnbar_ultra";
export const STRIPE_SECRET_KEY = defineSecret("STRIPE_SECRET_KEY");
export const STRIPE_WEBHOOK_SECRET = defineSecret("STRIPE_WEBHOOK_SECRET");
export const REMOTE_MCP_TOKEN_HMAC_SECRET = defineSecret("REMOTE_MCP_TOKEN_HMAC_SECRET");
export const STRIPE_API_SECRETS = [STRIPE_SECRET_KEY];
export const STRIPE_WEBHOOK_SECRETS = [STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET];
export const GOOGLE_PLAY_ACTIVE_STATES = new Set<string>([
  "SUBSCRIPTION_STATE_ACTIVE",
  "SUBSCRIPTION_STATE_IN_GRACE_PERIOD",
]);
export const STRIPE_ACTIVE_STATES = new Set<string>(["active", "trialing", "past_due"]);

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

export function assertProvider(provider: unknown): asserts provider is Provider {
  if (typeof provider !== "string" || !ALLOWED_PROVIDERS.has(provider)) {
    throw new HttpsError(
      "invalid-argument",
      `Unsupported provider "${String(provider)}". Backend connections only support: ${[...ALLOWED_PROVIDERS].join(", ")}.`,
    );
  }
}

export function nowISO(): string {
  return new Date().toISOString();
}

export function safeIdentifier(raw: unknown, prefix: string): string {
  const value = typeof raw === "string" ? raw.trim() : "";
  const safe = value
    .toLowerCase()
    .replace(/[^a-z0-9_-]/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "");
  return safe || `${prefix}_${randomBytes(8).toString("hex")}`;
}

export function requiredIdentifier(raw: unknown, fieldName: string): string {
  if (typeof raw !== "string" || raw.trim().length === 0) {
    throw new HttpsError("invalid-argument", `${fieldName} is required.`);
  }
  const safe = raw
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9_-]/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "");
  if (!safe) {
    throw new HttpsError("invalid-argument", `${fieldName} must contain letters or numbers.`);
  }
  return safe;
}

export function optionalTrimmedString(raw: unknown): string | undefined {
  if (typeof raw !== "string") {
    return undefined;
  }
  const value = raw.trim();
  return value.length > 0 ? value : undefined;
}

export function boundedTrimmedString(raw: unknown, fieldName: string, maxLength: number, required: true): string;
export function boundedTrimmedString(
  raw: unknown,
  fieldName: string,
  maxLength: number,
  required?: false,
): string | undefined;
export function boundedTrimmedString(
  raw: unknown,
  fieldName: string,
  maxLength: number,
  required = false,
): string | undefined {
  const value = optionalTrimmedString(raw);
  if (!value) {
    if (required) {
      throw new HttpsError("invalid-argument", `${fieldName} is required.`);
    }
    return undefined;
  }
  if (value.length > maxLength) {
    throw new HttpsError("invalid-argument", `${fieldName} must be ${maxLength} characters or fewer.`);
  }
  return value;
}

export function normalizedSearchTerms(raw: string): string[] {
  const stopwords = new Set([
    "the",
    "and",
    "for",
    "with",
    "that",
    "this",
    "from",
    "how",
    "what",
    "where",
    "when",
    "why",
    "are",
    "was",
  ]);
  return Array.from(
    new Set(
      raw
        .toLowerCase()
        .split(/[^a-z0-9]+/u)
        .map((part) => part.trim())
        .filter((part) => part.length >= 2 && !stopwords.has(part)),
    ),
  ).slice(0, 8);
}

export function searchScore(text: string, terms: string[]): number {
  const lower = text.toLowerCase();
  return terms.reduce((score, term) => score + (lower.includes(term) ? 1 : 0), 0);
}

export function sha256Hex(text: string): string {
  return createHash("sha256").update(text).digest("hex");
}

export function safeCloudDocumentID(raw: unknown, fieldName: string): string {
  const value = boundedTrimmedString(raw, fieldName, 512, true);
  if (!/^[A-Za-z0-9_.:-]+$/u.test(value) || value.includes("..") || value.includes("/")) {
    throw new HttpsError("invalid-argument", `${fieldName} contains unsupported characters.`);
  }
  return value;
}

function safeStoragePathDocumentSegment(raw: unknown, fieldName: string): string {
  const value = boundedTrimmedString(raw, fieldName, 512, true);
  if (
    value === "." ||
    value === ".." ||
    value.includes("/") ||
    value.includes("\\") ||
    /[\u0000-\u001F\u007F]/u.test(value)
  ) {
    throw new HttpsError("invalid-argument", `${fieldName} contains unsupported characters.`);
  }
  return value;
}

export function requireHexDigest(raw: unknown, fieldName: string): string {
  const value = boundedTrimmedString(raw, fieldName, 128, true);
  if (!/^[a-f0-9]{32,128}$/u.test(value)) {
    throw new HttpsError("invalid-argument", `${fieldName} must be a lowercase hex digest.`);
  }
  return value;
}

export function requireBoundedNumber(raw: unknown, fieldName: string, min: number, max: number): number {
  const value = typeof raw === "number" ? raw : Number(raw);
  if (!Number.isFinite(value)) {
    throw new HttpsError("invalid-argument", `${fieldName} must be a number.`);
  }
  const rounded = Math.floor(value);
  if (rounded < min || rounded > max) {
    throw new HttpsError("invalid-argument", `${fieldName} must be between ${min} and ${max}.`);
  }
  return rounded;
}

export function requireRecordArray(raw: unknown, fieldName: string, maxLength: number): Array<Record<string, unknown>> {
  if (!Array.isArray(raw)) {
    throw new HttpsError("invalid-argument", `${fieldName} must be an array.`);
  }
  if (raw.length > maxLength) {
    throw new HttpsError("invalid-argument", `${fieldName} can contain at most ${maxLength} items.`);
  }
  return raw.map((item, idx) => {
    if (!item || typeof item !== "object" || Array.isArray(item)) {
      throw new HttpsError("invalid-argument", `${fieldName}[${idx}] must be an object.`);
    }
    return item;
  });
}

export async function commitBatchedWrites(
  writes: Array<(batch: WriteBatch) => void>,
  maxWritesPerBatch = 450,
): Promise<void> {
  for (let start = 0; start < writes.length; start += maxWritesPerBatch) {
    const batch = db.batch();
    for (const write of writes.slice(start, start + maxWritesPerBatch)) {
      write(batch);
    }
    await batch.commit();
  }
}

export function requireTokenHashes(raw: unknown, fieldName: string): string[] {
  return requireSearchHashes(raw, fieldName, true);
}

export function requireOptionalSearchHashes(raw: unknown, fieldName: string): string[] {
  return requireSearchHashes(raw, fieldName, false);
}

export function requireSearchHashes(raw: unknown, fieldName: string, required: boolean): string[] {
  if (raw == null && !required) return [];
  if (!Array.isArray(raw)) {
    throw new HttpsError("invalid-argument", `${fieldName} must be an array.`);
  }
  const unique = Array.from(new Set(raw.filter((item): item is string => typeof item === "string")));
  if ((required && unique.length === 0) || unique.length > 1024) {
    throw new HttpsError(
      "invalid-argument",
      `${fieldName} must contain ${required ? "between 1 and" : "at most"} 1024 hashes.`,
    );
  }
  for (const hash of unique) {
    if (!/^[a-f0-9]{32}$/u.test(hash)) {
      throw new HttpsError("invalid-argument", `${fieldName} contains an invalid hash.`);
    }
  }
  return unique;
}

export function requireSealedText(raw: unknown, fieldName: string): Record<string, unknown> {
  if (!isRecord(raw)) {
    throw new HttpsError("invalid-argument", `${fieldName} must be an encrypted text envelope.`);
  }
  const envelope = raw;
  const algorithm = boundedTrimmedString(envelope.algorithm, `${fieldName}.algorithm`, 64, true);
  if (algorithm !== "AES-256-GCM") {
    throw new HttpsError("invalid-argument", `${fieldName}.algorithm must be AES-256-GCM.`);
  }
  requireBoundedNumber(envelope.keyVersion, `${fieldName}.keyVersion`, 1, 100);
  for (const key of ["nonce", "ciphertext", "tag"]) {
    const value = boundedTrimmedString(envelope[key], `${fieldName}.${key}`, 8192, true);
    if (!/^[A-Za-z0-9+/=]+$/u.test(value)) {
      throw new HttpsError("invalid-argument", `${fieldName}.${key} must be base64.`);
    }
  }
  return envelope;
}

export function requireISODateString(raw: unknown, fieldName: string): string {
  const value = boundedTrimmedString(raw, fieldName, 64, true);
  const parsed = Date.parse(value);
  if (!Number.isFinite(parsed)) {
    throw new HttpsError("invalid-argument", `${fieldName} must be an ISO 8601 date.`);
  }
  return new Date(parsed).toISOString();
}

export function optionalISODateString(raw: unknown, fieldName: string): string | undefined {
  if (raw == null) return undefined;
  return requireISODateString(raw, fieldName);
}

export function requireBoundedStringArray(
  raw: unknown,
  fieldName: string,
  maxLength: number,
  itemMaxLength: number,
): string[] {
  if (!Array.isArray(raw)) {
    throw new HttpsError("invalid-argument", `${fieldName} must be an array.`);
  }
  if (raw.length > maxLength) {
    throw new HttpsError("invalid-argument", `${fieldName} can contain at most ${maxLength} items.`);
  }
  const values = raw.map((item, idx) => boundedTrimmedString(item, `${fieldName}[${idx}]`, itemMaxLength, true));
  return Array.from(new Set(values));
}

export function parseProjectMemoryFreshness(raw: unknown): ProjectMemoryFreshness {
  const value = boundedTrimmedString(raw, "freshness", 32, false);
  if (value === "needsRefresh" || value === "stale") return value;
  return "fresh";
}

export function requireCloudVaultBlobEnvelope(raw: unknown, fieldName: string): CloudVaultBlobEnvelopeDoc {
  if (!isRecord(raw)) {
    throw new HttpsError("invalid-argument", `${fieldName} must be an encrypted blob envelope.`);
  }
  const envelope = raw;
  const algorithm = boundedTrimmedString(envelope.algorithm, `${fieldName}.algorithm`, 64, true);
  if (algorithm !== "AES-256-GCM") {
    throw new HttpsError("invalid-argument", `${fieldName}.algorithm must be AES-256-GCM.`);
  }
  const keyVersion = requireBoundedNumber(envelope.keyVersion, `${fieldName}.keyVersion`, 1, 100);
  const schemaVersion = requireBoundedNumber(envelope.schemaVersion ?? 1, `${fieldName}.schemaVersion`, 1, 10);
  const plaintextSHA256 = requireHexDigest(envelope.plaintextSHA256, `${fieldName}.plaintextSHA256`);
  const sealedBoxBase64 = boundedTrimmedString(
    envelope.sealedBoxBase64,
    `${fieldName}.sealedBoxBase64`,
    1_500_000,
    true,
  );
  if (!/^[A-Za-z0-9+/=]+$/u.test(sealedBoxBase64)) {
    throw new HttpsError("invalid-argument", `${fieldName}.sealedBoxBase64 must be base64.`);
  }
  const createdAt = optionalISODateString(envelope.createdAt, `${fieldName}.createdAt`) ?? nowISO();
  return {
    schemaVersion,
    algorithm,
    keyVersion,
    plaintextSHA256,
    sealedBoxBase64,
    createdAt,
  };
}

export function assertUserStoragePath(
  uid: string,
  storagePath: string,
  expectedBodyHash?: string,
  expectedDocumentID?: string,
): void {
  const parts = storagePath.split("/");
  if (
    parts.length !== 6 ||
    parts[0] !== "users" ||
    parts[1] !== uid ||
    parts[2] !== "session_logs" ||
    parts[4] !== "bodies" ||
    !parts[5].endsWith(".json.aesgcm")
  ) {
    throw new HttpsError("permission-denied", "Invalid encrypted session storage path.");
  }
  const pathDocumentID = expectedDocumentID
    ? safeCloudDocumentID(parts[3], "storagePath.documentID")
    : safeStoragePathDocumentSegment(parts[3], "storagePath.documentID");
  if (expectedDocumentID && pathDocumentID !== expectedDocumentID) {
    throw new HttpsError("invalid-argument", "Encrypted session storage path does not match documentID.");
  }
  const pathBodyHash = requireHexDigest(parts[5].slice(0, -".json.aesgcm".length), "storagePath.bodyHash");
  if (expectedBodyHash && pathBodyHash !== expectedBodyHash) {
    throw new HttpsError("invalid-argument", "Encrypted session storage path does not match bodyHash.");
  }
}

export async function assertEncryptedSessionBlobObject(args: {
  uid: string;
  storagePath: string;
  documentID: string;
  bodyHash: string;
  encryptedByteCount: number;
}): Promise<number> {
  assertUserStoragePath(args.uid, args.storagePath, args.bodyHash, args.documentID);
  let metadata: Record<string, unknown>;
  try {
    [metadata] = await getStorage().bucket().file(args.storagePath).getMetadata();
  } catch {
    throw new HttpsError(
      "failed-precondition",
      "Encrypted session body must be uploaded before committing the search index.",
    );
  }
  return resolveEncryptedSessionBlobByteCount({
    metadata,
    maxBytes: getConfig().encryptedSessionBlobMaxBytes,
  });
}

export function resolveEncryptedSessionBlobByteCount(args: {
  metadata: Record<string, unknown>;
  maxBytes: number;
}): number {
  const { metadata, maxBytes } = args;
  const size = Number(metadata.size);
  if (!Number.isFinite(size) || !Number.isInteger(size)) {
    throw new HttpsError("failed-precondition", "Encrypted session body has an invalid size.");
  }
  if (size < 1 || size > maxBytes) {
    throw new HttpsError("resource-exhausted", "Encrypted session body exceeds the configured upload limit.");
  }
  if (metadata.contentType !== "application/octet-stream") {
    throw new HttpsError("failed-precondition", "Encrypted session body has an invalid content type.");
  }
  return size;
}

export function callableDate(value: unknown): string | undefined {
  if (value instanceof Timestamp) {
    return value.toDate().toISOString();
  }
  if (value instanceof Date) {
    return value.toISOString();
  }
  if (typeof value === "string") {
    return value;
  }
  return undefined;
}

export function serializeUsageForCallable(
  documentID: string,
  data: FirebaseFirestore.DocumentData,
): Record<string, unknown> {
  const provider = typeof data.provider === "string" ? data.provider : "unknown";
  const startTime = callableDate(data.startTime) ?? new Date(0).toISOString();
  const endTime = callableDate(data.endTime) ?? startTime;
  return stripUndefinedObject({
    id: typeof data.id === "string" ? data.id : documentID,
    provider,
    sessionId: typeof data.sessionId === "string" ? data.sessionId : "",
    projectName: typeof data.projectName === "string" ? data.projectName : "",
    model: typeof data.model === "string" ? data.model : "unknown",
    inputTokens: typeof data.inputTokens === "number" ? data.inputTokens : 0,
    outputTokens: typeof data.outputTokens === "number" ? data.outputTokens : 0,
    cacheCreationTokens: typeof data.cacheCreationTokens === "number" ? data.cacheCreationTokens : 0,
    cacheReadTokens: typeof data.cacheReadTokens === "number" ? data.cacheReadTokens : 0,
    reasoningTokens: typeof data.reasoningTokens === "number" ? data.reasoningTokens : 0,
    totalTokens: typeof data.totalTokens === "number" ? data.totalTokens : 0,
    cost: typeof data.cost === "number" ? data.cost : 0,
    startTime,
    endTime,
    createdAt: callableDate(data.createdAt) ?? startTime,
    usageSource: typeof data.usageSource === "string" ? data.usageSource : "provider_log",
    sourceDeviceId: typeof data.deviceId === "string" ? data.deviceId : undefined,
    sourceDeviceName: typeof data.deviceName === "string" ? data.deviceName : undefined,
    isRemote: true,
    providerID: typeof data.providerID === "string" ? data.providerID : provider,
    providerAccountID: typeof data.providerAccountID === "string" ? data.providerAccountID : undefined,
    providerAccountLabel: typeof data.providerAccountLabel === "string" ? data.providerAccountLabel : undefined,
    providerAccountSource: typeof data.providerAccountSource === "string" ? data.providerAccountSource : undefined,
    provenanceMethod: "cloud_sync",
    provenanceConfidence: "exact",
    estimatorVersion: "",
  });
}

export async function writeHermesAuditEvent(
  uid: string,
  event: Omit<HermesConnectionAuditEventDoc, "id" | "observedAt" | "schemaVersion" | "expireAt">,
): Promise<void> {
  const id = `${Date.now()}_${randomBytes(6).toString("hex")}`;
  const expireAt = Timestamp.fromMillis(Date.now() + HERMES_PAIRING_AUDIT_TTL_MS);
  const doc: HermesConnectionAuditEventDoc = {
    id,
    ...event,
    observedAt: nowISO(),
    schemaVersion: HERMES_SCHEMA_VERSION,
    expireAt,
  };
  await db.doc(`users/${uid}/hermes_audit_events/${id}`).set(stripUndefinedObject(doc));
}

export async function writePiAgentAuditEvent(
  uid: string,
  event: Omit<PiAgentConnectionAuditEventDoc, "id" | "observedAt" | "schemaVersion" | "expireAt">,
): Promise<void> {
  const id = `${Date.now()}_${randomBytes(6).toString("hex")}`;
  const expireAt = Timestamp.fromMillis(Date.now() + PI_AGENT_PAIRING_AUDIT_TTL_MS);
  const doc: PiAgentConnectionAuditEventDoc = {
    id,
    ...event,
    observedAt: nowISO(),
    schemaVersion: PI_AGENT_SCHEMA_VERSION,
    expireAt,
  };
  await db.doc(`users/${uid}/pi_agent_audit_events/${id}`).set(stripUndefinedObject(doc));
}

export function accountIDFor(provider: string, requestedAccountID?: string): string {
  const raw = requestedAccountID?.trim() || `${provider}_default`;
  const safe = raw
    .toLowerCase()
    .replace(/[^a-z0-9_-]/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "");
  if (!safe) {
    throw new Error("invalid-argument: accountID must contain letters or numbers.");
  }
  return safe;
}

export function connectionDocFromAccount(account: ProviderAccountDoc): ProviderConnectionDoc {
  assertProvider(account.providerID);
  return {
    provider: account.providerID,
    status: account.status === "disabled" || account.status === "deleted" ? "disconnected" : account.status,
    lastValidatedAt: account.lastValidatedAt,
    lastRefreshAt: account.lastRefreshAt,
    lastErrorCode: account.lastErrorCode,
    credentialKind: account.credentialKind,
    redactedLabel: account.redactedLabel,
    schemaVersion: CONNECTION_SCHEMA_VERSION,
  };
}

export function assertHostedProvider(provider: string): asserts provider is Provider {
  assertProvider(provider);
  if (!HOSTED_QUOTA_PROVIDERS.has(provider)) {
    throw new HttpsError(
      "invalid-argument",
      `Hosted quota sync is currently available for ${Array.from(HOSTED_QUOTA_PROVIDERS).join(", ")} only.`,
    );
  }
}

export function hostedProviderLabel(provider: string): string {
  switch (provider) {
    case "codex":
      return "Codex";
    case "claude-code":
      return "Claude Code";
    case "kimi":
      return "Kimi";
    case "antigravity":
      return "Antigravity";
    default:
      return provider;
  }
}

export function hostedCredentialKind(provider: string): CredentialKind {
  switch (provider) {
    case "codex":
    case "claude-code":
    case "antigravity":
      return "session";
    default:
      return "bearer";
  }
}

export function assertSelfHostedProvider(provider: string): asserts provider is Provider {
  assertProvider(provider);
  if (!SELF_HOSTED_QUOTA_PROVIDERS.has(provider)) {
    throw new HttpsError(
      "invalid-argument",
      `Self-hosted quota sync is available for ${Array.from(SELF_HOSTED_QUOTA_PROVIDERS).join(", ")}.`,
    );
  }
}

export async function assertActiveHostedQuotaEntitlement(uid: string): Promise<void> {
  await assertCloudFeatureNotSuspended(db, uid, "hosted_quota");
  const [hostedSnap, proSnap] = await Promise.all([
    db.doc(`users/${uid}/entitlements/hosted_quota_sync`).get(),
    db.doc(`users/${uid}/entitlements/${BURNBAR_PRO_ENTITLEMENT_ID}`).get(),
  ]);
  if (isActiveHostedQuotaEntitlement(hostedSnap.data())) return;
  if (isActivePremiumEntitlement(proSnap.data())) return;
  throw new HttpsError("permission-denied", "Hosted Quota Sync or BurnBar Pro subscription required.");
}

export async function assertActiveBurnBarProEntitlement(uid: string): Promise<void> {
  await assertCloudFeatureNotSuspended(db, uid, "burnbar_cloud");
  const [proSnap, hostedSnap] = await Promise.all([
    db.doc(`users/${uid}/entitlements/${BURNBAR_PRO_ENTITLEMENT_ID}`).get(),
    db.doc(`users/${uid}/entitlements/hosted_quota_sync`).get(),
  ]);
  if (isActivePremiumEntitlement(proSnap.data())) return;
  if (isActivePremiumEntitlement(hostedSnap.data())) return;
  throw new HttpsError(
    "permission-denied",
    "BurnBar Pro is required for hosted LLM, encrypted session-log backup, and cloud search.",
  );
}

export async function assertActiveBurnBarCloudProEntitlement(uid: string): Promise<void> {
  await assertCloudFeatureNotSuspended(db, uid, "burnbar_cloud_pro");
  const proMaxSnap = await db.doc(`users/${uid}/entitlements/${BURNBAR_PRO_MAX_ENTITLEMENT_ID}`).get();
  if (isActiveBurnBarCloudProEntitlement(proMaxSnap.data())) return;
  throw new HttpsError("permission-denied", "BurnBar Cloud Pro is required for Floo and hosted Agent Control.");
}

/**
 * Ultra gate. Ultra mirrors proMax (the reconciler dual-writes burnbar_pro_max),
 * so the Cloud Pro surface stays suspendable; we additionally read the
 * burnbar_ultra source doc for the 10x Pensieve limits. Throws if not Ultra.
 */
export async function assertActiveBurnBarUltraEntitlement(uid: string): Promise<void> {
  await assertCloudFeatureNotSuspended(db, uid, "burnbar_cloud_pro");
  const ultraSnap = await db.doc(`users/${uid}/entitlements/${BURNBAR_ULTRA_ENTITLEMENT_ID}`).get();
  if (isActiveBurnBarUltraEntitlement(ultraSnap.data())) return;
  throw new HttpsError("permission-denied", "BurnBar Ultra is required for this capability.");
}

const BURNBAR_CLOUD_PRO_PRODUCT_ALIASES = new Set([
  "com.openburnbar.proMax.v2.monthly",
  "com.openburnbar.proMax.annual",
  "com.openburnbar.promax.v2.monthly",
  "com.openburnbar.promax.annual",
  "com.openburnbar.proMax.bundle.monthly",
]);

export function isActiveHostedQuotaEntitlement(raw: Record<string, unknown> | undefined): boolean {
  if (!raw || raw.active !== true) return false;
  if (raw.productID !== getConfig().hostedQuotaProductID) return false;
  const expiry = entitlementExpiryMillis(raw);
  return Number.isFinite(expiry) && expiry > Date.now();
}

export function isActivePremiumEntitlement(raw: Record<string, unknown> | undefined): boolean {
  if (!raw || raw.active !== true) return false;
  const productID = typeof raw.productID === "string" ? raw.productID : "";
  if (
    productID !== getConfig().hostedQuotaProductID &&
    productID !== getConfig().burnBarProProductID &&
    productID !== getConfig().burnBarProAnnualProductID &&
    productID !== getConfig().burnBarProMaxProductID &&
    productID !== getConfig().burnBarProMaxAnnualProductID &&
    productID !== getConfig().googlePlaySubscriptionProductID &&
    productID !== getConfig().googlePlayCloudMonthlyProductID &&
    productID !== getConfig().googlePlayCloudAnnualProductID &&
    productID !== getConfig().googlePlayCloudProMonthlyProductID &&
    productID !== getConfig().googlePlayCloudProAnnualProductID &&
    !BURNBAR_CLOUD_PRO_PRODUCT_ALIASES.has(productID)
  ) {
    return false;
  }
  const expiry = entitlementExpiryMillis(raw);
  return Number.isFinite(expiry) && expiry > Date.now();
}

export function isActiveBurnBarCloudProEntitlement(raw: Record<string, unknown> | undefined): boolean {
  if (!raw || raw.active !== true) return false;
  const productID = typeof raw.productID === "string" ? raw.productID : "";
  const cfg = getConfig();
  if (
    productID !== cfg.burnBarProMaxProductID &&
    productID !== cfg.burnBarProMaxAnnualProductID &&
    productID !== cfg.googlePlayCloudProMonthlyProductID &&
    productID !== cfg.googlePlayCloudProAnnualProductID &&
    !BURNBAR_CLOUD_PRO_PRODUCT_ALIASES.has(productID)
  ) {
    return false;
  }
  const expiry = entitlementExpiryMillis(raw);
  return Number.isFinite(expiry) && expiry > Date.now();
}

/**
 * Strict Ultra check. The burnbar_ultra source doc carries the Ultra SKU
 * productID (the proMax MIRROR carries it too, but the mirror lives at a
 * different doc path). Accepts Apple + Google Play Ultra product ids.
 */
export function isActiveBurnBarUltraEntitlement(raw: Record<string, unknown> | undefined): boolean {
  if (!raw || raw.active !== true) return false;
  const productID = typeof raw.productID === "string" ? raw.productID : "";
  const cfg = getConfig();
  if (
    productID !== cfg.burnBarUltraProductID &&
    productID !== cfg.burnBarUltraAnnualProductID &&
    productID !== cfg.googlePlayUltraMonthlyProductID &&
    productID !== cfg.googlePlayUltraAnnualProductID
  ) {
    return false;
  }
  const expiry = entitlementExpiryMillis(raw);
  return Number.isFinite(expiry) && expiry > Date.now();
}

export function entitlementExpiryMillis(raw: Record<string, unknown>): number {
  const expireAt = raw.expireAt;
  if (expireAt instanceof Timestamp) {
    return expireAt.toMillis();
  }
  if (isTimestampWithToMillis(expireAt)) {
    return expireAt.toMillis();
  }
  if (raw.expiresAt) {
    const parsed = Date.parse(String(raw.expiresAt));
    return Number.isFinite(parsed) ? parsed : 0;
  }
  return 0;
}

export function burnBarProFeatures(): Record<string, boolean> {
  return {
    hostedQuota: true,
    hostedLLM: true,
    encryptedSessionLogBackup: true,
    cloudConversationSearch: true,
  };
}

export function burnBarProMaxFeatures(): Record<string, boolean> {
  return {
    ...burnBarProFeatures(),
    floo: true,
    agentControl: true,
  };
}

export async function writeBurnBarProEntitlement(args: {
  uid: string;
  productID: string;
  expiresAtMillis: number;
  source: string;
  platform: "ios" | "android" | "macos" | "web" | "stripe";
  entitlementID?: string;
  externalSubscriptionID?: string;
  externalCustomerID?: string;
  purchaseTokenHash?: string;
  rawStatus?: string;
  environment?: string;
  activeOverride?: boolean;
}): Promise<Record<string, unknown>> {
  const now = nowISO();
  const active = args.activeOverride ?? (Number.isFinite(args.expiresAtMillis) && args.expiresAtMillis > Date.now());
  const expiresAt = new Date(args.expiresAtMillis).toISOString();
  const entitlementID = args.entitlementID || BURNBAR_PRO_ENTITLEMENT_ID;
  const doc = stripUndefinedObject({
    id: entitlementID,
    active,
    productID: args.productID,
    entitlementFamily: entitlementID,
    features: entitlementID === BURNBAR_PRO_MAX_ENTITLEMENT_ID ? burnBarProMaxFeatures() : burnBarProFeatures(),
    expiresAt,
    expireAt: Timestamp.fromMillis(args.expiresAtMillis),
    source: args.source,
    platform: args.platform,
    externalSubscriptionID: args.externalSubscriptionID,
    externalCustomerID: args.externalCustomerID,
    purchaseTokenHash: args.purchaseTokenHash,
    rawStatus: args.rawStatus,
    environment: args.environment,
    verificationVersion: 1,
    schemaVersion: 1,
    lastVerifiedAt: now,
    updatedAt: now,
  });
  await db.doc(`users/${args.uid}/entitlements/${entitlementID}`).set(doc, { merge: true });
  if (entitlementID === BURNBAR_PRO_MAX_ENTITLEMENT_ID && active) {
    await ensureCloudProAllowanceLedger(args.uid);
  }
  return doc;
}

async function ensureCloudProAllowanceLedger(uid: string): Promise<void> {
  const allowanceConfig = await loadCloudProAllowanceConfig();
  await db.doc(allowanceDocPath(uid, monthKeyForDate(new Date()))).set(
    {
      includedHostedActions: allowanceConfig.includedHostedActionsMonthly,
      includedRelayGB: allowanceConfig.includedRelayGBMonthly,
      monthlyHostedActionCap: allowanceConfig.monthlyHostedActionCap,
      monthlyRelayGBCap: allowanceConfig.monthlyRelayGBCap,
      updatedAt: Timestamp.now(),
      schemaVersion: CLOUD_PRO_ALLOWANCE_SCHEMA_VERSION,
    },
    { merge: true },
  );
}

export function requireConfiguredStripe(): Stripe {
  const cfg = getConfig();
  const secretKey = STRIPE_SECRET_KEY.value() || cfg.stripeSecretKey;
  if (!secretKey || !(cfg.stripeBurnBarCloudMonthlyPriceID || cfg.stripeBurnBarProPriceID)) {
    throw new HttpsError("failed-precondition", "Stripe BurnBar Pro checkout is not configured.");
  }
  return new Stripe(secretKey);
}

export function requireConfiguredStripeWebhookSecret(): string {
  const secret = STRIPE_WEBHOOK_SECRET.value() || getConfig().stripeWebhookSecret;
  if (!secret) {
    throw new HttpsError("failed-precondition", "Stripe BurnBar Pro webhook is not configured.");
  }
  return secret;
}

export function boundedHttpsURL(raw: unknown, fieldName: string): string {
  const value = boundedTrimmedString(raw, fieldName, 2048, true);
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    throw new HttpsError("invalid-argument", `${fieldName} must be a valid URL.`);
  }
  if (url.protocol !== "https:" && !url.hostname.includes("localhost")) {
    throw new HttpsError("invalid-argument", `${fieldName} must be HTTPS.`);
  }
  return url.toString();
}

export async function getOrCreateStripeCustomer(uid: string, stripe: Stripe): Promise<string> {
  const ref = db.doc(`users/${uid}/billing/stripe`);
  const existing = await ref.get();
  const existingID = existing.get("customerID");
  if (typeof existingID === "string" && existingID.startsWith("cus_")) {
    return existingID;
  }

  const user = await auth.getUser(uid).catch(() => undefined);
  const customer = await stripeWithResilience("customers.create", () =>
    stripe.customers.create({
      email: user?.email ?? undefined,
      name: user?.displayName ?? undefined,
      metadata: { firebaseUID: uid },
    }),
  );
  await ref.set(
    {
      uid,
      customerID: customer.id,
      createdAt: Timestamp.now(),
      updatedAt: Timestamp.now(),
      schemaVersion: 1,
    },
    { merge: true },
  );
  await db.doc(`stripe_customers/${customer.id}`).set(
    {
      uid,
      customerID: customer.id,
      createdAt: Timestamp.now(),
      updatedAt: Timestamp.now(),
      schemaVersion: 1,
    },
    { merge: true },
  );
  return customer.id;
}

export function googlePlayLineItemForProduct(
  purchase: Record<string, unknown>,
  productID: string,
): Record<string, unknown> | undefined {
  const lineItems = Array.isArray(purchase.lineItems)
    ? purchase.lineItems.filter((item): item is Record<string, unknown> => !!item && typeof item === "object")
    : [];
  return lineItems.find((item) => item.productId === productID);
}

export function googlePlayExpiryMillis(lineItem: Record<string, unknown> | undefined): number {
  const expiryTime = lineItem?.expiryTime;
  if (typeof expiryTime === "string") {
    const parsed = Date.parse(expiryTime);
    if (Number.isFinite(parsed)) return parsed;
  }
  throw new HttpsError("failed-precondition", "Google Play did not return an expiry for this subscription.");
}

export async function applyStripeCheckoutSession(stripe: Stripe, session: Stripe.Checkout.Session): Promise<void> {
  const uid = session.metadata?.firebaseUID ?? session.client_reference_id ?? undefined;
  if (!uid) return;
  if (session.metadata?.topUpKind) {
    if (session.payment_status !== "paid") return;
    await creditCloudProTopUp({
      uid,
      kind: stripeTopUpKind(session.metadata.topUpKind),
      source: "stripe_checkout",
      externalPaymentID: session.id,
    });
    return;
  }
  let subscription: Stripe.Subscription | undefined;
  if (typeof session.subscription === "string") {
    subscription = await stripeWithResilience("subscriptions.retrieve", () =>
      stripe.subscriptions.retrieve(session.subscription as string),
    );
  } else if (session.subscription && typeof session.subscription === "object") {
    subscription = session.subscription;
  }
  if (subscription) {
    await applyStripeSubscription(stripe, subscription, uid);
  }
}

export async function creditCloudProTopUp(args: {
  uid: string;
  kind: CloudProTopUpKind;
  source: string;
  externalPaymentID: string;
  quantity?: number;
}): Promise<{ credited: boolean; monthKey: string; units: number; kind: CloudProTopUpKind }> {
  await assertActiveBurnBarCloudProEntitlement(args.uid);
  const monthKey = monthKeyForDate(new Date());
  const allowanceRef = db.doc(allowanceDocPath(args.uid, monthKey));
  const topUpRef = allowanceRef
    .collection("topups")
    .doc(requiredIdentifier(`${args.source}_${args.externalPaymentID}`, "externalPaymentID"));
  const allowanceConfig = await loadCloudProAllowanceConfig();
  const topUp = unitsForCloudProTopUp(args.kind, args.quantity, allowanceConfig);

  return db.runTransaction(async (transaction) => {
    const existing = await transaction.get(topUpRef);
    if (existing.exists) {
      return { credited: false, monthKey, units: topUp.units, kind: args.kind };
    }

    const incrementField = topUp.meter === "relay_gb" ? "topupRelayGBPurchased" : "topupActionsPurchased";
    const now = Timestamp.now();
    transaction.set(
      allowanceRef,
      {
        includedHostedActions: allowanceConfig.includedHostedActionsMonthly,
        includedRelayGB: allowanceConfig.includedRelayGBMonthly,
        monthlyHostedActionCap: allowanceConfig.monthlyHostedActionCap,
        monthlyRelayGBCap: allowanceConfig.monthlyRelayGBCap,
        [incrementField]: FieldValue.increment(topUp.units),
        updatedAt: now,
        schemaVersion: CLOUD_PRO_ALLOWANCE_SCHEMA_VERSION,
      },
      { merge: true },
    );
    transaction.set(topUpRef, {
      uid: args.uid,
      monthKey,
      kind: args.kind,
      meter: topUp.meter,
      units: topUp.units,
      source: args.source,
      externalPaymentID: args.externalPaymentID,
      quantity: args.quantity ?? 1,
      creditedAt: now,
      schemaVersion: CLOUD_PRO_ALLOWANCE_SCHEMA_VERSION,
    });
    return { credited: true, monthKey, units: topUp.units, kind: args.kind };
  });
}

function stripeTopUpKind(raw: string): CloudProTopUpKind {
  if (raw === "agent_control_actions_100" || raw === "floo_relay_50gb") return raw;
  throw new HttpsError("invalid-argument", "Unsupported Stripe top-up kind.");
}

export async function applyStripeSubscription(
  stripe: Stripe,
  subscription: Stripe.Subscription,
  uidOverride?: string,
): Promise<void> {
  const uid = uidOverride ?? (await uidForStripeSubscription(subscription));
  if (!uid) return;

  const customerID = stripeCustomerID(subscription.customer);
  const expiresAtMillis = stripeSubscriptionPeriodEndMillis(subscription);
  const status = String(subscription.status ?? "unknown");
  const active = STRIPE_ACTIVE_STATES.has(status) && expiresAtMillis > Date.now();
  const entitlementID =
    subscription.metadata?.entitlementID === BURNBAR_PRO_MAX_ENTITLEMENT_ID
      ? BURNBAR_PRO_MAX_ENTITLEMENT_ID
      : BURNBAR_PRO_ENTITLEMENT_ID;
  const productID = stripeSubscriptionProductID(subscription, entitlementID);

  await writeBurnBarProEntitlement({
    uid,
    productID,
    expiresAtMillis,
    source: "stripe_webhook_verified",
    platform: "stripe",
    entitlementID,
    externalSubscriptionID: subscription.id,
    externalCustomerID: customerID,
    rawStatus: status,
    environment: "Production",
    activeOverride: active,
  });

  if (customerID) {
    await db.doc(`users/${uid}/billing/stripe`).set(
      {
        uid,
        customerID,
        subscriptionID: subscription.id,
        subscriptionStatus: status,
        currentPeriodEnd: new Date(expiresAtMillis).toISOString(),
        updatedAt: Timestamp.now(),
        schemaVersion: 1,
      },
      { merge: true },
    );
    await db.doc(`stripe_customers/${customerID}`).set(
      {
        uid,
        customerID,
        subscriptionID: subscription.id,
        subscriptionStatus: status,
        updatedAt: Timestamp.now(),
        schemaVersion: 1,
      },
      { merge: true },
    );
  }
}

function stripeSubscriptionProductID(subscription: Stripe.Subscription, entitlementID: string): string {
  const cfg = getConfig();
  const priceIDs = new Set(
    subscription.items?.data
      ?.map((item) => item.price?.id)
      .filter((priceID): priceID is string => typeof priceID === "string") || [],
  );
  if (cfg.stripeBurnBarCloudAnnualPriceID && priceIDs.has(cfg.stripeBurnBarCloudAnnualPriceID)) {
    return cfg.burnBarProAnnualProductID;
  }
  if (cfg.stripeBurnBarCloudProMonthlyPriceID && priceIDs.has(cfg.stripeBurnBarCloudProMonthlyPriceID)) {
    return cfg.burnBarProMaxProductID;
  }
  if (cfg.stripeBurnBarCloudProAnnualPriceID && priceIDs.has(cfg.stripeBurnBarCloudProAnnualPriceID)) {
    return cfg.burnBarProMaxAnnualProductID;
  }
  return entitlementID === BURNBAR_PRO_MAX_ENTITLEMENT_ID ? cfg.burnBarProMaxProductID : cfg.burnBarProProductID;
}

export async function uidForStripeSubscription(subscription: Stripe.Subscription): Promise<string | undefined> {
  const metadataUID = subscription.metadata?.firebaseUID;
  if (metadataUID) return metadataUID;
  const customerID = stripeCustomerID(subscription.customer);
  if (!customerID) return undefined;
  const snap = await db.doc(`stripe_customers/${customerID}`).get();
  const uid = snap.get("uid");
  return typeof uid === "string" ? uid : undefined;
}

export function stripeCustomerID(customer: unknown): string | undefined {
  if (typeof customer === "string") return customer;
  if (customer && typeof customer === "object" && "id" in customer && typeof customer.id === "string") {
    return customer.id;
  }
  return undefined;
}

export function stripeSubscriptionPeriodEndMillis(subscription: Stripe.Subscription): number {
  const raw = jsonObject(subscription);
  const direct = raw.current_period_end;
  if (typeof direct === "number") return direct * 1000;
  const items = recordOrUndefined(raw.items);
  const firstItem = Array.isArray(items?.data) ? recordOrUndefined(items.data[0]) : undefined;
  const itemEnd = firstItem?.current_period_end;
  if (typeof itemEnd === "number") return itemEnd * 1000;
  return Date.now() - 1;
}

export function normalizeHostedCredential(provider: string, raw: unknown): string {
  const credential = boundedTrimmedString(raw, "credential", getConfig().maxCredentialLength, true);
  if (!credential) {
    throw new HttpsError("invalid-argument", "credential is required.");
  }
  try {
    const candidate = credential.startsWith("{") ? credential : Buffer.from(credential, "base64").toString("utf8");
    JSON.parse(candidate);
    return credential;
  } catch {
    throw new HttpsError(
      "invalid-argument",
      "Codex hosted credentials must be ~/.codex/auth.json JSON or base64 JSON.",
    );
  }
}

export function safeSnapshotSourceID(raw: unknown): string {
  return (
    (typeof raw === "string" ? raw : "self-hosted-runner")
      .toLowerCase()
      .replace(/[^a-z0-9_-]/g, "-")
      .replace(/-+/g, "-")
      .replace(/^-|-$/g, "") || "self-hosted-runner"
  );
}

export function sanitizeUploadedQuotaSnapshot(
  account: ProviderAccountDoc,
  raw: Record<string, unknown>,
): QuotaSnapshotDoc {
  const now = nowISO();
  const bucketsRaw = Array.isArray(raw.buckets) ? raw.buckets : [];
  const buckets = bucketsRaw.slice(0, 16).flatMap((item): QuotaSnapshotDoc["buckets"] => {
    const b = recordOrUndefined(item);
    if (!b) return [];
    const name = boundedTrimmedString(b.name, "bucket.name", 80);
    if (!name) return [];
    const used = Number(b.used);
    const limit = Number(b.limit);
    const remaining = Number(b.remaining);
    if (!Number.isFinite(used) || !Number.isFinite(limit) || !Number.isFinite(remaining)) {
      return [];
    }
    const bucket: QuotaSnapshotDoc["buckets"][number] = {
      name,
      used,
      limit,
      remaining,
      ...(boundedTrimmedString(b.window, "bucket.window", 64)
        ? { window: boundedTrimmedString(b.window, "bucket.window", 64) }
        : {}),
      ...(recordOrUndefined(b.meta)
        ? {
            meta: Object.fromEntries(
              Object.entries(recordOrUndefined(b.meta) ?? {})
                .filter(
                  ([key, value]) =>
                    /^[a-zA-Z0-9_.-]{1,64}$/.test(key) &&
                    !isSecretLikeMetadataKey(key) &&
                    (typeof value === "string" || typeof value === "number" || typeof value === "boolean"),
                )
                .slice(0, 16),
            ),
          }
        : {}),
    };
    return [bucket];
  });
  if (buckets.length === 0) {
    throw new HttpsError("invalid-argument", "At least one quota bucket is required.");
  }
  const confidence =
    raw.confidence === "high" || raw.confidence === "medium" || raw.confidence === "low" || raw.confidence === "stale"
      ? raw.confidence
      : "high";
  assertProvider(account.providerID);
  const snapshot: QuotaSnapshotDoc = {
    sourceKind: "provider",
    sourceId: safeSnapshotSourceID(raw.sourceId),
    provider: account.providerID,
    providerID: account.providerID,
    accountID: account.id,
    accountLabel: account.label,
    accountStorageScope: account.storageScope,
    fetchedAt:
      typeof raw.fetchedAt === "string" && Number.isFinite(Date.parse(raw.fetchedAt))
        ? new Date(Date.parse(raw.fetchedAt)).toISOString()
        : now,
    source: boundedTrimmedString(raw.source, "source", 160) ?? "Self-hosted quota runner",
    confidence,
    managementURL:
      typeof raw.managementURL === "string" && raw.managementURL.startsWith("https://")
        ? raw.managementURL.slice(0, 2048)
        : undefined,
    statusMessage: boundedTrimmedString(raw.statusMessage, "statusMessage", 240),
    buckets,
    schemaVersion: 2,
    updatedAt: now,
  };
  return snapshot;
}

export function isSecretLikeMetadataKey(key: string): boolean {
  const lower = key.toLowerCase();
  return (
    lower.includes("token") ||
    lower.includes("secret") ||
    lower.includes("authorization") ||
    lower.includes("credential") ||
    lower.includes("cookie") ||
    lower.includes("password")
  );
}

export async function writePrivateSecretRef(
  uid: string,
  accountID: string,
  provider: Provider,
  secretVersionName: string,
  createdAt: string,
  updatedAt: string,
): Promise<void> {
  const refDoc: ProviderAccountSecretRefDoc = {
    uid,
    providerID: provider,
    accountID,
    secretVersionName,
    createdAt,
    updatedAt,
  };
  await db.doc(providerAccountSecretRefPath(uid, accountID)).set(refDoc, { merge: true });
}

export async function connectProviderAccountInternal(params: {
  uid: string;
  provider: Provider;
  credential: string;
  label?: string;
  accountID?: string;
  isDefault?: boolean;
  sourceDeviceID?: string;
  deviceDisplayName?: string;
  endpointProfileID?: string;
  region?: ProviderAccountConnectContext["region"];
  tokenPlanTier?: ProviderAccountConnectContext["tokenPlanTier"];
  tokenPlanBillingCycle?: ProviderAccountConnectContext["tokenPlanBillingCycle"];
  authMethodID?: string;
}): Promise<ProviderAccountDoc> {
  const { uid, provider, credential } = params;
  const accountID = accountIDFor(provider, params.accountID);
  const label = params.label?.trim() || "Default";
  const accountContext: ProviderAccountConnectContext = {
    endpointProfileID: params.endpointProfileID,
    region: params.region,
    tokenPlanTier: params.tokenPlanTier,
    tokenPlanBillingCycle: params.tokenPlanBillingCycle,
    authMethodID: params.authMethodID,
  };

  const adapter = backendAdapterFor(provider);
  if (!adapter) {
    if (provider === "codex") {
      throw new HttpsError(
        "failed-precondition",
        "Codex is a runner-based provider and doesn't support backend credential connections. Connect it through hosted quota sync or the OpenBurnBar Mac app instead.",
      );
    }
    throw new HttpsError(
      "unimplemented",
      `OpenBurnBar doesn't have a server-side connector for ${provider} yet. Connect it on the macOS app, or pick a supported provider (OpenAI, Factory, Cursor, Z.ai, MiniMax, Kimi).`,
    );
  }

  const testResult = await adapter.testCredential(credential, accountContext);
  if (!testResult.valid) {
    const message = testResult.errorMessage?.trim() || "We couldn't validate that credential.";
    const detail = testResult.errorCode ? `${message} (${testResult.errorCode})` : message;
    throw new HttpsError("invalid-argument", detail, {
      provider,
      errorCode: testResult.errorCode,
    });
  }

  const now = nowISO();
  const existing = await db.doc(`users/${uid}/provider_accounts/${accountID}`).get();
  const secretVersionName = await storeCredential(uid, provider, credential, accountID);
  await writePrivateSecretRef(
    uid,
    accountID,
    provider,
    secretVersionName,
    existing.exists ? (optionalStringField(existing.get("createdAt")) ?? now) : now,
    now,
  );

  const accountDoc: ProviderAccountDoc = {
    id: accountID,
    providerID: provider,
    label,
    identityHint: undefined,
    status: "connected",
    credentialKind: testResult.credentialKind,
    storageScope: "cloud_refreshable",
    redactedLabel: testResult.redactedLabel,
    sourceDeviceID: boundedTrimmedString(params.sourceDeviceID, "sourceDeviceID", 128),
    linkedSwitcherProfileID: undefined,
    endpointProfileID: params.endpointProfileID,
    region: params.region,
    tokenPlanTier: params.tokenPlanTier,
    tokenPlanBillingCycle: params.tokenPlanBillingCycle,
    authMethodID: params.authMethodID,
    isDefault: params.isDefault ?? accountID.endsWith("_default"),
    sortKey: accountID.endsWith("_default") ? 0 : Date.now(),
    lastValidatedAt: now,
    lastRefreshAt: now,
    lastErrorCode: undefined,
    schemaVersion: ACCOUNT_SCHEMA_VERSION,
    createdAt: existing.exists ? (optionalStringField(existing.get("createdAt")) ?? now) : now,
    updatedAt: now,
  };

  await db.runTransaction(async (tx) => {
    const accountRef = db.doc(`users/${uid}/provider_accounts/${accountID}`);
    tx.set(accountRef, accountDoc, { merge: true });

    if (accountDoc.isDefault) {
      const legacyRef = db.doc(`users/${uid}/provider_connections/${provider}`);
      tx.set(legacyRef, connectionDocFromAccount(accountDoc), { merge: true });
    }
  });

  if (accountDoc.sourceDeviceID) {
    await upsertDeviceLink({
      db,
      uid,
      accountID,
      deviceID: accountDoc.sourceDeviceID,
      deviceDisplayName: params.deviceDisplayName ?? accountDoc.sourceDeviceID,
      capability: "owner",
    });
  }

  try {
    await refreshUserProviderAccountQuota(db, uid, accountID);
    if (accountDoc.isDefault) {
      await refreshUserProviderQuota(db, uid, provider);
    }
  } catch (quotaErr) {
    logError({
      event: "callable_warn",
      message: `Initial quota refresh failed for ${uid}/${accountID}:`,
      detail: String(quotaErr),
    });
  }

  return accountDoc;
}

/**
 * Enforce rate limit for refreshProviderQuota per user+provider.
 * Uses Firestore as a lightweight TTL store.
 */
export async function checkRefreshRateLimit(db: Firestore, uid: string, provider: string): Promise<void> {
  const { refreshRateLimitSeconds } = getConfig();
  const ref = db.doc(`users/${uid}/_rate_limits/refresh_${provider}`);
  const snap = await ref.get();
  if (snap.exists) {
    const ts = snap.get("lastRefreshAt");
    if (isTimestampWithToMillis(ts)) {
      const elapsed = Date.now() - ts.toMillis();
      if (elapsed < refreshRateLimitSeconds * 1000) {
        throw new Error(
          `Rate limited: wait ${Math.ceil(
            (refreshRateLimitSeconds * 1000 - elapsed) / 1000,
          )}s before refreshing ${provider}.`,
        );
      }
    }
  }
  await ref.set({ lastRefreshAt: Timestamp.now() }, { merge: true });
}

export async function checkHermesRateLimit(uid: string, action: string, windowSeconds: number): Promise<void> {
  const ref = db.doc(`users/${uid}/_rate_limits/hermes_${action}`);
  const snap = await ref.get();
  if (snap.exists) {
    const ts = snap.get("lastAt");
    if (isTimestampWithToMillis(ts)) {
      const elapsed = Date.now() - ts.toMillis();
      if (elapsed < windowSeconds * 1000) {
        throw new HttpsError(
          "resource-exhausted",
          `Please wait ${Math.ceil((windowSeconds * 1000 - elapsed) / 1000)}s before retrying.`,
        );
      }
    }
  }
  await ref.set({ lastAt: Timestamp.now() }, { merge: true });
}

export async function checkPiAgentRateLimit(uid: string, action: string, windowSeconds: number): Promise<void> {
  const ref = db.doc(`users/${uid}/_rate_limits/pi_agent_${action}`);
  const snap = await ref.get();
  if (snap.exists) {
    const ts = snap.get("lastAt");
    if (isTimestampWithToMillis(ts)) {
      const elapsed = Date.now() - ts.toMillis();
      if (elapsed < windowSeconds * 1000) {
        throw new HttpsError(
          "resource-exhausted",
          `Please wait ${Math.ceil((windowSeconds * 1000 - elapsed) / 1000)}s before retrying.`,
        );
      }
    }
  }
  await ref.set({ lastAt: Timestamp.now() }, { merge: true });
}

HOSTED_QUOTA_PROVIDERS.add("claude-code");
