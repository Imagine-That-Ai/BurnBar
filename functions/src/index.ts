/**
 * @fileoverview OpenBurnBar Cloud Functions v2 — main entry point.
 *
 * Exports:
 *   Callable:
 *     - connectProviderCredential
 *     - deleteProviderCredential
 *     - refreshProviderQuota
 *     - rebuildUsageRollups
 *   Background:
 *     - onUsageWritten       (Firestore trigger)
 *     - rebuildRollups       (scheduled, every 5 min)
 *     - refreshAllProviderQuotas (scheduled, every 15 min)
 *     - refreshModelLandscapeBenchmarks (scheduled, every 24h)
 *
 * Before deploying, ensure Firebase Admin is initialized (no args needed in
 * GCP because ADC is automatic; for local emulation set GOOGLE_APPLICATION_CREDENTIALS).
 */

import { initializeApp } from "firebase-admin/app";
import { getAuth } from "firebase-admin/auth";
import { getFirestore, Timestamp, type DocumentData, type DocumentSnapshot, type QuerySnapshot, type WriteBatch } from "firebase-admin/firestore";
import { getStorage } from "firebase-admin/storage";
import { HttpsError, onCall, onRequest, type CallableRequest } from "firebase-functions/v2/https";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { defineSecret } from "firebase-functions/params";
import type { Firestore } from "firebase-admin/firestore";
import { createHash, randomBytes } from "node:crypto";
import { google } from "googleapis";
import Stripe from "stripe";

import { getConfig } from "./config.js";
import { enforceAuthAndAppCheck } from "./auth.js";
import {
  storeCredential,
  destroyCredential,
} from "./secrets.js";
import {
  providerAccountSecretRefPath,
  refreshUserProviderAccountQuota,
  refreshUserProviderQuota,
} from "./quota.js";
import { computeUserRollups, writeUserRollups } from "./rollups.js";
import { eraseUserAccount } from "./accountDeletion.js";
import {
  adoptDeviceLink,
  backfillUserDeviceLinks,
  isDeviceLinkCapability,
  revokeAllLinksForAccount,
  revokeDeviceLink,
  upsertDeviceLink,
} from "./providerAccountDeviceLinks.js";
import {
  isHermesConnectionDoc,
  pairingCodeDigest,
  parseHermesConnectionMode,
  parseHermesPlatform,
  randomPairingCode,
  safeEqualHex,
  sanitizeHermesCapabilities,
  validateHermesEndpointURL,
} from "./hermes.js";
import {
  isPiAgentConnectionDoc,
  piAgentPairingCodeDigest,
  piAgentSafeEqualHex,
  parsePiAgentConnectionMode,
  parsePiAgentPlatform,
  randomPiAgentPairingCode,
  sanitizePiAgentCapabilities,
  sanitizePiAgentInstances,
  sanitizePiAgentModels,
  validatePiAgentEndpointURL,
} from "./piAgent.js";
import { minimaxAdapter } from "./providers/minimax.js";
import { zaiAdapter } from "./providers/zai.js";
import { factoryAdapter } from "./providers/factory.js";
import { cursorAdapter } from "./providers/cursor.js";
import { openaiAdapter } from "./providers/openai.js";

import type {
  Provider,
  SUPPORTED_PROVIDERS,
  CredentialKind,
  ProviderAccountDoc,
  ProviderAccountSecretRefDoc,
  ProviderConnectionDoc,
  QuotaSnapshotDoc,
  HermesConnectionDoc,
  HermesConnectionMode,
  HermesPairingDoc,
  HermesConnectionAuditEventDoc,
  PiAgentConnectionDoc,
  PiAgentConnectionMode,
  PiAgentPairingDoc,
  PiAgentConnectionAuditEventDoc,
  RollupJobDoc,
  ProjectMemorySnapshotDoc,
  ProjectMemoryFreshness,
  CloudVaultBlobEnvelopeDoc,
} from "./types.js";

import { onUsageWritten } from "./triggers.js";
import {
  rebuildRollups,
  refreshAllProviderQuotas,
  refreshModelLandscapeBenchmarks,
} from "./scheduled.js";
import { seedAndroidDemoAccount as seedAndroidDemoAccountForUser } from "./demoSeed.js";
import { latestRouterRundown } from "./routerRundown.js";
import { HOSTED_RUNNER_SECRETS } from "./hostedRunnerConfig.js";
import { issueRemoteMcpGrantForSignedInUser } from "./remoteMcpOAuth.js";
import { revokeRemoteMcpClient as revokeRemoteMcpClientDoc } from "./remoteMcpGrant.js";
export { insightsHostedAnswer } from "./insightsHostedAnswer.js";
export { rollupIrohTransportDaily } from "./irohMonitoring.js";
export { recomputeMediaQuotaUsage } from "./mediaQuota.js";
export { rollupMediaSessionDaily } from "./mediaMonitoring.js";
export { grantMediaGrandfather, validateMediaPurchase } from "./mediaSku.js";
export { triggerVoIPCall } from "./voipPush.js";
export { evaluateMediaBudget } from "./mediaBudget.js";
export { sendVoIPOutbound } from "./apnsSender.js";
export { sendFcmOutbound } from "./fcmAndroidSender.js";

// ---------------------------------------------------------------------------
// Admin initialization
// ---------------------------------------------------------------------------
const configuredStorageBucket =
  process.env.OPENBURNBAR_STORAGE_BUCKET ||
  process.env.FIREBASE_STORAGE_BUCKET ||
  undefined;
initializeApp(configuredStorageBucket ? { storageBucket: configuredStorageBucket } : undefined);
const db = getFirestore();
const auth = getAuth();
// Allow optional fields (e.g. identityHint, sourceDeviceID) to be set to
// `undefined` directly on writes without crashing the transaction. Firestore
// otherwise rejects the entire document, which surfaces as a generic INTERNAL
// error to the iOS connect flow.
db.settings({ ignoreUndefinedProperties: true });

// ---------------------------------------------------------------------------
// Provider adapter registry
// ---------------------------------------------------------------------------
const ADAPTERS = {
  openai: openaiAdapter,
  minimax: minimaxAdapter,
  zai: zaiAdapter,
  factory: factoryAdapter,
  cursor: cursorAdapter,
} as const;

const ALLOWED_PROVIDERS = new Set<string>([
  "openai",
  "minimax",
  "zai",
  "factory",
  "cursor",
  "claude-code",
  "codex",
  "opencode",
]);

const CONNECTION_SCHEMA_VERSION = 1;
const ACCOUNT_SCHEMA_VERSION = 1;
const HERMES_SCHEMA_VERSION = 1;
const HERMES_PAIRING_TTL_MS = 10 * 60 * 1000;
const HERMES_PAIRING_AUDIT_TTL_MS = 90 * 24 * 60 * 60 * 1000;
const HERMES_MAX_FAILED_PAIRING_ATTEMPTS = 5;
const PI_AGENT_SCHEMA_VERSION = 1;
const PI_AGENT_PAIRING_TTL_MS = 10 * 60 * 1000;
const PI_AGENT_PAIRING_AUDIT_TTL_MS = 90 * 24 * 60 * 60 * 1000;
const PI_AGENT_MAX_FAILED_PAIRING_ATTEMPTS = 5;
const HOSTED_QUOTA_PROVIDERS = new Set<string>(["codex"]);
const SELF_HOSTED_QUOTA_PROVIDERS = new Set<string>(["claude-code", "codex", "opencode"]);
const BURNBAR_PRO_ENTITLEMENT_ID = "burnbar_pro";
const STRIPE_SECRET_KEY = defineSecret("STRIPE_SECRET_KEY");
const STRIPE_WEBHOOK_SECRET = defineSecret("STRIPE_WEBHOOK_SECRET");
const REMOTE_MCP_TOKEN_HMAC_SECRET = defineSecret("REMOTE_MCP_TOKEN_HMAC_SECRET");
const STRIPE_API_SECRETS = [STRIPE_SECRET_KEY];
const STRIPE_WEBHOOK_SECRETS = [STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET];
const GOOGLE_PLAY_ACTIVE_STATES = new Set<string>([
  "SUBSCRIPTION_STATE_ACTIVE",
  "SUBSCRIPTION_STATE_IN_GRACE_PERIOD",
]);
const STRIPE_ACTIVE_STATES = new Set<string>(["active", "trialing", "past_due"]);

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function assertProvider(provider: unknown): asserts provider is Provider {
  if (typeof provider !== "string" || !ALLOWED_PROVIDERS.has(provider)) {
    throw new HttpsError(
      "invalid-argument",
      `Unsupported provider "${String(provider)}". Backend connections only support: ${[...ALLOWED_PROVIDERS].join(", ")}.`
    );
  }
}

function nowISO(): string {
  return new Date().toISOString();
}

function safeIdentifier(raw: unknown, prefix: string): string {
  const value = typeof raw === "string" ? raw.trim() : "";
  const safe = value
    .toLowerCase()
    .replace(/[^a-z0-9_-]/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "");
  return safe || `${prefix}_${randomBytes(8).toString("hex")}`;
}

function requiredIdentifier(raw: unknown, fieldName: string): string {
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

function optionalTrimmedString(raw: unknown): string | undefined {
  if (typeof raw !== "string") {
    return undefined;
  }
  const value = raw.trim();
  return value.length > 0 ? value : undefined;
}

function boundedTrimmedString(
  raw: unknown,
  fieldName: string,
  maxLength: number,
  required = false
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

function stripUndefined<T extends object>(value: T): T {
  const output = {} as T;
  for (const [key, item] of Object.entries(value)) {
    if (item !== undefined) {
      (output as Record<string, unknown>)[key] = item;
    }
  }
  return output;
}

function normalizedSearchTerms(raw: string): string[] {
  const stopwords = new Set(["the", "and", "for", "with", "that", "this", "from", "how", "what", "where", "when", "why", "are", "was"]);
  return Array.from(
    new Set(
      raw
        .toLowerCase()
        .split(/[^a-z0-9]+/u)
        .map((part) => part.trim())
        .filter((part) => part.length >= 2 && !stopwords.has(part))
    )
  ).slice(0, 8);
}

function searchScore(text: string, terms: string[]): number {
  const lower = text.toLowerCase();
  return terms.reduce((score, term) => score + (lower.includes(term) ? 1 : 0), 0);
}

function sha256Hex(text: string): string {
  return createHash("sha256").update(text).digest("hex");
}

function safeCloudDocumentID(raw: unknown, fieldName: string): string {
  const value = boundedTrimmedString(raw, fieldName, 512, true)!;
  if (!/^[A-Za-z0-9_.:-]+$/u.test(value) || value.includes("..") || value.includes("/")) {
    throw new HttpsError("invalid-argument", `${fieldName} contains unsupported characters.`);
  }
  return value;
}

function requireHexDigest(raw: unknown, fieldName: string): string {
  const value = boundedTrimmedString(raw, fieldName, 128, true)!;
  if (!/^[a-f0-9]{32,128}$/u.test(value)) {
    throw new HttpsError("invalid-argument", `${fieldName} must be a lowercase hex digest.`);
  }
  return value;
}

function requireBoundedNumber(raw: unknown, fieldName: string, min: number, max: number): number {
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

function requireRecordArray(raw: unknown, fieldName: string, maxLength: number): Array<Record<string, unknown>> {
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
    return item as Record<string, unknown>;
  });
}

async function commitBatchedWrites(
  writes: Array<(batch: WriteBatch) => void>,
  maxWritesPerBatch = 450
): Promise<void> {
  for (let start = 0; start < writes.length; start += maxWritesPerBatch) {
    const batch = db.batch();
    for (const write of writes.slice(start, start + maxWritesPerBatch)) {
      write(batch);
    }
    await batch.commit();
  }
}

function requireTokenHashes(raw: unknown, fieldName: string): string[] {
  return requireSearchHashes(raw, fieldName, true);
}

function requireOptionalSearchHashes(raw: unknown, fieldName: string): string[] {
  return requireSearchHashes(raw, fieldName, false);
}

function requireSearchHashes(raw: unknown, fieldName: string, required: boolean): string[] {
  if (raw == null && !required) return [];
  if (!Array.isArray(raw)) {
    throw new HttpsError("invalid-argument", `${fieldName} must be an array.`);
  }
  const unique = Array.from(new Set(raw.filter((item): item is string => typeof item === "string")));
  if ((required && unique.length === 0) || unique.length > 250) {
    throw new HttpsError("invalid-argument", `${fieldName} must contain ${required ? "between 1 and" : "at most"} 250 hashes.`);
  }
  for (const hash of unique) {
    if (!/^[a-f0-9]{32}$/u.test(hash)) {
      throw new HttpsError("invalid-argument", `${fieldName} contains an invalid hash.`);
    }
  }
  return unique;
}

function requireSealedText(raw: unknown, fieldName: string): Record<string, unknown> {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    throw new HttpsError("invalid-argument", `${fieldName} must be an encrypted text envelope.`);
  }
  const envelope = raw as Record<string, unknown>;
  const algorithm = boundedTrimmedString(envelope.algorithm, `${fieldName}.algorithm`, 64, true);
  if (algorithm !== "AES-256-GCM") {
    throw new HttpsError("invalid-argument", `${fieldName}.algorithm must be AES-256-GCM.`);
  }
  requireBoundedNumber(envelope.keyVersion, `${fieldName}.keyVersion`, 1, 100);
  for (const key of ["nonce", "ciphertext", "tag"]) {
    const value = boundedTrimmedString(envelope[key], `${fieldName}.${key}`, 8192, true)!;
    if (!/^[A-Za-z0-9+/=]+$/u.test(value)) {
      throw new HttpsError("invalid-argument", `${fieldName}.${key} must be base64.`);
    }
  }
  return envelope;
}

function requireISODateString(raw: unknown, fieldName: string): string {
  const value = boundedTrimmedString(raw, fieldName, 64, true)!;
  const parsed = Date.parse(value);
  if (!Number.isFinite(parsed)) {
    throw new HttpsError("invalid-argument", `${fieldName} must be an ISO 8601 date.`);
  }
  return new Date(parsed).toISOString();
}

function optionalISODateString(raw: unknown, fieldName: string): string | undefined {
  if (raw == null) return undefined;
  return requireISODateString(raw, fieldName);
}

function requireBoundedStringArray(
  raw: unknown,
  fieldName: string,
  maxLength: number,
  itemMaxLength: number
): string[] {
  if (!Array.isArray(raw)) {
    throw new HttpsError("invalid-argument", `${fieldName} must be an array.`);
  }
  if (raw.length > maxLength) {
    throw new HttpsError("invalid-argument", `${fieldName} can contain at most ${maxLength} items.`);
  }
  const values = raw.map((item, idx) =>
    boundedTrimmedString(item, `${fieldName}[${idx}]`, itemMaxLength, true)!
  );
  return Array.from(new Set(values));
}

function parseProjectMemoryFreshness(raw: unknown): ProjectMemoryFreshness {
  const value = boundedTrimmedString(raw, "freshness", 32, false);
  if (value === "needsRefresh" || value === "stale") return value;
  return "fresh";
}

function requireCloudVaultBlobEnvelope(raw: unknown, fieldName: string): CloudVaultBlobEnvelopeDoc {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    throw new HttpsError("invalid-argument", `${fieldName} must be an encrypted blob envelope.`);
  }
  const envelope = raw as Record<string, unknown>;
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
    true
  )!;
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

function assertUserStoragePath(
  uid: string,
  storagePath: string,
  expectedBodyHash?: string,
  expectedDocumentID?: string
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
  const pathDocumentID = safeCloudDocumentID(parts[3], "storagePath.documentID");
  if (expectedDocumentID && pathDocumentID !== expectedDocumentID) {
    throw new HttpsError("invalid-argument", "Encrypted session storage path does not match documentID.");
  }
  const pathBodyHash = requireHexDigest(parts[5].slice(0, -".json.aesgcm".length), "storagePath.bodyHash");
  if (expectedBodyHash && pathBodyHash !== expectedBodyHash) {
    throw new HttpsError("invalid-argument", "Encrypted session storage path does not match bodyHash.");
  }
}

async function assertEncryptedSessionBlobObject(args: {
  uid: string;
  storagePath: string;
  documentID: string;
  bodyHash: string;
  encryptedByteCount: number;
}): Promise<void> {
  assertUserStoragePath(args.uid, args.storagePath, args.bodyHash, args.documentID);
  let metadata: Record<string, unknown>;
  try {
    [metadata] = await getStorage().bucket().file(args.storagePath).getMetadata();
  } catch {
    throw new HttpsError(
      "failed-precondition",
      "Encrypted session body must be uploaded before committing the search index."
    );
  }
  const size = Number(metadata.size);
  if (!Number.isFinite(size) || size !== args.encryptedByteCount) {
    throw new HttpsError("failed-precondition", "Encrypted session body size does not match the upload ticket.");
  }
  if (size < 1 || size > getConfig().encryptedSessionBlobMaxBytes) {
    throw new HttpsError("resource-exhausted", "Encrypted session body exceeds the configured upload limit.");
  }
  if (metadata.contentType !== "application/octet-stream") {
    throw new HttpsError("failed-precondition", "Encrypted session body has an invalid content type.");
  }
}

function callableDate(value: unknown): string | undefined {
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

function serializeUsageForCallable(documentID: string, data: FirebaseFirestore.DocumentData): Record<string, unknown> {
  const provider = typeof data.provider === "string" ? data.provider : "unknown";
  const startTime = callableDate(data.startTime) ?? new Date(0).toISOString();
  const endTime = callableDate(data.endTime) ?? startTime;
  return stripUndefined({
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

async function writeHermesAuditEvent(
  uid: string,
  event: Omit<HermesConnectionAuditEventDoc, "id" | "observedAt" | "schemaVersion" | "expireAt">
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
  await db.doc(`users/${uid}/hermes_audit_events/${id}`).set(stripUndefined(doc));
}

async function writePiAgentAuditEvent(
  uid: string,
  event: Omit<PiAgentConnectionAuditEventDoc, "id" | "observedAt" | "schemaVersion" | "expireAt">
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
  await db.doc(`users/${uid}/pi_agent_audit_events/${id}`).set(stripUndefined(doc));
}

function accountIDFor(provider: string, requestedAccountID?: string): string {
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

function connectionDocFromAccount(account: ProviderAccountDoc): ProviderConnectionDoc {
  return {
    provider: account.providerID as Provider,
    status:
      account.status === "disabled" || account.status === "deleted"
        ? "disconnected"
        : account.status,
    lastValidatedAt: account.lastValidatedAt,
    lastRefreshAt: account.lastRefreshAt,
    lastErrorCode: account.lastErrorCode,
    credentialKind: account.credentialKind,
    redactedLabel: account.redactedLabel,
    schemaVersion: CONNECTION_SCHEMA_VERSION,
  };
}

function assertHostedProvider(provider: string): asserts provider is Provider {
  assertProvider(provider);
  if (!HOSTED_QUOTA_PROVIDERS.has(provider)) {
    throw new HttpsError(
      "invalid-argument",
      `Hosted quota sync is currently available for ${Array.from(HOSTED_QUOTA_PROVIDERS).join(", ")} only.`
    );
  }
}

function hostedProviderLabel(provider: string): string {
  switch (provider) {
    case "codex": return "Codex";
    case "claude-code": return "Claude Code";
    case "kimi": return "Kimi";
    default: return provider;
  }
}

function hostedCredentialKind(provider: string): CredentialKind {
  switch (provider) {
    case "codex":
    case "claude-code":
      return "session";
    default:
      return "bearer";
  }
}

function assertSelfHostedProvider(provider: string): asserts provider is Provider {
  assertProvider(provider);
  if (!SELF_HOSTED_QUOTA_PROVIDERS.has(provider)) {
    throw new HttpsError(
      "invalid-argument",
      `Self-hosted quota sync is available for ${Array.from(SELF_HOSTED_QUOTA_PROVIDERS).join(", ")}.`
    );
  }
}

async function assertActiveHostedQuotaEntitlement(uid: string): Promise<void> {
  const [hostedSnap, proSnap] = await Promise.all([
    db.doc(`users/${uid}/entitlements/hosted_quota_sync`).get(),
    db.doc(`users/${uid}/entitlements/${BURNBAR_PRO_ENTITLEMENT_ID}`).get(),
  ]);
  if (isActiveHostedQuotaEntitlement(hostedSnap.data())) return;
  if (isActivePremiumEntitlement(proSnap.data())) return;
  throw new HttpsError("permission-denied", "Hosted Quota Sync or BurnBar Pro subscription required.");
}

async function assertActiveBurnBarProEntitlement(uid: string): Promise<void> {
  const [proSnap, hostedSnap] = await Promise.all([
    db.doc(`users/${uid}/entitlements/${BURNBAR_PRO_ENTITLEMENT_ID}`).get(),
    db.doc(`users/${uid}/entitlements/hosted_quota_sync`).get(),
  ]);
  if (isActivePremiumEntitlement(proSnap.data())) return;
  if (isActivePremiumEntitlement(hostedSnap.data())) return;
  throw new HttpsError(
    "permission-denied",
    "BurnBar Pro is required for hosted LLM, encrypted session-log backup, and cloud search."
  );
}

function isActiveHostedQuotaEntitlement(raw: Record<string, unknown> | undefined): boolean {
  if (!raw || raw.active !== true) return false;
  if (raw.productID !== getConfig().hostedQuotaProductID) return false;
  const expiry = entitlementExpiryMillis(raw);
  return Number.isFinite(expiry) && expiry > Date.now();
}

function isActivePremiumEntitlement(raw: Record<string, unknown> | undefined): boolean {
  if (!raw || raw.active !== true) return false;
  const productID = typeof raw.productID === "string" ? raw.productID : "";
  if (
    productID !== getConfig().hostedQuotaProductID &&
    productID !== getConfig().burnBarProProductID &&
    productID !== getConfig().googlePlaySubscriptionProductID
  ) {
    return false;
  }
  const expiry = entitlementExpiryMillis(raw);
  return Number.isFinite(expiry) && expiry > Date.now();
}

function entitlementExpiryMillis(raw: Record<string, unknown>): number {
  const expireAt = raw.expireAt;
  if (expireAt instanceof Timestamp) {
    return expireAt.toMillis();
  }
  if (expireAt && typeof expireAt === "object") {
    const candidate = expireAt as { toMillis?: () => number };
    if (typeof candidate.toMillis === "function") {
      return candidate.toMillis();
    }
  }
  if (raw.expiresAt) {
    const parsed = Date.parse(String(raw.expiresAt));
    return Number.isFinite(parsed) ? parsed : 0;
  }
  return 0;
}

function burnBarProFeatures(): Record<string, boolean> {
  return {
    hostedQuota: true,
    hostedLLM: true,
    encryptedSessionLogBackup: true,
    cloudConversationSearch: true,
  };
}

async function writeBurnBarProEntitlement(args: {
  uid: string;
  productID: string;
  expiresAtMillis: number;
  source: string;
  platform: "ios" | "android" | "macos" | "web" | "stripe";
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
  const doc = stripUndefined({
    id: BURNBAR_PRO_ENTITLEMENT_ID,
    active,
    productID: args.productID,
    entitlementFamily: "burnbar_pro",
    features: burnBarProFeatures(),
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
  await db.doc(`users/${args.uid}/entitlements/${BURNBAR_PRO_ENTITLEMENT_ID}`).set(doc, { merge: true });
  return doc;
}

function requireConfiguredStripe(): Stripe {
  const cfg = getConfig();
  const secretKey = STRIPE_SECRET_KEY.value() || cfg.stripeSecretKey;
  if (!secretKey || !cfg.stripeBurnBarProPriceID) {
    throw new HttpsError("failed-precondition", "Stripe BurnBar Pro checkout is not configured.");
  }
  return new Stripe(secretKey);
}

function requireConfiguredStripeWebhookSecret(): string {
  const secret = STRIPE_WEBHOOK_SECRET.value() || getConfig().stripeWebhookSecret;
  if (!secret) {
    throw new HttpsError("failed-precondition", "Stripe BurnBar Pro webhook is not configured.");
  }
  return secret;
}

function boundedHttpsURL(raw: unknown, fieldName: string): string {
  const value = boundedTrimmedString(raw, fieldName, 2048, true)!;
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

async function getOrCreateStripeCustomer(uid: string, stripe: Stripe): Promise<string> {
  const ref = db.doc(`users/${uid}/billing/stripe`);
  const existing = await ref.get();
  const existingID = existing.get("customerID");
  if (typeof existingID === "string" && existingID.startsWith("cus_")) {
    return existingID;
  }

  const user = await auth.getUser(uid).catch(() => undefined);
  const customer = await stripe.customers.create({
    email: user?.email ?? undefined,
    name: user?.displayName ?? undefined,
    metadata: { firebaseUID: uid },
  });
  await ref.set(
    {
      uid,
      customerID: customer.id,
      createdAt: Timestamp.now(),
      updatedAt: Timestamp.now(),
      schemaVersion: 1,
    },
    { merge: true }
  );
  await db.doc(`stripe_customers/${customer.id}`).set(
    {
      uid,
      customerID: customer.id,
      createdAt: Timestamp.now(),
      updatedAt: Timestamp.now(),
      schemaVersion: 1,
    },
    { merge: true }
  );
  return customer.id;
}

function googlePlayLineItemForProduct(
  purchase: Record<string, unknown>,
  productID: string
): Record<string, unknown> | undefined {
  const lineItems = Array.isArray(purchase.lineItems)
    ? purchase.lineItems.filter((item): item is Record<string, unknown> => !!item && typeof item === "object")
    : [];
  return lineItems.find((item) => item.productId === productID) ?? lineItems[0];
}

function googlePlayExpiryMillis(lineItem: Record<string, unknown> | undefined): number {
  const expiryTime = lineItem?.expiryTime;
  if (typeof expiryTime === "string") {
    const parsed = Date.parse(expiryTime);
    if (Number.isFinite(parsed)) return parsed;
  }
  throw new HttpsError("failed-precondition", "Google Play did not return an expiry for this subscription.");
}

async function applyStripeCheckoutSession(
  stripe: Stripe,
  session: Stripe.Checkout.Session
): Promise<void> {
  const uid = session.metadata?.firebaseUID ?? session.client_reference_id ?? undefined;
  if (!uid) return;
  let subscription: Stripe.Subscription | undefined;
  if (typeof session.subscription === "string") {
    subscription = await stripe.subscriptions.retrieve(session.subscription);
  } else if (session.subscription && typeof session.subscription === "object") {
    subscription = session.subscription as Stripe.Subscription;
  }
  if (subscription) {
    await applyStripeSubscription(stripe, subscription, uid);
  }
}

async function applyStripeSubscription(
  stripe: Stripe,
  subscription: Stripe.Subscription,
  uidOverride?: string
): Promise<void> {
  const uid = uidOverride ?? (await uidForStripeSubscription(subscription));
  if (!uid) return;

  const customerID = stripeCustomerID(subscription.customer);
  const expiresAtMillis = stripeSubscriptionPeriodEndMillis(subscription);
  const status = String(subscription.status ?? "unknown");
  const active = STRIPE_ACTIVE_STATES.has(status) && expiresAtMillis > Date.now();

  await writeBurnBarProEntitlement({
    uid,
    productID: getConfig().burnBarProProductID,
    expiresAtMillis,
    source: "stripe_webhook_verified",
    platform: "stripe",
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
      { merge: true }
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
      { merge: true }
    );
  }
}

async function uidForStripeSubscription(subscription: Stripe.Subscription): Promise<string | undefined> {
  const metadataUID = subscription.metadata?.firebaseUID;
  if (metadataUID) return metadataUID;
  const customerID = stripeCustomerID(subscription.customer);
  if (!customerID) return undefined;
  const snap = await db.doc(`stripe_customers/${customerID}`).get();
  const uid = snap.get("uid");
  return typeof uid === "string" ? uid : undefined;
}

function stripeCustomerID(customer: unknown): string | undefined {
  if (typeof customer === "string") return customer;
  if (customer && typeof customer === "object" && "id" in customer && typeof customer.id === "string") {
    return customer.id;
  }
  return undefined;
}

function stripeSubscriptionPeriodEndMillis(subscription: Stripe.Subscription): number {
  const raw = subscription as unknown as Record<string, unknown>;
  const direct = raw.current_period_end;
  if (typeof direct === "number") return direct * 1000;
  const items = raw.items as { data?: Array<Record<string, unknown>> } | undefined;
  const itemEnd = items?.data?.[0]?.current_period_end;
  if (typeof itemEnd === "number") return itemEnd * 1000;
  return Date.now() - 1;
}

function normalizeHostedCredential(provider: string, raw: unknown): string {
  const credential = boundedTrimmedString(raw, "credential", getConfig().maxCredentialLength, true);
  if (!credential) {
    throw new HttpsError("invalid-argument", "credential is required.");
  }
  try {
    const candidate = credential.startsWith("{")
      ? credential
      : Buffer.from(credential, "base64").toString("utf8");
    JSON.parse(candidate);
    return credential;
  } catch {
    throw new HttpsError(
      "invalid-argument",
      "Codex hosted credentials must be ~/.codex/auth.json JSON or base64 JSON."
    );
  }
}

function safeSnapshotSourceID(raw: unknown): string {
  return (typeof raw === "string" ? raw : "self-hosted-runner")
    .toLowerCase()
    .replace(/[^a-z0-9_-]/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "") || "self-hosted-runner";
}

function sanitizeUploadedQuotaSnapshot(
  account: ProviderAccountDoc,
  raw: Record<string, unknown>
): QuotaSnapshotDoc {
  const now = nowISO();
  const bucketsRaw = Array.isArray(raw.buckets) ? raw.buckets : [];
  const buckets = bucketsRaw.slice(0, 16).flatMap((item): QuotaSnapshotDoc["buckets"] => {
    if (!item || typeof item !== "object") return [];
    const b = item as Record<string, unknown>;
    const name = boundedTrimmedString(b.name, "bucket.name", 80);
    if (!name) return [];
    const used = Number(b.used);
    const limit = Number(b.limit);
    const remaining = Number(b.remaining);
    if (!Number.isFinite(used) || !Number.isFinite(limit) || !Number.isFinite(remaining)) {
      return [];
    }
    return [stripUndefined({
      name,
      used,
      limit,
      remaining,
      window: boundedTrimmedString(b.window, "bucket.window", 64),
      meta: b.meta && typeof b.meta === "object"
        ? Object.fromEntries(
            Object.entries(b.meta as Record<string, unknown>)
              .filter(([key, value]) =>
                /^[a-zA-Z0-9_.-]{1,64}$/.test(key) &&
                !isSecretLikeMetadataKey(key) &&
                (typeof value === "string" ||
                  typeof value === "number" ||
                  typeof value === "boolean")
              )
              .slice(0, 16)
          )
        : undefined,
    })];
  });
  if (buckets.length === 0) {
    throw new HttpsError("invalid-argument", "At least one quota bucket is required.");
  }
  const confidence = raw.confidence === "high" ||
    raw.confidence === "medium" ||
    raw.confidence === "low" ||
    raw.confidence === "stale"
    ? raw.confidence
    : "high";
  return stripUndefined({
    sourceKind: "provider",
    sourceId: safeSnapshotSourceID(raw.sourceId),
    provider: account.providerID as Provider,
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
  }) as QuotaSnapshotDoc;
}

function isSecretLikeMetadataKey(key: string): boolean {
  const lower = key.toLowerCase();
  return lower.includes("token")
    || lower.includes("secret")
    || lower.includes("authorization")
    || lower.includes("credential")
    || lower.includes("cookie")
    || lower.includes("password");
}

async function writePrivateSecretRef(
  uid: string,
  accountID: string,
  provider: Provider,
  secretVersionName: string,
  createdAt: string,
  updatedAt: string
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

async function connectProviderAccountInternal(params: {
  uid: string;
  provider: Provider;
  credential: string;
  label?: string;
  accountID?: string;
  isDefault?: boolean;
  sourceDeviceID?: string;
  deviceDisplayName?: string;
}): Promise<ProviderAccountDoc> {
  const { uid, provider, credential } = params;
  const accountID = accountIDFor(provider, params.accountID);
  const label = params.label?.trim() || "Default";

  const adapter = ADAPTERS[provider as keyof typeof ADAPTERS];
  if (!adapter) {
    if (provider === "codex") {
      throw new HttpsError(
        "failed-precondition",
        "Codex is a runner-based provider and doesn't support backend credential connections. Connect it through hosted quota sync or the OpenBurnBar Mac app instead."
      );
    }
    throw new HttpsError(
      "unimplemented",
      `OpenBurnBar doesn't have a server-side connector for ${provider} yet. Connect it on the macOS app, or pick a supported provider (OpenAI, Factory, Cursor, Z.ai, MiniMax, Kimi).`
    );
  }

  const testResult = await adapter.testCredential(credential);
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
    existing.exists ? (existing.get("createdAt") as string | undefined) ?? now : now,
    now
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
    isDefault: params.isDefault ?? accountID.endsWith("_default"),
    sortKey: accountID.endsWith("_default") ? 0 : Date.now(),
    lastValidatedAt: now,
    lastRefreshAt: now,
    lastErrorCode: undefined,
    schemaVersion: ACCOUNT_SCHEMA_VERSION,
    createdAt: existing.exists ? (existing.get("createdAt") as string | undefined) ?? now : now,
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
    console.warn(`Initial quota refresh failed for ${uid}/${accountID}:`, quotaErr);
  }

  return accountDoc;
}

/**
 * Enforce rate limit for refreshProviderQuota per user+provider.
 * Uses Firestore as a lightweight TTL store.
 */
async function checkRefreshRateLimit(
  db: Firestore,
  uid: string,
  provider: string
): Promise<void> {
  const { refreshRateLimitSeconds } = getConfig();
  const ref = db.doc(`users/${uid}/_rate_limits/refresh_${provider}`);
  const snap = await ref.get();
  if (snap.exists) {
    const ts = snap.get("lastRefreshAt") as FirebaseFirestore.Timestamp;
    if (ts) {
      const elapsed = Date.now() - ts.toMillis();
      if (elapsed < refreshRateLimitSeconds * 1000) {
        throw new Error(
          `Rate limited: wait ${Math.ceil(
            (refreshRateLimitSeconds * 1000 - elapsed) / 1000
          )}s before refreshing ${provider}.`
        );
      }
    }
  }
  await ref.set({ lastRefreshAt: Timestamp.now() }, { merge: true });
}

async function checkHermesRateLimit(
  uid: string,
  action: string,
  windowSeconds: number
): Promise<void> {
  const ref = db.doc(`users/${uid}/_rate_limits/hermes_${action}`);
  const snap = await ref.get();
  if (snap.exists) {
    const ts = snap.get("lastAt") as FirebaseFirestore.Timestamp | undefined;
    if (ts) {
      const elapsed = Date.now() - ts.toMillis();
      if (elapsed < windowSeconds * 1000) {
        throw new HttpsError(
          "resource-exhausted",
          `Please wait ${Math.ceil((windowSeconds * 1000 - elapsed) / 1000)}s before retrying.`
        );
      }
    }
  }
  await ref.set({ lastAt: Timestamp.now() }, { merge: true });
}

async function checkPiAgentRateLimit(
  uid: string,
  action: string,
  windowSeconds: number
): Promise<void> {
  const ref = db.doc(`users/${uid}/_rate_limits/pi_agent_${action}`);
  const snap = await ref.get();
  if (snap.exists) {
    const ts = snap.get("lastAt") as FirebaseFirestore.Timestamp | undefined;
    if (ts) {
      const elapsed = Date.now() - ts.toMillis();
      if (elapsed < windowSeconds * 1000) {
        throw new HttpsError(
          "resource-exhausted",
          `Please wait ${Math.ceil((windowSeconds * 1000 - elapsed) / 1000)}s before retrying.`
        );
      }
    }
  }
  await ref.set({ lastAt: Timestamp.now() }, { merge: true });
}

// ---------------------------------------------------------------------------
// Callable: connectProviderAccount
// ---------------------------------------------------------------------------

export const connectProviderAccount = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (
    request: CallableRequest<{
      provider: string;
      credential: string;
      label?: string;
      accountID?: string;
      sourceDeviceID?: string;
      deviceDisplayName?: string;
    }>
  ) => {
    const { provider, credential, label, accountID, sourceDeviceID, deviceDisplayName } = request.data;
    const uid = request.auth?.uid;

    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in before adding a provider account.");
    }
    enforceAuthAndAppCheck(request, uid);
    assertProvider(provider);

    if (typeof credential !== "string" || credential.trim().length === 0) {
      throw new HttpsError("invalid-argument", "credential must be a non-empty string.");
    }
    if (credential.length > getConfig().maxCredentialLength) {
      throw new HttpsError(
        "invalid-argument",
        `credential exceeds max length (${getConfig().maxCredentialLength} characters).`
      );
    }

    return connectProviderAccountInternal({
      uid,
      provider,
      credential,
      label,
      accountID,
      sourceDeviceID,
      deviceDisplayName,
      isDefault: accountID == null,
    });
  }
);

// ---------------------------------------------------------------------------
// Callable: connectProviderCredential (legacy compatibility)
// ---------------------------------------------------------------------------

export const connectProviderCredential = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (request: CallableRequest<{ provider: string; credential: string }>) => {
    const { provider, credential } = request.data;
    const uid = request.auth?.uid;

    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in before connecting a provider.");
    }
    enforceAuthAndAppCheck(request, uid);

    assertProvider(provider);

    if (typeof credential !== "string" || credential.trim().length === 0) {
      throw new HttpsError("invalid-argument", "credential must be a non-empty string.");
    }
    if (credential.length > getConfig().maxCredentialLength) {
      throw new HttpsError(
        "invalid-argument",
        `credential exceeds max length (${getConfig().maxCredentialLength} characters).`
      );
    }

    const accountDoc = await connectProviderAccountInternal({
      uid,
      provider: provider as Provider,
      credential,
      label: "Default",
      accountID: `${provider}_default`,
      isDefault: true,
    });

    return connectionDocFromAccount(accountDoc);
  }
);

// ---------------------------------------------------------------------------
// Callable: connectHostedQuotaAccount
// ---------------------------------------------------------------------------

export const connectHostedQuotaAccount = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (
    request: CallableRequest<{
      provider: string;
      credential: string;
      label?: string;
      accountID?: string;
      sourceDeviceID?: string;
      deviceDisplayName?: string;
    }>
  ) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in before adding hosted quota sync.");
    }
    enforceAuthAndAppCheck(request, uid);
    const provider = String(request.data.provider ?? "");
    assertHostedProvider(provider);
    await assertActiveHostedQuotaEntitlement(uid);

    const credential = normalizeHostedCredential(provider, request.data.credential);
    const accountID = accountIDFor(provider, request.data.accountID);
    const providerLabel = hostedProviderLabel(provider);
    const accountRedactedLabel = `${providerLabel} credential stored in Secret Manager`;
    const label = boundedTrimmedString(request.data.label, "label", 80) ?? `Hosted ${providerLabel}`;
    const now = nowISO();
    const accountRef = db.doc(`users/${uid}/provider_accounts/${accountID}`);
    const existing = await accountRef.get();
    const createdAt = existing.exists
      ? (existing.get("createdAt") as string | undefined) ?? now
      : now;
    const secretVersionName = await storeCredential(uid, provider, credential, accountID);
    await writePrivateSecretRef(uid, accountID, provider, secretVersionName, createdAt, now);

    const accountDoc: ProviderAccountDoc = {
      id: accountID,
      providerID: provider,
      label,
      identityHint: undefined,
      status: "connected",
      credentialKind: hostedCredentialKind(provider),
      storageScope: "server_private",
      redactedLabel: accountRedactedLabel,
      sourceDeviceID: boundedTrimmedString(request.data.sourceDeviceID, "sourceDeviceID", 128),
      linkedSwitcherProfileID: undefined,
      isDefault: request.data.accountID == null || accountID.endsWith("_default"),
      sortKey: accountID.endsWith("_default") ? 0 : Date.now(),
      lastValidatedAt: now,
      lastRefreshAt: now,
      lastErrorCode: undefined,
      schemaVersion: ACCOUNT_SCHEMA_VERSION,
      createdAt,
      updatedAt: now,
    };

    await db.runTransaction(async (tx) => {
      tx.set(accountRef, stripUndefined(accountDoc), { merge: true });
      if (accountDoc.isDefault) {
        tx.set(
          db.doc(`users/${uid}/provider_connections/${provider}`),
          connectionDocFromAccount(accountDoc),
          { merge: true }
        );
      }
    });
    if (accountDoc.sourceDeviceID) {
      await upsertDeviceLink({
        db,
        uid,
        accountID,
        deviceID: accountDoc.sourceDeviceID,
        deviceDisplayName: request.data.deviceDisplayName ?? accountDoc.sourceDeviceID,
        capability: "owner",
      });
    }
    return accountDoc;
  }
);

// ---------------------------------------------------------------------------
// Callable: connectSelfHostedQuotaAccount
// ---------------------------------------------------------------------------

export const connectSelfHostedQuotaAccount = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (
    request: CallableRequest<{
      provider: string;
      label?: string;
      accountID?: string;
      sourceDeviceID?: string;
      deviceDisplayName?: string;
    }>
  ) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in before adding self-hosted quota sync.");
    }
    enforceAuthAndAppCheck(request, uid);
    const provider = String(request.data.provider ?? "");
    assertSelfHostedProvider(provider);

    const accountID = accountIDFor(provider, request.data.accountID);
    const label =
     boundedTrimmedString(request.data.label, "label", 80) ??
      `${hostedProviderLabel(provider)} self-hosted`;
    const now = nowISO();
    const existing = await db.doc(`users/${uid}/provider_accounts/${accountID}`).get();
    const accountDoc: ProviderAccountDoc = {
      id: accountID,
      providerID: provider,
      label,
      identityHint: undefined,
      status: "connected",
      credentialKind: "session",
      storageScope: "local_only",
      redactedLabel: "Self-hosted runner",
      sourceDeviceID: boundedTrimmedString(request.data.sourceDeviceID, "sourceDeviceID", 128),
      linkedSwitcherProfileID: undefined,
      isDefault: request.data.accountID == null || accountID.endsWith("_default"),
      sortKey: accountID.endsWith("_default") ? 0 : Date.now(),
      lastValidatedAt: now,
      lastRefreshAt: undefined,
      lastErrorCode: undefined,
      schemaVersion: ACCOUNT_SCHEMA_VERSION,
      createdAt: existing.exists ? (existing.get("createdAt") as string | undefined) ?? now : now,
      updatedAt: now,
    };

    await db.runTransaction(async (tx) => {
      tx.set(db.doc(`users/${uid}/provider_accounts/${accountID}`), stripUndefined(accountDoc), { merge: true });
      if (accountDoc.isDefault) {
        tx.set(
          db.doc(`users/${uid}/provider_connections/${provider}`),
          connectionDocFromAccount(accountDoc),
          { merge: true }
        );
      }
    });

    if (accountDoc.sourceDeviceID) {
      try {
        await upsertDeviceLink({
          db,
          uid,
          accountID,
          deviceID: accountDoc.sourceDeviceID,
          deviceDisplayName: request.data.deviceDisplayName ?? accountDoc.sourceDeviceID,
          capability: "owner",
        });
      } catch (linkErr) {
        console.warn(`device_links upsert failed for ${uid}/${accountID}:`, linkErr);
      }
    }
    return accountDoc;
  }
);

// ---------------------------------------------------------------------------
// Callable: uploadProviderQuotaSnapshot
// ---------------------------------------------------------------------------

export const uploadProviderQuotaSnapshot = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (request: CallableRequest<Record<string, unknown>>) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in before uploading quota snapshots.");
    }
    enforceAuthAndAppCheck(request, uid);
    const accountID = requiredIdentifier(request.data.accountID, "accountID");
    const accountRef = db.doc(`users/${uid}/provider_accounts/${accountID}`);
    const accountSnap = await accountRef.get();
    if (!accountSnap.exists) {
      throw new HttpsError("not-found", "Provider account not found.");
    }
    const account = accountSnap.data() as ProviderAccountDoc;
    if (account.storageScope !== "local_only") {
      throw new HttpsError(
        "failed-precondition",
        "Only self-hosted local-only accounts can upload runner snapshots."
      );
    }
    assertSelfHostedProvider(account.providerID);
    const snapshot = sanitizeUploadedQuotaSnapshot(account, request.data);
    const snapshotID = `${account.providerID}_${account.id}_${snapshot.sourceId}`;
    const now = nowISO();
    await db.runTransaction(async (tx) => {
      tx.set(db.doc(`users/${uid}/quota_snapshots/${snapshotID}`), snapshot, { merge: true });
      tx.update(accountRef, {
        status: "connected",
        lastRefreshAt: now,
        lastErrorCode: null,
        updatedAt: now,
      });
    });
    return snapshot;
  }
);

// ---------------------------------------------------------------------------
// Callable: deleteHostedQuotaCredentials
// ---------------------------------------------------------------------------

export const deleteHostedQuotaCredentials = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (request: CallableRequest<{ accountID: string; provider?: string }>) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in before deleting hosted credentials.");
    }
    enforceAuthAndAppCheck(request, uid);
    const provider = typeof request.data.provider === "string" && request.data.provider.trim()
      ? request.data.provider.trim()
      : "codex";
    assertHostedProvider(provider);
    const accountID = accountIDFor(provider, request.data.accountID);
    const accountRef = db.doc(`users/${uid}/provider_accounts/${accountID}`);
    const accountSnap = await accountRef.get();
    if (!accountSnap.exists) {
      throw new HttpsError("not-found", "Provider account not found.");
    }
    const account = accountSnap.data() as ProviderAccountDoc;
    if (account.storageScope !== "server_private") {
      throw new HttpsError("failed-precondition", "Account is not a hosted quota account.");
    }
    const privateRef = db.doc(providerAccountSecretRefPath(uid, accountID));
    const privateSnap = await privateRef.get();
    const secretVersionName = privateSnap.exists
      ? (privateSnap.get("secretVersionName") as string | undefined)
      : undefined;
    if (secretVersionName) {
      await destroyCredential(secretVersionName);
    }
    const now = nowISO();
    await db.runTransaction(async (tx) => {
      tx.delete(privateRef);
      tx.set(
        accountRef,
        {
          status: "deleted",
          lastValidatedAt: null,
          lastRefreshAt: null,
          lastErrorCode: null,
          updatedAt: now,
        },
        { merge: true }
      );
    });
    return { success: true, accountID };
  }
);

// ---------------------------------------------------------------------------
// Callable: updateProviderAccount
// ---------------------------------------------------------------------------

export const updateProviderAccount = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (
    request: CallableRequest<{
      accountID: string;
      label?: string;
      isDefault?: boolean;
      disabled?: boolean;
    }>
  ) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new Error("unauthenticated");
    }
    enforceAuthAndAppCheck(request, uid);

    const accountID = accountIDFor("account", request.data.accountID);
    const accountRef = db.doc(`users/${uid}/provider_accounts/${accountID}`);
    const snap = await accountRef.get();
    if (!snap.exists) {
      throw new Error("not-found: provider account does not exist.");
    }
    const current = snap.data() as ProviderAccountDoc;
    const now = nowISO();
    const next: Partial<ProviderAccountDoc> = {
      updatedAt: now,
    };
    if (typeof request.data.label === "string" && request.data.label.trim()) {
      next.label = request.data.label.trim();
    }
    if (typeof request.data.isDefault === "boolean") {
      next.isDefault = request.data.isDefault;
    }
    if (typeof request.data.disabled === "boolean") {
      next.status = request.data.disabled ? "disabled" : "connected";
    }

    await db.runTransaction(async (tx) => {
      if (next.isDefault === true) {
        const siblingSnap = await db
          .collection(`users/${uid}/provider_accounts`)
          .where("providerID", "==", current.providerID)
          .where("isDefault", "==", true)
          .get();

        for (const sibling of siblingSnap.docs) {
          if (sibling.id !== accountID) {
            tx.set(sibling.ref, { isDefault: false, updatedAt: now }, { merge: true });
          }
        }
      }

      tx.set(accountRef, next, { merge: true });
    });

    const updatedSnap = await accountRef.get();
    const updated = updatedSnap.data() as ProviderAccountDoc;
    if (updated.isDefault) {
      await db.doc(`users/${uid}/provider_connections/${updated.providerID}`).set(
        connectionDocFromAccount(updated),
        { merge: true }
      );
    }
    if (current.isDefault && !updated.isDefault) {
      await db.doc(`users/${uid}/provider_connections/${updated.providerID}`).set(
        { status: "disconnected", updatedAt: now },
        { merge: true }
      );
    }
    return updated;
  }
);

// ---------------------------------------------------------------------------
// Callable: deleteProviderCredential
// ---------------------------------------------------------------------------

export const deleteProviderAccount = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (request: CallableRequest<{ accountID: string }>) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new Error("unauthenticated");
    }
    enforceAuthAndAppCheck(request, uid);

    const accountID = accountIDFor("account", request.data.accountID);
    const accountRef = db.doc(`users/${uid}/provider_accounts/${accountID}`);
    const accountSnap = await accountRef.get();
    if (!accountSnap.exists) {
      throw new Error("not-found: provider account does not exist.");
    }
    const account = accountSnap.data() as ProviderAccountDoc;

    const privateRef = db.doc(providerAccountSecretRefPath(uid, accountID));
    const privateSnap = await privateRef.get();
    const secretVersionName = privateSnap.exists
      ? (privateSnap.get("secretVersionName") as string | undefined)
      : undefined;

    if (secretVersionName) {
      try {
        await destroyCredential(secretVersionName);
      } catch (err) {
        console.warn(`Failed to destroy provider account secret for ${accountID}:`, err);
      }
    }

    const now = nowISO();
    await db.runTransaction(async (tx) => {
      tx.delete(privateRef);
      tx.set(
        accountRef,
        {
          status: "deleted",
          lastValidatedAt: null,
          lastRefreshAt: null,
          lastErrorCode: null,
          updatedAt: now,
        },
        { merge: true }
      );
      if (account.isDefault) {
        tx.set(
          db.doc(`users/${uid}/provider_connections/${account.providerID}`),
          {
            status: "disconnected",
            lastValidatedAt: null,
            lastRefreshAt: null,
            lastErrorCode: null,
            updatedAt: now,
          },
          { merge: true }
        );
      }
    });

    const snapshotQuery = await db
      .collection(`users/${uid}/quota_snapshots`)
      .where("accountID", "==", accountID)
      .get();
    const batch = db.batch();
    for (const doc of snapshotQuery.docs) {
      batch.set(
        doc.ref,
        {
          confidence: "stale",
          statusMessage: "Credential deleted; snapshot is stale.",
          updatedAt: now,
        },
        { merge: true }
      );
    }
    await batch.commit();

    try {
      await revokeAllLinksForAccount(db, uid, accountID);
    } catch (linkErr) {
      console.warn(`device_links cascade revoke failed for ${uid}/${accountID}:`, linkErr);
    }

    return { success: true, accountID };
  }
);

// ---------------------------------------------------------------------------
// Callable: deleteUserCloudData
// ---------------------------------------------------------------------------

export const deleteUserCloudData = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 20,
    timeoutSeconds: 540,
    memory: "1GiB",
  },
  async (request: CallableRequest<Record<string, never>>) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in before deleting cloud data.");
    }
    enforceAuthAndAppCheck(request, uid);

    const summary = await eraseUserAccount(db, uid, {
      destroyCredential,
      deleteAuthUser: async (targetUID) => {
        await auth.deleteUser(targetUID);
      },
    });
    if (summary.failedSecretDestroys > 0) {
      throw new HttpsError(
        "internal",
        "Cloud data was deleted, but one or more hosted credential secrets could not be destroyed. Contact support.",
        summary
      );
    }

    return {
      success: true,
      ...summary,
    };
  }
);

export const deleteProviderCredential = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (request: CallableRequest<{ provider: string }>) => {
    const { provider } = request.data;
    const uid = request.auth?.uid;

    if (!uid) {
      throw new Error("unauthenticated");
    }
    enforceAuthAndAppCheck(request, uid);
    assertProvider(provider);

    const accountID = `${provider}_default`;
    const privateRef = db.doc(providerAccountSecretRefPath(uid, accountID));
    const privateSnap = await privateRef.get();
    const secretVersionName = privateSnap.exists
      ? (privateSnap.get("secretVersionName") as string | undefined)
      : undefined;

    // Destroy the secret payload if we know where it lives.
    if (secretVersionName) {
      try {
        await destroyCredential(secretVersionName);
      } catch (err) {
        console.warn(`Failed to destroy provider credential secret for ${uid}/${accountID}:`, err);
      }
    }

    const now = nowISO();
    await privateRef.delete();
    await db.doc(`users/${uid}/provider_accounts/${accountID}`).set(
      {
        status: "deleted",
        lastValidatedAt: null,
        lastRefreshAt: null,
        lastErrorCode: null,
        updatedAt: now,
      },
      { merge: true }
    );
    const connRef = db.doc(`users/${uid}/provider_connections/${provider}`);
    await connRef.set(
      {
        status: "disconnected",
        lastValidatedAt: null,
        lastRefreshAt: null,
        lastErrorCode: null,
        updatedAt: now,
      },
      { merge: true }
    );

    // Stale-mark the quota snapshot.
    const snapRef = db.doc(`users/${uid}/quota_snapshots/${provider}_default`);
    await snapRef.set(
      {
        confidence: "stale",
        statusMessage: "Credential deleted; snapshot is stale.",
        updatedAt: now,
      },
      { merge: true }
    );

    return { success: true, provider };
  }
);

// ---------------------------------------------------------------------------
// Callable: refreshProviderQuota
// ---------------------------------------------------------------------------

export const refreshProviderAccountQuota = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
    secrets: HOSTED_RUNNER_SECRETS,
  },
  async (request: CallableRequest<{ accountID: string }>) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new Error("unauthenticated");
    }
    enforceAuthAndAppCheck(request, uid);

    const accountID = accountIDFor("account", request.data.accountID);
    const snapshot = await refreshUserProviderAccountQuota(db, uid, accountID);
    if (!snapshot) {
      throw new Error("failed-precondition: quota refresh returned no snapshot.");
    }
    return snapshot;
  }
);

export const refreshProviderQuota = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
    secrets: HOSTED_RUNNER_SECRETS,
  },
  async (request: CallableRequest<{ provider: string }>) => {
    const { provider } = request.data;
    const uid = request.auth?.uid;

    if (!uid) {
      throw new Error("unauthenticated");
    }
    enforceAuthAndAppCheck(request, uid);
    assertProvider(provider);

    await checkRefreshRateLimit(db, uid, provider);

    const accountSnapshot = await db
      .collection(`users/${uid}/provider_accounts`)
      .where("providerID", "==", provider)
      .where("status", "in", ["connected", "stale", "error"])
      .get();

    if (!accountSnapshot.empty) {
      const snapshots = [];
      const skippedAccountIDs: string[] = [];
      const errors: Array<{ accountID: string; message: string }> = [];

      for (const doc of accountSnapshot.docs) {
        const account = doc.data() as ProviderAccountDoc;
        if (account.storageScope !== "cloud_refreshable" && account.storageScope !== "server_private") {
          skippedAccountIDs.push(account.id);
          continue;
        }

        try {
          const snapshot = await refreshUserProviderAccountQuota(db, uid, account.id);
          if (snapshot) {
            snapshots.push(snapshot);
          }
        } catch (err) {
          errors.push({
            accountID: account.id,
            message: (err as Error).message,
          });
        }
      }

      if (snapshots.length === 0 && errors.length > 0) {
        throw new Error(
          `failed-precondition: no ${provider} accounts refreshed: ${errors
            .map((err) => `${err.accountID}: ${err.message}`)
            .join("; ")}`
        );
      }

      return {
        success: true,
        provider,
        refreshedAccountIDs: snapshots.map((snapshot) => snapshot.accountID),
        skippedAccountIDs,
        errorAccountIDs: errors.map((err) => err.accountID),
        snapshots,
      };
    }

    const snapshot = await refreshUserProviderQuota(db, uid, provider as Provider);
    if (!snapshot) {
      throw new Error("failed-precondition: legacy quota refresh returned no snapshot.");
    }

    return {
      success: true,
      provider,
      refreshedAccountIDs: [snapshot.accountID ?? `${provider}_default`],
      skippedAccountIDs: [],
      errorAccountIDs: [],
      snapshots: [snapshot],
    };
  }
);

// ---------------------------------------------------------------------------
// Callable: Hermes pairing and connection management
// ---------------------------------------------------------------------------

export const createHermesPairing = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (
    request: CallableRequest<{
      deviceId?: string;
      platform?: "ios" | "ipados" | "macos" | "web";
      displayName?: string;
    }>
  ) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in before creating a Hermes pairing.");
    }
    enforceAuthAndAppCheck(request, uid);
    await assertActiveHostedQuotaEntitlement(uid);
    await checkHermesRateLimit(uid, "create_pairing", 5);

    const code = randomPairingCode();
    const id = `pair_${randomBytes(12).toString("hex")}`;
    const now = nowISO();
    const expiresAt = new Date(Date.now() + HERMES_PAIRING_TTL_MS).toISOString();
    const expireAt = Timestamp.fromMillis(Date.now() + HERMES_PAIRING_TTL_MS);
    const doc: HermesPairingDoc = {
      id,
      status: "pending",
      codeHash: pairingCodeDigest(code),
      failedAttempts: 0,
      requestedByDeviceId: boundedTrimmedString(request.data.deviceId, "deviceId", 128),
      requestedByPlatform: parseHermesPlatform(request.data.platform),
      displayName: boundedTrimmedString(request.data.displayName, "displayName", 80),
      expiresAt,
      expireAt,
      createdAt: now,
      updatedAt: now,
      schemaVersion: HERMES_SCHEMA_VERSION,
    };

    await db.doc(`users/${uid}/hermes_pairings/${id}`).set(stripUndefined(doc));
    await writeHermesAuditEvent(uid, {
      eventType: "pairing_created",
      pairingId: id,
      actorDeviceId: doc.requestedByDeviceId,
    });

    return { id, code, expiresAt };
  }
);

export const completeHermesPairing = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (
    request: CallableRequest<{
      pairingId: string;
      code: string;
      connectionId?: string;
      displayName?: string;
      mode?: HermesConnectionMode;
      profileName?: string;
      endpointURL?: string;
      advertisedModel?: string;
      capabilities?: string[];
      deviceId?: string;
    }>
  ) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in before completing a Hermes pairing.");
    }
    enforceAuthAndAppCheck(request, uid);
    await assertActiveHostedQuotaEntitlement(uid);
    await checkHermesRateLimit(uid, "complete_pairing", 1);

    const pairingId = requiredIdentifier(request.data.pairingId, "pairingId");
    const code = boundedTrimmedString(request.data.code, "code", 32, true);
    if (!code) {
      throw new HttpsError("invalid-argument", "code is required.");
    }

    const pairingRef = db.doc(`users/${uid}/hermes_pairings/${pairingId}`);
    const connectionId = safeIdentifier(request.data.connectionId, "hermes");
    const connectionRef = db.doc(`users/${uid}/hermes_connections/${connectionId}`);
    const now = nowISO();
    let failedAttempt = false;

    let connection: HermesConnectionDoc;
    try {
      connection = await db.runTransaction(async (tx) => {
      const pairingSnap = await tx.get(pairingRef);
      if (!pairingSnap.exists) {
        throw new HttpsError("not-found", "Pairing session not found.");
      }
      const pairing = pairingSnap.data() as HermesPairingDoc;
      if (Date.parse(pairing.expiresAt) <= Date.now() && pairing.status === "pending") {
        tx.set(pairingRef, { status: "expired", updatedAt: now }, { merge: true });
        throw new HttpsError("deadline-exceeded", "Pairing code has expired.");
      }
      if (!safeEqualHex(pairingCodeDigest(code), pairing.codeHash)) {
        failedAttempt = true;
        const failedAttempts = (pairing.failedAttempts ?? 0) + 1;
        tx.set(
          pairingRef,
          {
            failedAttempts,
            status: failedAttempts >= HERMES_MAX_FAILED_PAIRING_ATTEMPTS ? "revoked" : pairing.status,
            updatedAt: now,
          },
          { merge: true }
        );
        throw new HttpsError("permission-denied", "Pairing code mismatch.");
      }
      if (pairing.status === "completed") {
        const completedConnectionId = pairing.connectionId ?? connectionId;
        const existingSnap = await tx.get(db.doc(`users/${uid}/hermes_connections/${completedConnectionId}`));
        const existing = existingSnap.data() as Partial<HermesConnectionDoc> | undefined;
        if (existingSnap.exists && existing && isHermesConnectionDoc(existing)) {
          return existing;
        }
        throw new HttpsError("failed-precondition", "Pairing is completed but its connection is unavailable.");
      }
      if (pairing.status !== "pending") {
        throw new HttpsError("failed-precondition", "Pairing session is no longer pending.");
      }

      const mode = parseHermesConnectionMode(request.data.mode ?? "directURL");
      const endpointURL = validateHermesEndpointURL(request.data.endpointURL, mode);
      const capabilities = sanitizeHermesCapabilities(request.data.capabilities);
      const displayName =
        boundedTrimmedString(request.data.displayName, "displayName", 80) ??
        pairing.displayName ??
        "Hermes Host";
      const doc: HermesConnectionDoc = {
        id: connectionId,
        displayName,
        mode,
        status: "online",
        profileName: boundedTrimmedString(request.data.profileName, "profileName", 80),
        endpointURL,
        advertisedModel: boundedTrimmedString(request.data.advertisedModel, "advertisedModel", 160),
        capabilities,
        lastSeenAt: now,
        createdAt: now,
        updatedAt: now,
        schemaVersion: HERMES_SCHEMA_VERSION,
      };
      tx.set(connectionRef, stripUndefined(doc), { merge: true });
      tx.set(
        pairingRef,
        { status: "completed", connectionId, updatedAt: now },
        { merge: true }
      );
      return doc;
      });
    } catch (err) {
      if (failedAttempt) {
        await writeHermesAuditEvent(uid, {
          eventType: "pairing_failed",
          connectionId,
          pairingId,
          actorDeviceId: boundedTrimmedString(request.data.deviceId, "deviceId", 128),
        });
      }
      throw err;
    }

    await writeHermesAuditEvent(uid, {
      eventType: "pairing_completed",
      connectionId,
      pairingId,
      actorDeviceId: boundedTrimmedString(request.data.deviceId, "deviceId", 128),
    });
    await writeHermesAuditEvent(uid, {
      eventType: "connection_created",
      connectionId: connection.id,
      pairingId,
      actorDeviceId: boundedTrimmedString(request.data.deviceId, "deviceId", 128),
      detail: { mode: connection.mode },
    });

    return stripUndefined(connection);
  }
);

export const listHermesConnections = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (request: CallableRequest<{ includeRevoked?: boolean }>) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in before listing Hermes connections.");
    }
    enforceAuthAndAppCheck(request, uid);
    await assertActiveHostedQuotaEntitlement(uid);

    const snap = await db.collection(`users/${uid}/hermes_connections`).get();
    const connections = snap.docs
      .map((doc) => doc.data() as Partial<HermesConnectionDoc>)
      .filter(isHermesConnectionDoc)
      .filter((doc) => request.data.includeRevoked === true || doc.status !== "revoked")
      .sort((left, right) => right.updatedAt.localeCompare(left.updatedAt));
    return { connections };
  }
);

export const revokeHermesConnection = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (request: CallableRequest<{ connectionId: string; deviceId?: string }>) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in before revoking a Hermes connection.");
    }
    enforceAuthAndAppCheck(request, uid);
    await assertActiveHostedQuotaEntitlement(uid);
    await checkHermesRateLimit(uid, "revoke_connection", 2);

    const connectionId = requiredIdentifier(request.data.connectionId, "connectionId");
    const now = nowISO();
    const ref = db.doc(`users/${uid}/hermes_connections/${connectionId}`);
    await db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      if (!snap.exists) {
        throw new HttpsError("not-found", "Hermes connection not found.");
      }
      tx.update(ref, { status: "revoked", updatedAt: now });
    });
    await writeHermesAuditEvent(uid, {
      eventType: "connection_revoked",
      connectionId,
      actorDeviceId: boundedTrimmedString(request.data.deviceId, "deviceId", 128),
    });
    return { success: true, connectionId };
  }
);

export const updateHermesConnectionStatus = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (
    request: CallableRequest<{
      connectionId: string;
      status: HermesConnectionDoc["status"];
      advertisedModel?: string;
      capabilities?: string[];
      deviceId?: string;
    }>
  ) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in before updating a Hermes connection.");
    }
    enforceAuthAndAppCheck(request, uid);
    await assertActiveHostedQuotaEntitlement(uid);
    await checkHermesRateLimit(uid, "update_connection_status", 2);

    const allowedStatus = new Set<HermesConnectionDoc["status"]>([
      "pending",
      "online",
      "offline",
      "unauthorized",
      "revoked",
      "degraded",
    ]);
    if (!allowedStatus.has(request.data.status)) {
      throw new HttpsError("invalid-argument", "Unknown Hermes connection status.");
    }

    const connectionId = requiredIdentifier(request.data.connectionId, "connectionId");
    const now = nowISO();
    const update: Partial<HermesConnectionDoc> = {
      status: request.data.status,
      updatedAt: now,
    };
    const advertisedModel = boundedTrimmedString(request.data.advertisedModel, "advertisedModel", 160);
    if (advertisedModel) {
      update.advertisedModel = advertisedModel;
    }
    if (request.data.status === "online") {
      update.lastSeenAt = now;
    }
    if (Array.isArray(request.data.capabilities)) {
      update.capabilities = sanitizeHermesCapabilities(request.data.capabilities);
    }
    const ref = db.doc(`users/${uid}/hermes_connections/${connectionId}`);
    await db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      if (!snap.exists) {
        throw new HttpsError("not-found", "Hermes connection not found.");
      }
      const current = snap.data() as Partial<HermesConnectionDoc>;
      if (current.status === "revoked") {
        throw new HttpsError("failed-precondition", "Revoked Hermes connections cannot be reactivated.");
      }
      tx.update(ref, stripUndefined(update));
    });
    await writeHermesAuditEvent(uid, {
      eventType: "connection_status_updated",
      connectionId,
      actorDeviceId: boundedTrimmedString(request.data.deviceId, "deviceId", 128),
      detail: { status: request.data.status },
    });
    return { success: true, connectionId };
  }
);

// ---------------------------------------------------------------------------
// Callable: Pi Agent pairing and connection management
// ---------------------------------------------------------------------------

export const createPiAgentPairing = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (
    request: CallableRequest<{
      deviceId?: string;
      platform?: "ios" | "ipados" | "android" | "macos" | "web";
      displayName?: string;
    }>
  ) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in before creating a Pi Agent pairing.");
    }
    enforceAuthAndAppCheck(request, uid);
    await assertActiveHostedQuotaEntitlement(uid);
    await checkPiAgentRateLimit(uid, "create_pairing", 5);

    const code = randomPiAgentPairingCode();
    const id = `pair_${randomBytes(12).toString("hex")}`;
    const now = nowISO();
    const expiresAt = new Date(Date.now() + PI_AGENT_PAIRING_TTL_MS).toISOString();
    const expireAt = Timestamp.fromMillis(Date.now() + PI_AGENT_PAIRING_TTL_MS);
    const doc: PiAgentPairingDoc = {
      id,
      status: "pending",
      codeHash: piAgentPairingCodeDigest(code),
      failedAttempts: 0,
      requestedByDeviceId: boundedTrimmedString(request.data.deviceId, "deviceId", 128),
      requestedByPlatform: parsePiAgentPlatform(request.data.platform),
      displayName: boundedTrimmedString(request.data.displayName, "displayName", 80),
      expiresAt,
      expireAt,
      createdAt: now,
      updatedAt: now,
      schemaVersion: PI_AGENT_SCHEMA_VERSION,
    };

    await db.doc(`users/${uid}/pi_agent_pairings/${id}`).set(stripUndefined(doc));
    await writePiAgentAuditEvent(uid, {
      eventType: "pairing_created",
      pairingId: id,
      actorDeviceId: doc.requestedByDeviceId,
    });

    return { id, code, expiresAt };
  }
);

export const completePiAgentPairing = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (
    request: CallableRequest<{
      pairingId: string;
      code: string;
      connectionId?: string;
      displayName?: string;
      mode?: PiAgentConnectionMode;
      endpointURL?: string;
      advertisedModel?: string;
      selectedInstanceID?: string;
      redisURL?: string;
      capabilities?: string[];
      instances?: unknown[];
      models?: unknown[];
      relayPublicKey?: string;
      relayKeyVersion?: number;
      relayEncryption?: string;
      realtimeRelayURL?: string;
      realtimeRelayStatus?: string;
      deviceId?: string;
    }>
  ) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in before completing a Pi Agent pairing.");
    }
    enforceAuthAndAppCheck(request, uid);
    await assertActiveHostedQuotaEntitlement(uid);
    await checkPiAgentRateLimit(uid, "complete_pairing", 1);

    const pairingId = requiredIdentifier(request.data.pairingId, "pairingId");
    const code = boundedTrimmedString(request.data.code, "code", 32, true);
    if (!code) {
      throw new HttpsError("invalid-argument", "code is required.");
    }

    const pairingRef = db.doc(`users/${uid}/pi_agent_pairings/${pairingId}`);
    const connectionId = safeIdentifier(request.data.connectionId, "pi_agent");
    const connectionRef = db.doc(`users/${uid}/pi_agent_connections/${connectionId}`);
    const now = nowISO();
    let failedAttempt = false;

    let connection: PiAgentConnectionDoc;
    try {
      connection = await db.runTransaction(async (tx) => {
        const pairingSnap = await tx.get(pairingRef);
        if (!pairingSnap.exists) {
          throw new HttpsError("not-found", "Pi Agent pairing session not found.");
        }
        const pairing = pairingSnap.data() as PiAgentPairingDoc;
        if (Date.parse(pairing.expiresAt) <= Date.now() && pairing.status === "pending") {
          tx.set(pairingRef, { status: "expired", updatedAt: now }, { merge: true });
          throw new HttpsError("deadline-exceeded", "Pairing code has expired.");
        }
        if (!piAgentSafeEqualHex(piAgentPairingCodeDigest(code), pairing.codeHash)) {
          failedAttempt = true;
          const failedAttempts = (pairing.failedAttempts ?? 0) + 1;
          tx.set(
            pairingRef,
            {
              failedAttempts,
              status: failedAttempts >= PI_AGENT_MAX_FAILED_PAIRING_ATTEMPTS ? "revoked" : pairing.status,
              updatedAt: now,
            },
            { merge: true }
          );
          throw new HttpsError("permission-denied", "Pairing code mismatch.");
        }
        if (pairing.status === "completed") {
          const completedConnectionId = pairing.connectionId ?? connectionId;
          const existingSnap = await tx.get(db.doc(`users/${uid}/pi_agent_connections/${completedConnectionId}`));
          const existing = existingSnap.data() as Partial<PiAgentConnectionDoc> | undefined;
          if (existingSnap.exists && existing && isPiAgentConnectionDoc(existing)) {
            return existing;
          }
          throw new HttpsError("failed-precondition", "Pairing is completed but its connection is unavailable.");
        }
        if (pairing.status !== "pending") {
          throw new HttpsError("failed-precondition", "Pairing session is no longer pending.");
        }

        const mode = parsePiAgentConnectionMode(request.data.mode ?? "directURL");
        const endpointURL = validatePiAgentEndpointURL(request.data.endpointURL, mode);
        const capabilities = sanitizePiAgentCapabilities(request.data.capabilities);
        const displayName =
          boundedTrimmedString(request.data.displayName, "displayName", 80) ??
          pairing.displayName ??
          "Pi Agent Host";
        const doc: PiAgentConnectionDoc = {
          id: connectionId,
          displayName,
          mode,
          status: "online",
          endpointURL,
          advertisedModel: boundedTrimmedString(request.data.advertisedModel, "advertisedModel", 160),
          selectedInstanceID: boundedTrimmedString(request.data.selectedInstanceID, "selectedInstanceID", 128),
          redisURL: boundedTrimmedString(request.data.redisURL, "redisURL", 2048),
          relayPublicKey: boundedTrimmedString(request.data.relayPublicKey, "relayPublicKey", 256),
          relayKeyVersion: typeof request.data.relayKeyVersion === "number" ? request.data.relayKeyVersion : undefined,
          relayEncryption: boundedTrimmedString(request.data.relayEncryption, "relayEncryption", 80),
          realtimeRelayURL: boundedTrimmedString(request.data.realtimeRelayURL, "realtimeRelayURL", 2048),
          realtimeRelayStatus: boundedTrimmedString(request.data.realtimeRelayStatus, "realtimeRelayStatus", 40),
          capabilities,
          instances: sanitizePiAgentInstances(request.data.instances),
          models: sanitizePiAgentModels(request.data.models),
          lastSeenAt: now,
          createdAt: now,
          updatedAt: now,
          schemaVersion: PI_AGENT_SCHEMA_VERSION,
        };
        tx.set(connectionRef, stripUndefined(doc), { merge: true });
        tx.set(pairingRef, { status: "completed", connectionId, updatedAt: now }, { merge: true });
        return doc;
      });
    } catch (err) {
      if (failedAttempt) {
        await writePiAgentAuditEvent(uid, {
          eventType: "pairing_failed",
          connectionId,
          pairingId,
          actorDeviceId: boundedTrimmedString(request.data.deviceId, "deviceId", 128),
        });
      }
      throw err;
    }

    await writePiAgentAuditEvent(uid, {
      eventType: "pairing_completed",
      connectionId,
      pairingId,
      actorDeviceId: boundedTrimmedString(request.data.deviceId, "deviceId", 128),
    });
    await writePiAgentAuditEvent(uid, {
      eventType: "connection_created",
      connectionId: connection.id,
      pairingId,
      actorDeviceId: boundedTrimmedString(request.data.deviceId, "deviceId", 128),
      detail: { mode: connection.mode },
    });

    return stripUndefined(connection);
  }
);

export const listPiAgentConnections = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (request: CallableRequest<{ includeRevoked?: boolean }>) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in before listing Pi Agent connections.");
    }
    enforceAuthAndAppCheck(request, uid);
    await assertActiveHostedQuotaEntitlement(uid);

    const snap = await db.collection(`users/${uid}/pi_agent_connections`).get();
    const connections = snap.docs
      .map((doc) => doc.data() as Partial<PiAgentConnectionDoc>)
      .filter(isPiAgentConnectionDoc)
      .filter((doc) => request.data.includeRevoked === true || doc.status !== "revoked")
      .sort((left, right) => right.updatedAt.localeCompare(left.updatedAt));
    return { connections };
  }
);

export const revokePiAgentConnection = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (request: CallableRequest<{ connectionId: string; deviceId?: string }>) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in before revoking a Pi Agent connection.");
    }
    enforceAuthAndAppCheck(request, uid);
    await assertActiveHostedQuotaEntitlement(uid);
    await checkPiAgentRateLimit(uid, "revoke_connection", 2);

    const connectionId = requiredIdentifier(request.data.connectionId, "connectionId");
    const now = nowISO();
    const ref = db.doc(`users/${uid}/pi_agent_connections/${connectionId}`);
    await db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      if (!snap.exists) {
        throw new HttpsError("not-found", "Pi Agent connection not found.");
      }
      tx.update(ref, { status: "revoked", updatedAt: now });
    });
    await writePiAgentAuditEvent(uid, {
      eventType: "connection_revoked",
      connectionId,
      actorDeviceId: boundedTrimmedString(request.data.deviceId, "deviceId", 128),
    });
    return { success: true, connectionId };
  }
);

export const updatePiAgentConnectionStatus = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (
    request: CallableRequest<{
      connectionId: string;
      status: PiAgentConnectionDoc["status"];
      advertisedModel?: string;
      selectedInstanceID?: string;
      capabilities?: string[];
      instances?: unknown[];
      models?: unknown[];
      deviceId?: string;
    }>
  ) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in before updating a Pi Agent connection.");
    }
    enforceAuthAndAppCheck(request, uid);
    await assertActiveHostedQuotaEntitlement(uid);
    await checkPiAgentRateLimit(uid, "update_connection_status", 2);

    const allowedStatus = new Set<PiAgentConnectionDoc["status"]>([
      "pending",
      "online",
      "offline",
      "unauthorized",
      "revoked",
      "degraded",
    ]);
    if (!allowedStatus.has(request.data.status)) {
      throw new HttpsError("invalid-argument", "Unknown Pi Agent connection status.");
    }

    const connectionId = requiredIdentifier(request.data.connectionId, "connectionId");
    const now = nowISO();
    const update: Partial<PiAgentConnectionDoc> = {
      status: request.data.status,
      updatedAt: now,
    };
    const advertisedModel = boundedTrimmedString(request.data.advertisedModel, "advertisedModel", 160);
    if (advertisedModel) {
      update.advertisedModel = advertisedModel;
    }
    const selectedInstanceID = boundedTrimmedString(request.data.selectedInstanceID, "selectedInstanceID", 128);
    if (selectedInstanceID) {
      update.selectedInstanceID = selectedInstanceID;
    }
    if (request.data.status === "online") {
      update.lastSeenAt = now;
    }
    if (Array.isArray(request.data.capabilities)) {
      update.capabilities = sanitizePiAgentCapabilities(request.data.capabilities);
    }
    if (Array.isArray(request.data.instances)) {
      update.instances = sanitizePiAgentInstances(request.data.instances);
    }
    if (Array.isArray(request.data.models)) {
      update.models = sanitizePiAgentModels(request.data.models);
    }
    const ref = db.doc(`users/${uid}/pi_agent_connections/${connectionId}`);
    await db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      if (!snap.exists) {
        throw new HttpsError("not-found", "Pi Agent connection not found.");
      }
      const current = snap.data() as Partial<PiAgentConnectionDoc>;
      if (current.status === "revoked") {
        throw new HttpsError("failed-precondition", "Revoked Pi Agent connections cannot be reactivated.");
      }
      tx.update(ref, stripUndefined(update));
    });
    await writePiAgentAuditEvent(uid, {
      eventType: "connection_status_updated",
      connectionId,
      actorDeviceId: boundedTrimmedString(request.data.deviceId, "deviceId", 128),
      detail: { status: request.data.status },
    });
    return { success: true, connectionId };
  }
);

// ---------------------------------------------------------------------------
// Callable / HTTP: BurnBar Pro billing bridges
// ---------------------------------------------------------------------------

export const createStripeBurnBarProCheckoutSession = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 50,
    secrets: STRIPE_API_SECRETS,
  },
  async (
    request: CallableRequest<{
      successUrl?: unknown;
      cancelUrl?: unknown;
    }>
  ) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before starting checkout.");
    enforceAuthAndAppCheck(request, uid);

    const cfg = getConfig();
    const stripe = requireConfiguredStripe();
    const successUrl = boundedHttpsURL(request.data.successUrl, "successUrl");
    const cancelUrl = boundedHttpsURL(request.data.cancelUrl, "cancelUrl");
    const customerID = await getOrCreateStripeCustomer(uid, stripe);

    const session = await stripe.checkout.sessions.create({
      mode: "subscription",
      customer: customerID,
      client_reference_id: uid,
      success_url: successUrl,
      cancel_url: cancelUrl,
      allow_promotion_codes: true,
      line_items: [{ price: cfg.stripeBurnBarProPriceID, quantity: 1 }],
      metadata: {
        firebaseUID: uid,
        entitlementID: BURNBAR_PRO_ENTITLEMENT_ID,
      },
      subscription_data: {
        metadata: {
          firebaseUID: uid,
          entitlementID: BURNBAR_PRO_ENTITLEMENT_ID,
        },
      },
    });

    return { sessionId: session.id, url: session.url };
  }
);

export const createStripeBurnBarProPortalSession = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 50,
    secrets: STRIPE_API_SECRETS,
  },
  async (
    request: CallableRequest<{
      returnUrl?: unknown;
    }>
  ) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before opening the billing portal.");
    enforceAuthAndAppCheck(request, uid);

    const stripe = requireConfiguredStripe();
    const returnUrl = boundedHttpsURL(request.data.returnUrl, "returnUrl");
    const customerID = await getOrCreateStripeCustomer(uid, stripe);
    const session = await stripe.billingPortal.sessions.create({
      customer: customerID,
      return_url: returnUrl,
    });
    return { url: session.url };
  }
);

export const verifyGooglePlayBurnBarProSubscription = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (
    request: CallableRequest<{
      purchaseToken?: unknown;
      productID?: unknown;
    }>
  ) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before verifying Google Play billing.");
    enforceAuthAndAppCheck(request, uid);

    const cfg = getConfig();
    const purchaseToken = boundedTrimmedString(request.data.purchaseToken, "purchaseToken", 4096, true)!;
    const productID =
      boundedTrimmedString(request.data.productID, "productID", 256, false) ??
      cfg.googlePlaySubscriptionProductID;
    if (productID !== cfg.googlePlaySubscriptionProductID && productID !== cfg.burnBarProProductID) {
      throw new HttpsError("invalid-argument", "Unsupported Google Play subscription product.");
    }

    const authClient = await google.auth.getClient({
      scopes: ["https://www.googleapis.com/auth/androidpublisher"],
    });
    const androidpublisher = google.androidpublisher({ version: "v3", auth: authClient });
    const response = await androidpublisher.purchases.subscriptionsv2.get({
      packageName: cfg.googlePlayPackageName,
      token: purchaseToken,
    });

    const purchase = response.data as Record<string, unknown>;
    const subscriptionState =
      typeof purchase.subscriptionState === "string"
        ? purchase.subscriptionState
        : "SUBSCRIPTION_STATE_UNSPECIFIED";
    const lineItem = googlePlayLineItemForProduct(purchase, productID);
    const expiresAtMillis = googlePlayExpiryMillis(lineItem);
    const active = GOOGLE_PLAY_ACTIVE_STATES.has(subscriptionState) && expiresAtMillis > Date.now();
    const tokenHash = sha256Hex(purchaseToken);
    const entitlement = await writeBurnBarProEntitlement({
      uid,
      productID: cfg.googlePlaySubscriptionProductID,
      expiresAtMillis,
      source: "google_play_verified",
      platform: "android",
      purchaseTokenHash: tokenHash,
      rawStatus: subscriptionState,
      environment: "Production",
      activeOverride: active,
    });

    await db.doc(`users/${uid}/billing/google_play_purchases/${tokenHash}`).set(
      stripUndefined({
        uid,
        productID: cfg.googlePlaySubscriptionProductID,
        purchaseTokenHash: tokenHash,
        subscriptionState,
        expiresAt: new Date(expiresAtMillis).toISOString(),
        lineItemProductID: lineItem && typeof lineItem.productId === "string" ? lineItem.productId : undefined,
        lastVerifiedAt: nowISO(),
        schemaVersion: 1,
      }),
      { merge: true }
    );

    return { entitlement, subscriptionState, active, expiresAt: new Date(expiresAtMillis).toISOString() };
  }
);

export const stripeBurnBarProWebhook = onRequest(
  {
    region: "us-central1",
    maxInstances: 20,
    secrets: STRIPE_WEBHOOK_SECRETS,
  },
  async (req, res): Promise<void> => {
    let stripe: Stripe;
    let webhookSecret: string;
    try {
      stripe = requireConfiguredStripe();
      webhookSecret = requireConfiguredStripeWebhookSecret();
    } catch {
      res.status(503).send("Stripe webhook is not configured.");
      return;
    }
    const signature = req.header("stripe-signature");
    if (!signature) {
      res.status(400).send("Missing Stripe signature.");
      return;
    }
    let event: Stripe.Event;
    try {
      const rawBody = Buffer.isBuffer(req.rawBody) ? req.rawBody : Buffer.from(JSON.stringify(req.body ?? {}));
      event = stripe.webhooks.constructEvent(rawBody, signature, webhookSecret);
    } catch (err) {
      res.status(400).send(`Webhook Error: ${err instanceof Error ? err.message : "invalid signature"}`);
      return;
    }

    try {
      switch (event.type) {
        case "checkout.session.completed":
        case "checkout.session.async_payment_succeeded":
          await applyStripeCheckoutSession(stripe, event.data.object as Stripe.Checkout.Session);
          break;
        case "customer.subscription.created":
        case "customer.subscription.updated":
        case "customer.subscription.deleted":
          await applyStripeSubscription(stripe, event.data.object as Stripe.Subscription);
          break;
        default:
          break;
      }
      res.json({ received: true });
    } catch (err) {
      console.error("Stripe webhook handling failed", err);
      res.status(500).send("Stripe webhook handling failed.");
    }
  }
);

// ---------------------------------------------------------------------------
// Callable: encrypted hosted session logs + cloud search
// ---------------------------------------------------------------------------

export const beginEncryptedSessionBlobUpload = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (
    request: CallableRequest<{
      documentID?: unknown;
      bodyHash?: unknown;
      encryptedByteCount?: unknown;
      contentType?: unknown;
    }>
  ) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before uploading session logs.");
    enforceAuthAndAppCheck(request, uid);
    await assertActiveBurnBarProEntitlement(uid);

    const documentID = safeCloudDocumentID(request.data.documentID, "documentID");
    const bodyHash = requireHexDigest(request.data.bodyHash, "bodyHash");
    const encryptedByteCount = requireBoundedNumber(
      request.data.encryptedByteCount,
      "encryptedByteCount",
      1,
      getConfig().encryptedSessionBlobMaxBytes
    );
    const contentType =
      boundedTrimmedString(request.data.contentType, "contentType", 128, false) ??
      "application/octet-stream";
    if (contentType !== "application/octet-stream") {
      throw new HttpsError("invalid-argument", "encrypted session blobs must use application/octet-stream.");
    }

    const storagePath = `users/${uid}/session_logs/${documentID}/bodies/${bodyHash}.json.aesgcm`;
    const expiresAt = new Date(Date.now() + 10 * 60 * 1000);
    const [uploadURL] = await getStorage()
      .bucket()
      .file(storagePath)
      .getSignedUrl({
        version: "v4",
        action: "write",
        expires: expiresAt,
        contentType,
      });

    return {
      storagePath,
      uploadURL,
      expiresAt: expiresAt.toISOString(),
      maxBytes: getConfig().encryptedSessionBlobMaxBytes,
      acceptedByteCount: encryptedByteCount,
    };
  }
);

export const getEncryptedSessionBlobDownloadUrl = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (
    request: CallableRequest<{
      storagePath?: unknown;
    }>
  ) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before reading session logs.");
    enforceAuthAndAppCheck(request, uid);
    await assertActiveBurnBarProEntitlement(uid);
    const storagePath = boundedTrimmedString(request.data.storagePath, "storagePath", 1024, true)!;
    assertUserStoragePath(uid, storagePath);
    const expiresAt = new Date(Date.now() + 10 * 60 * 1000);
    const [downloadURL] = await getStorage()
      .bucket()
      .file(storagePath)
      .getSignedUrl({
        version: "v4",
        action: "read",
        expires: expiresAt,
      });
    return { downloadURL, expiresAt: expiresAt.toISOString() };
  }
);

export const commitEncryptedSearchIndexBatch = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (
    request: CallableRequest<{
      documents?: unknown;
      chunks?: unknown;
      indexVersion?: unknown;
      deviceId?: unknown;
    }>
  ) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before syncing the search index.");
    enforceAuthAndAppCheck(request, uid);
    await assertActiveBurnBarProEntitlement(uid);

    const documents = requireRecordArray(request.data.documents, "documents", 50);
    const chunks = requireRecordArray(request.data.chunks, "chunks", 300);
    const indexVersion = requireBoundedNumber(request.data.indexVersion, "indexVersion", 1, 100);
    const deviceId = boundedTrimmedString(request.data.deviceId, "deviceId", 256, true)!;
    const now = Timestamp.now();
    const commitID = randomBytes(16).toString("hex");

    let writeCount = 0;
    const writes: Array<(batch: WriteBatch) => void> = [];
    const documentsRef = db.collection(`users/${uid}/cloud_search_documents`);
    const chunksRef = db.collection(`users/${uid}/cloud_search_chunks`);
    const postingsRef = db.collection(`users/${uid}/cloud_search_postings`);

    for (const raw of documents) {
      const documentID = safeCloudDocumentID(raw.documentID, "document.documentID");
      const doc = {
        uid,
        documentID,
        deviceId,
        sourceKind: boundedTrimmedString(raw.sourceKind, "document.sourceKind", 64, true),
        sourceID: boundedTrimmedString(raw.sourceID, "document.sourceID", 512, true),
        sourceVersionID: boundedTrimmedString(raw.sourceVersionID, "document.sourceVersionID", 512, false),
        provider: boundedTrimmedString(raw.provider, "document.provider", 80, false),
        projectName: boundedTrimmedString(raw.projectName, "document.projectName", 512, false),
        bodyHash: requireHexDigest(raw.bodyHash, "document.bodyHash"),
        storagePath: boundedTrimmedString(raw.storagePath, "document.storagePath", 1024, true)!,
        sealedTitle: requireSealedText(raw.sealedTitle, "document.sealedTitle"),
        sealedBodyPreview: requireSealedText(raw.sealedBodyPreview, "document.sealedBodyPreview"),
        byteCount: requireBoundedNumber(raw.byteCount, "document.byteCount", 0, getConfig().encryptedSessionBlobMaxBytes),
        encryptedByteCount: requireBoundedNumber(
          raw.encryptedByteCount,
          "document.encryptedByteCount",
          1,
          getConfig().encryptedSessionBlobMaxBytes
        ),
        indexVersion,
        tokenHashVersion: 1,
        semanticHashVersion: 1,
        commitID,
        updatedAt: now,
        schemaVersion: 1,
      };
      await assertEncryptedSessionBlobObject({
        uid,
        storagePath: doc.storagePath,
        documentID,
        bodyHash: doc.bodyHash,
        encryptedByteCount: doc.encryptedByteCount,
      });
      writes.push((batch) => batch.set(documentsRef.doc(documentID), stripUndefined(doc), { merge: true }));
      writeCount += 1;
    }

    for (const raw of chunks) {
      const documentID = safeCloudDocumentID(raw.documentID, "chunk.documentID");
      const chunkID = safeCloudDocumentID(raw.chunkID, "chunk.chunkID");
      const tokenHashes = requireTokenHashes(raw.tokenHashes, "chunk.tokenHashes");
      const semanticHashes = requireOptionalSearchHashes(raw.semanticHashes, "chunk.semanticHashes");
      if (indexVersion >= 2 && semanticHashes.length === 0) {
        throw new HttpsError("invalid-argument", "chunk.semanticHashes are required for encrypted semantic search indexes.");
      }
      const chunk = {
        uid,
        chunkID,
        documentID,
        deviceId,
        sourceKind: boundedTrimmedString(raw.sourceKind, "chunk.sourceKind", 64, true),
        sourceID: boundedTrimmedString(raw.sourceID, "chunk.sourceID", 512, true),
        provider: boundedTrimmedString(raw.provider, "chunk.provider", 80, false),
        projectName: boundedTrimmedString(raw.projectName, "chunk.projectName", 512, false),
        ordinal: requireBoundedNumber(raw.ordinal, "chunk.ordinal", 0, 100_000),
        startOffset: requireBoundedNumber(raw.startOffset, "chunk.startOffset", 0, 50_000_000),
        endOffset: requireBoundedNumber(raw.endOffset, "chunk.endOffset", 0, 50_000_000),
        contentHash: requireHexDigest(raw.contentHash, "chunk.contentHash"),
        bodyHash: requireHexDigest(raw.bodyHash, "chunk.bodyHash"),
        storagePath: boundedTrimmedString(raw.storagePath, "chunk.storagePath", 1024, true)!,
        sealedSnippet: requireSealedText(raw.sealedSnippet, "chunk.sealedSnippet"),
        tokenHashes,
        semanticHashes,
        indexVersion,
        tokenHashVersion: 1,
        semanticHashVersion: semanticHashes.length > 0 ? 1 : 0,
        commitID,
        updatedAt: now,
        schemaVersion: 1,
      };
      assertUserStoragePath(uid, chunk.storagePath, chunk.bodyHash, documentID);
      writes.push((batch) => batch.set(chunksRef.doc(chunkID), stripUndefined(chunk), { merge: true }));
      writeCount += 1;
      for (const hash of semanticHashes) {
        const postingKey = `semantic_${hash}`;
        const edgeID = `${postingKey}_${chunkID}`;
        writes.push((batch) => batch.set(
          postingsRef.doc(edgeID),
          stripUndefined({
            uid,
            postingKey,
            edgeID,
            kind: "semantic",
            hash,
            chunkID,
            documentID,
            sourceKind: chunk.sourceKind,
            sourceID: chunk.sourceID,
            provider: chunk.provider,
            projectName: chunk.projectName,
            ordinal: chunk.ordinal,
            bodyHash: chunk.bodyHash,
            storagePath: chunk.storagePath,
            sealedSnippet: chunk.sealedSnippet,
            updatedAt: now,
            indexVersion,
            commitID,
            schemaVersion: 1,
          }),
          { merge: true }
        ));
        writeCount += 1;
      }
    }

    writes.push((batch) => batch.set(
      db.doc(`users/${uid}/cloud_search_index_state/${deviceId}`),
      stripUndefined({
        uid,
        deviceId,
        indexVersion,
        activeCommitID: commitID,
        lastCommittedAt: now,
        documentCount: documents.length,
        chunkCount: chunks.length,
        postingCount: writeCount - documents.length - chunks.length,
        schemaVersion: 1,
      }),
      { merge: true }
    ));
    writeCount += 1;

    await commitBatchedWrites(writes);
    return { ok: true, writeCount, documentCount: documents.length, chunkCount: chunks.length, commitID };
  }
);

export const commitEncryptedProjectMemorySnapshot = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (
    request: CallableRequest<{
      projectSlug?: unknown;
      projectDisplayName?: unknown;
      contentHash?: unknown;
      sourceSessionCount?: unknown;
      sourceConversationCount?: unknown;
      generatedAt?: unknown;
      freshness?: unknown;
      visualKinds?: unknown;
      sealedSnapshot?: unknown;
    }>
  ) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before syncing Project Memory.");
    enforceAuthAndAppCheck(request, uid);
    await assertActiveBurnBarProEntitlement(uid);

    const projectSlug = requiredIdentifier(request.data.projectSlug, "projectSlug");
    const projectDisplayName = boundedTrimmedString(
      request.data.projectDisplayName,
      "projectDisplayName",
      240,
      true
    )!;
    const contentHash = requireHexDigest(request.data.contentHash, "contentHash");
    const sourceSessionCount = requireBoundedNumber(
      request.data.sourceSessionCount ?? 0,
      "sourceSessionCount",
      0,
      1_000_000
    );
    const sourceConversationCount = requireBoundedNumber(
      request.data.sourceConversationCount ?? 0,
      "sourceConversationCount",
      0,
      1_000_000
    );
    const generatedAt = optionalISODateString(request.data.generatedAt, "generatedAt") ?? nowISO();
    const freshness = parseProjectMemoryFreshness(request.data.freshness);
    const visualKinds = request.data.visualKinds == null
      ? []
      : requireBoundedStringArray(request.data.visualKinds, "visualKinds", 24, 80);
    const sealedSnapshot = requireCloudVaultBlobEnvelope(request.data.sealedSnapshot, "sealedSnapshot");
    const updatedAt = nowISO();

    const doc: ProjectMemorySnapshotDoc = {
      projectSlug,
      projectDisplayName,
      contentHash,
      sourceSessionCount,
      sourceConversationCount,
      generatedAt,
      freshness,
      visualKinds,
      sealedSnapshot,
      encryption: {
        algorithm: sealedSnapshot.algorithm,
        keyVersion: sealedSnapshot.keyVersion,
        envelopeSchemaVersion: sealedSnapshot.schemaVersion,
      },
      schemaVersion: 1,
      updatedAt,
    };

    await db.doc(`users/${uid}/project_memory_snapshots/${projectSlug}`).set(stripUndefined(doc), { merge: true });
    return {
      ok: true,
      projectSlug,
      contentHash,
      generatedAt,
      updatedAt,
    };
  }
);

export const getEncryptedProjectMemorySnapshot = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (
    request: CallableRequest<{
      projectSlug?: unknown;
    }>
  ) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before reading Project Memory.");
    enforceAuthAndAppCheck(request, uid);
    await assertActiveBurnBarProEntitlement(uid);

    const projectSlug = requiredIdentifier(request.data.projectSlug, "projectSlug");
    const snap = await db.doc(`users/${uid}/project_memory_snapshots/${projectSlug}`).get();
    if (!snap.exists) {
      return { snapshot: null };
    }
    const data = snap.data() ?? {};
    return {
      snapshot: stripUndefined({
        projectSlug: data.projectSlug ?? projectSlug,
        projectDisplayName: data.projectDisplayName,
        contentHash: data.contentHash,
        sourceSessionCount: data.sourceSessionCount,
        sourceConversationCount: data.sourceConversationCount,
        generatedAt: data.generatedAt,
        freshness: data.freshness,
        visualKinds: data.visualKinds,
        sealedSnapshot: data.sealedSnapshot,
        encryption: data.encryption,
        schemaVersion: data.schemaVersion,
        updatedAt: data.updatedAt,
      }),
    };
  }
);

export const listEncryptedProjectMemorySnapshots = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (
    request: CallableRequest<{
      limit?: unknown;
    }>
  ) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before listing Project Memory.");
    enforceAuthAndAppCheck(request, uid);
    await assertActiveBurnBarProEntitlement(uid);

    const limit = requireBoundedNumber(request.data.limit ?? 20, "limit", 1, 50);
    const snapshot = await db
      .collection(`users/${uid}/project_memory_snapshots`)
      .orderBy("updatedAt", "desc")
      .limit(limit)
      .get();

    const snapshots = snapshot.docs.map((doc) => {
      const data = doc.data();
      return stripUndefined({
        projectSlug: data.projectSlug ?? doc.id,
        projectDisplayName: data.projectDisplayName,
        contentHash: data.contentHash,
        sourceSessionCount: data.sourceSessionCount,
        sourceConversationCount: data.sourceConversationCount,
        generatedAt: data.generatedAt,
        freshness: data.freshness,
        visualKinds: data.visualKinds,
        schemaVersion: data.schemaVersion,
        updatedAt: data.updatedAt,
      });
    });

    return { snapshots };
  }
);

export const searchEncryptedConversationIndex = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (
    request: CallableRequest<{
      tokenHashes?: unknown;
      semanticHashes?: unknown;
      limit?: unknown;
      provider?: unknown;
    }>
  ) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before searching session logs.");
    enforceAuthAndAppCheck(request, uid);
    await assertActiveBurnBarProEntitlement(uid);

    const tokenHashes = requireOptionalSearchHashes(request.data.tokenHashes, "tokenHashes").slice(0, 10);
    const semanticHashes = requireOptionalSearchHashes(request.data.semanticHashes, "semanticHashes").slice(0, 12);
    const limitRaw = typeof request.data.limit === "number" ? request.data.limit : 25;
    const limit = Math.max(1, Math.min(Math.floor(limitRaw), 50));
    const provider = boundedTrimmedString(request.data.provider, "provider", 80, false);
    if (tokenHashes.length === 0 && semanticHashes.length === 0) return { hits: [] };

    type ScoredChunk = {
      id: string;
      data: DocumentData;
      tokenMatches: number;
      semanticMatches: number;
    };
    const scoredById = new Map<string, ScoredChunk>();
    const chunksRef = db.collection(`users/${uid}/cloud_search_chunks`);
    const chunkCache = new Map<string, DocumentSnapshot>();
    const stateSnap = await db
      .collection(`users/${uid}/cloud_search_index_state`)
      .limit(100)
      .get();
    const activeCommitIDs = new Set(
      stateSnap.docs
        .map((doc) => doc.get("activeCommitID"))
        .filter((commitID): commitID is string => typeof commitID === "string" && /^[a-f0-9]{32}$/u.test(commitID))
    );

    const mergeChunkDoc = (
      doc: DocumentSnapshot,
      requested: Set<string>,
      fieldName: "tokenHashes" | "semanticHashes",
      scoreName: "tokenMatches" | "semanticMatches"
    ) => {
      if (!doc.exists) return;
      const data = doc.data() ?? {};
      if (provider && data.provider !== provider) return;
      const chunkCommitID = typeof data.commitID === "string" ? data.commitID : undefined;
      if (chunkCommitID) {
        if (!activeCommitIDs.has(chunkCommitID)) return;
      } else if (activeCommitIDs.size > 0) {
        return;
      }
      const hashes = Array.isArray(data[fieldName])
        ? data[fieldName].filter((hash): hash is string => typeof hash === "string")
        : [];
      const matches = hashes.reduce((sum, hash) => sum + (requested.has(hash) ? 1 : 0), 0);
      if (matches <= 0) return;
      const existing = scoredById.get(doc.id) ?? {
        id: doc.id,
        data,
        tokenMatches: 0,
        semanticMatches: 0,
      };
      existing[scoreName] += matches;
      scoredById.set(doc.id, existing);
    };

    const mergeSnapshot = (
      snap: QuerySnapshot,
      requested: Set<string>,
      fieldName: "tokenHashes" | "semanticHashes",
      scoreName: "tokenMatches" | "semanticMatches"
    ) => {
      for (const doc of snap.docs) {
        chunkCache.set(doc.id, doc);
        mergeChunkDoc(doc, requested, fieldName, scoreName);
      }
    };

    const mergePostingHits = async (
      hashes: string[],
      kind: "token" | "semantic",
      fieldName: "tokenHashes" | "semanticHashes",
      scoreName: "tokenMatches" | "semanticMatches"
    ) => {
      if (hashes.length === 0) return;
      const postingKeys = hashes.map((hash) => `${kind}_${hash}`);
      let postingQuery = db
        .collection(`users/${uid}/cloud_search_postings`)
        .where("postingKey", "in", postingKeys);
      if (provider) postingQuery = postingQuery.where("provider", "==", provider);
      const postingSnaps = await postingQuery.limit(500).get();
      const chunkIDs = new Set<string>();
      for (const postingSnap of postingSnaps.docs) {
        const data = postingSnap.data();
        if (!data || data.kind !== kind || typeof data.hash !== "string") continue;
        if (!hashes.includes(data.hash)) continue;
        if (typeof data.chunkID === "string" && chunkIDs.size < 500) {
          chunkIDs.add(data.chunkID);
        }
      }
      if (chunkIDs.size === 0) return;
      const missingRefs = Array.from(chunkIDs)
        .filter((chunkID) => !chunkCache.has(chunkID))
        .map((chunkID) => db.doc(`users/${uid}/cloud_search_chunks/${chunkID}`));
      if (missingRefs.length > 0) {
        const chunkSnaps = await db.getAll(...missingRefs);
        for (const chunkSnap of chunkSnaps) {
          chunkCache.set(chunkSnap.id, chunkSnap);
        }
      }
      const requested = new Set(hashes);
      for (const chunkID of chunkIDs) {
        const chunkSnap = chunkCache.get(chunkID);
        if (chunkSnap) {
          mergeChunkDoc(chunkSnap, requested, fieldName, scoreName);
        }
      }
    };

    await Promise.all([
      mergePostingHits(tokenHashes, "token", "tokenHashes", "tokenMatches"),
      mergePostingHits(semanticHashes, "semantic", "semanticHashes", "semanticMatches"),
    ]);

    if (tokenHashes.length > 0) {
      let tokenQuery = chunksRef.where("tokenHashes", "array-contains-any", tokenHashes);
      if (provider) tokenQuery = tokenQuery.where("provider", "==", provider);
      const tokenSnap = await tokenQuery.limit(250).get();
      mergeSnapshot(tokenSnap, new Set(tokenHashes), "tokenHashes", "tokenMatches");
    }

    if (semanticHashes.length > 0) {
      let semanticQuery = chunksRef.where("semanticHashes", "array-contains-any", semanticHashes);
      if (provider) semanticQuery = semanticQuery.where("provider", "==", provider);
      const semanticSnap = await semanticQuery.limit(250).get();
      mergeSnapshot(semanticSnap, new Set(semanticHashes), "semanticHashes", "semanticMatches");
    }

    const scored = Array.from(scoredById.values())
      .filter((item) => item.tokenMatches > 0 || item.semanticMatches > 0)
      .sort((a, b) => {
        const aScore = a.tokenMatches * 2 + a.semanticMatches;
        const bScore = b.tokenMatches * 2 + b.semanticMatches;
        return bScore - aScore || Number(a.data.ordinal ?? 0) - Number(b.data.ordinal ?? 0);
      });

    const hits: Array<Record<string, unknown>> = [];
    const seenDocuments = new Set<string>();
    for (const item of scored) {
      const documentID = typeof item.data.documentID === "string" ? item.data.documentID : "";
      if (!documentID || seenDocuments.has(documentID)) continue;
      const docSnap = await db.doc(`users/${uid}/cloud_search_documents/${documentID}`).get();
      if (!docSnap.exists) continue;
      const docData = docSnap.data() ?? {};
      if (docData.bodyHash !== item.data.bodyHash || docData.storagePath !== item.data.storagePath) continue;
      seenDocuments.add(documentID);
      hits.push({
        id: item.id,
        chunkID: item.id,
        documentID,
        sourceKind: item.data.sourceKind,
        sourceID: item.data.sourceID,
        provider: item.data.provider,
        projectName: docData.projectName ?? item.data.projectName,
        sealedTitle: docData.sealedTitle,
        sealedSnippet: item.data.sealedSnippet,
        sealedBodyPreview: docData.sealedBodyPreview,
        storagePath: item.data.storagePath,
        bodyHash: item.data.bodyHash,
        score: Math.min(1, (item.tokenMatches * 2 + item.semanticMatches) / Math.max(1, tokenHashes.length * 2 + semanticHashes.length)),
        tokenScore: tokenHashes.length > 0 ? item.tokenMatches / tokenHashes.length : 0,
        semanticScore: semanticHashes.length > 0 ? item.semanticMatches / semanticHashes.length : 0,
        matchKind: item.tokenMatches > 0 && item.semanticMatches > 0 ? "hybrid" : item.semanticMatches > 0 ? "semantic" : "token",
        tokenHashVersion: item.data.tokenHashVersion ?? 1,
        semanticHashVersion: item.data.semanticHashVersion ?? 0,
        indexVersion: item.data.indexVersion ?? 1,
      });
      if (hits.length >= limit) break;
    }
    return { hits };
  }
);

export const issueRemoteMcpGrant = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 50,
    secrets: [REMOTE_MCP_TOKEN_HMAC_SECRET],
  },
  async (
    request: CallableRequest<{
      clientId?: unknown;
      displayName?: unknown;
      clientType?: unknown;
      installFingerprint?: unknown;
      scopes?: unknown;
      grantMode?: unknown;
    }>
  ) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before connecting OpenBurnBar MCP.");
    enforceAuthAndAppCheck(request, uid);
    await assertActiveBurnBarProEntitlement(uid);
    const tokenSecret = REMOTE_MCP_TOKEN_HMAC_SECRET.value();
    if (!tokenSecret) {
      throw new HttpsError("failed-precondition", "Remote MCP token signing secret is not configured.");
    }
    const scopes = Array.isArray(request.data.scopes)
      ? request.data.scopes.filter((scope): scope is "search:read" | "conversation:read" | "usage:read" | "index:status" =>
        ["search:read", "conversation:read", "usage:read", "index:status"].includes(String(scope))
      )
      : undefined;
    const grantModeRaw = typeof request.data.grantMode === "string" ? request.data.grantMode : "local_decrypt_shim";
    const grantMode = grantModeRaw === "sealed_only" || grantModeRaw === "remote_readable_explicit_opt_in"
      ? grantModeRaw
      : "local_decrypt_shim";
    return issueRemoteMcpGrantForSignedInUser(db, uid, {
      clientId: boundedTrimmedString(request.data.clientId, "clientId", 160, false),
      displayName: boundedTrimmedString(request.data.displayName, "displayName", 120, false),
      clientType: boundedTrimmedString(request.data.clientType, "clientType", 80, false),
      installFingerprint: boundedTrimmedString(request.data.installFingerprint, "installFingerprint", 512, false),
      scopes,
      grantMode,
      entitlementFamily: "burnbar_pro",
      tokenSecret,
      audience: process.env.REMOTE_MCP_AUDIENCE ?? "https://mcp.burnbar.ai/mcp",
    });
  }
);

export const revokeRemoteMcpClient = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 50,
  },
  async (request: CallableRequest<{ clientId?: unknown }>) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before revoking OpenBurnBar MCP clients.");
    enforceAuthAndAppCheck(request, uid);
    const clientId = boundedTrimmedString(request.data.clientId, "clientId", 160, true)!;
    await revokeRemoteMcpClientDoc(db, uid, clientId);
    return { ok: true, clientId };
  }
);

// ---------------------------------------------------------------------------
// Callable: searchStreams
// ---------------------------------------------------------------------------

export const searchStreams = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (request: CallableRequest<{ query?: unknown; limit?: unknown }>) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in before searching streams.");
    }
    enforceAuthAndAppCheck(request, uid);

    const query = boundedTrimmedString(request.data.query, "query", 200, true) ?? "";
    const limitRaw = typeof request.data.limit === "number" ? request.data.limit : 25;
    const limit = Math.max(1, Math.min(Math.floor(limitRaw), 50));
    const terms = normalizedSearchTerms(query);
    if (terms.length === 0) {
      return { hits: [] };
    }

    const chunkSnap = await db
      .collectionGroup("chunks")
      .where("uid", "==", uid)
      .where("terms", "array-contains", terms[0])
      .select("docId", "sessionId", "deviceId", "bodyHash", "title", "snippet", "projectName", "model", "terms")
      .limit(200)
      .get();

    const scored = chunkSnap.docs
      .map((doc) => {
        const data = doc.data();
        const indexedTerms = Array.isArray(data.terms)
          ? data.terms.filter((term): term is string => typeof term === "string")
          : [];
        const haystack = `${data.title ?? ""} ${data.snippet ?? ""} ${data.projectName ?? ""} ${data.model ?? ""} ${indexedTerms.join(" ")}`;
        return { doc, data, score: searchScore(haystack, terms) };
      })
      .filter((item) => item.score > 0)
      .sort((a, b) => b.score - a.score || String(a.data.docId ?? "").localeCompare(String(b.data.docId ?? "")))
      .slice(0, limit * 3);

    const hits: Array<Record<string, unknown>> = [];
    const seenSessions = new Set<string>();

    for (const item of scored) {
      const deviceId = typeof item.data.deviceId === "string" ? item.data.deviceId : "";
      const sessionId = typeof item.data.sessionId === "string" ? item.data.sessionId : "";
      const docId = typeof item.data.docId === "string" ? item.data.docId : "";
      const bodyHash = typeof item.data.bodyHash === "string" ? item.data.bodyHash : "";
      if (!deviceId || !sessionId || !docId || !bodyHash) {
        continue;
      }

      const manifest = await db.doc(`users/${uid}/session_logs/${docId}`).get();
      if (!manifest.exists || manifest.get("bodyHash") !== bodyHash) {
        continue;
      }

      const dedupeKey = `${deviceId}:${sessionId}`;
      if (seenSessions.has(dedupeKey)) {
        continue;
      }

      const usageSnap = await db
        .collection(`users/${uid}/usage`)
        .where("deviceId", "==", deviceId)
        .where("sessionId", "==", sessionId)
        .limit(1)
        .get();
      const usageDoc = usageSnap.docs[0];
      if (!usageDoc) {
        continue;
      }

      const usage = serializeUsageForCallable(usageDoc.id, usageDoc.data());
      seenSessions.add(dedupeKey);
      hits.push({
        id: `${sha256Hex(`${docId}:${item.doc.id}`).slice(0, 16)}_${item.doc.id}`,
        title: item.data.title ?? usage.projectName ?? usage.model ?? "Stream",
        snippet: item.data.snippet ?? "",
        score: item.score / terms.length,
        usage,
      });
      if (hits.length >= limit) {
        break;
      }
    }

    return { hits };
  }
);

// ---------------------------------------------------------------------------
// Callable: rebuildUsageRollups
// ---------------------------------------------------------------------------

export const rebuildUsageRollups = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 10,
  },
  async (request: CallableRequest<Record<string, never>>) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new Error("unauthenticated");
    }
    enforceAuthAndAppCheck(request, uid);

    const rollups = await computeUserRollups(db, uid);
    await writeUserRollups(db, uid, rollups);

    return {
      success: true,
      computedAt: rollups.all_time.computedAt,
      windows: ["today", "7d", "30d", "90d", "all_time"] as const,
    };
  }
);

// ---------------------------------------------------------------------------
// Callable: seedAndroidDemoAccount
// ---------------------------------------------------------------------------

export const seedAndroidDemoAccount = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 20,
  },
  async (request: CallableRequest<Record<string, never>>) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in before loading demo data.");
    }
    enforceAuthAndAppCheck(request, uid);

    return seedAndroidDemoAccountForUser(db, uid);
  }
);

// ---------------------------------------------------------------------------
// Re-export background functions so `firebase deploy --only functions` picks
// them up from a single entry point.
// ---------------------------------------------------------------------------
export {
  onUsageWritten,
  rebuildRollups,
  refreshAllProviderQuotas,
  refreshModelLandscapeBenchmarks,
  latestRouterRundown,
};

// ---------------------------------------------------------------------------
// Apple App Store JWS verification surface.
//
// Trust pipeline: every entitlement field is derived from a JWS verified
// against AppleRootCA-G3 / G2 / AppleInc Root, then reconciled with live
// state from the App Store Server API. See `appstore/` for details.
// ---------------------------------------------------------------------------
export {
  beginEntitlementBinding,
  verifyHostedQuotaEntitlement,
  restoreHostedQuotaEntitlement,
  appStoreServerNotificationsV2,
  reconcileHostedEntitlementsDaily,
} from "./appstore/index.js";

// ---------------------------------------------------------------------------
// Callable: adoptProviderAccountForDevice
//
// Owner-only. Writes a `use` device link onto an existing provider account.
// Validates that the calling user owns both the account and the device.
// ---------------------------------------------------------------------------

export const adoptProviderAccountForDevice = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 50,
  },
  async (
    request: CallableRequest<{
      accountID: string;
      deviceID: string;
      deviceDisplayName?: string;
      capability?: string;
    }>
  ) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in before adopting a provider account.");
    }
    enforceAuthAndAppCheck(request, uid);

    const accountID = String(request.data.accountID ?? "").trim();
    const deviceID = String(request.data.deviceID ?? "").trim();
    if (!accountID) {
      throw new HttpsError("invalid-argument", "accountID is required.");
    }
    if (!deviceID) {
      throw new HttpsError("invalid-argument", "deviceID is required.");
    }

    const requestedCap = request.data.capability;
    if (requestedCap !== undefined && !isDeviceLinkCapability(requestedCap)) {
      throw new HttpsError("invalid-argument", "capability must be one of owner/use/add.");
    }

    const doc = await adoptDeviceLink({
      db,
      uid,
      accountID,
      deviceID,
      deviceDisplayName: request.data.deviceDisplayName,
      capability: requestedCap,
    });
    return { success: true, link: doc };
  }
);

// ---------------------------------------------------------------------------
// Callable: revokeProviderAccountDeviceLink
//
// Soft-revoke a single device link. Owner-only.
// ---------------------------------------------------------------------------

export const revokeProviderAccountDeviceLink = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 50,
  },
  async (
    request: CallableRequest<{ accountID: string; deviceID: string }>
  ) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in before revoking device links.");
    }
    enforceAuthAndAppCheck(request, uid);

    const accountID = String(request.data.accountID ?? "").trim();
    const deviceID = String(request.data.deviceID ?? "").trim();
    if (!accountID || !deviceID) {
      throw new HttpsError("invalid-argument", "accountID and deviceID are required.");
    }
    await revokeDeviceLink({ db, uid, accountID, deviceID });
    return { success: true };
  }
);

// ---------------------------------------------------------------------------
// Callable: backfillProviderAccountDeviceLinks
//
// Idempotent. Walks every provider_accounts/* doc for the caller and writes
// owner + use links so existing accounts surface at least one device chip
// after the rollout.
// ---------------------------------------------------------------------------

export const backfillProviderAccountDeviceLinks = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 20,
    timeoutSeconds: 300,
  },
  async (
    request: CallableRequest<{
      callerDeviceID?: string;
      callerDeviceDisplayName?: string;
    }>
  ) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in before running backfill.");
    }
    enforceAuthAndAppCheck(request, uid);

    const callerDeviceID = String(request.data.callerDeviceID ?? "").trim() || undefined;
    const callerDeviceDisplayName =
      String(request.data.callerDeviceDisplayName ?? "").trim() || undefined;

    const writes = await backfillUserDeviceLinks(
      db,
      uid,
      callerDeviceID,
      callerDeviceDisplayName
    );
    return { success: true, writes };
  }
);

export const backfillProviderAccountDeviceLinksScheduled = onSchedule(
  {
    region: "us-central1",
    schedule: "every 24 hours",
    timeoutSeconds: 300,
    memory: "512MiB",
  },
  async () => {
    const users = await db.collection("users").limit(500).get();
    let usersScanned = 0;
    let writes = 0;
    for (const user of users.docs) {
      usersScanned += 1;
      writes += await backfillUserDeviceLinks(db, user.id, undefined, undefined);
    }
    console.log("provider_account_device_links scheduled backfill", { usersScanned, writes });
  }
);
import { kimiAdapter } from "./providers/kimi.js";
// Claude Code is now supported via the hosted quota runner.
HOSTED_QUOTA_PROVIDERS.add("claude-code");
