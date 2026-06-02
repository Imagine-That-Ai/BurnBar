import { SUPPORTED_PROVIDERS } from "./types.js";
import type { DocumentData } from "firebase-admin/firestore";
import type {
  AppStoreEnvironment,
  EntitlementBindingDoc,
  HostedQuotaEntitlementDoc,
  HostedQuotaEntitlementSource,
  ModelBenchmarkFreshness,
  ModelBenchmarkSnapshotDoc,
  ModelBenchmarkSource,
  ModelBenchmarkSourceStatusDoc,
  ModelBenchmarkTaskCategory,
  Provider,
  ProviderAccountDoc,
  ProviderAccountSecretRefDoc,
  ProviderAccountStorageScope,
  ProviderConnectionDoc,
  ProviderID,
  QuotaBucket,
  RollupJobDoc,
  UsageEventDoc,
} from "./types.js";

const PROVIDER_VALUES: ReadonlySet<string> = new Set(SUPPORTED_PROVIDERS);

export type TimestampWithToMillis = {
  toMillis: () => number;
};

export type TimestampWithToDate = {
  toDate: () => Date;
};

export function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

export function recordOrUndefined(value: unknown): Record<string, unknown> | undefined {
  return isRecord(value) ? value : undefined;
}

export function recordEntries(value: unknown): Array<[string, unknown]> {
  return isRecord(value) ? Object.entries(value) : [];
}

export function isProvider(value: unknown): value is Provider {
  return typeof value === "string" && PROVIDER_VALUES.has(value);
}

export function parseProvider(value: unknown): Provider | undefined {
  return isProvider(value) ? value : undefined;
}

export function stringValue(raw: unknown): string | undefined {
  return typeof raw === "string" && raw.trim() ? raw.trim() : undefined;
}

export function numberValue(raw: unknown): number | undefined {
  return typeof raw === "number" && Number.isFinite(raw) ? raw : undefined;
}

export function isTimestampWithToMillis(value: unknown): value is TimestampWithToMillis {
  return isRecord(value) && typeof value.toMillis === "function";
}

export function isFirestoreTimestamp(value: unknown): value is import("firebase-admin/firestore").Timestamp {
  return (
    isRecord(value) &&
    typeof value.toMillis === "function" &&
    typeof value.seconds === "number" &&
    typeof value.nanoseconds === "number"
  );
}

export function isTimestampWithToDate(value: unknown): value is TimestampWithToDate {
  return isRecord(value) && typeof value.toDate === "function";
}

export function errorCode(error: unknown): number | string | undefined {
  return isRecord(error) && (typeof error.code === "number" || typeof error.code === "string") ? error.code : undefined;
}

export function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

export function jsonObject(value: unknown): Record<string, unknown> {
  return isRecord(value) ? value : {};
}

export function stripUndefinedRecord(value: Record<string, unknown>): Record<string, unknown> {
  return Object.fromEntries(Object.entries(value).filter(([, item]) => item !== undefined));
}

function isCredentialKind(value: unknown): value is ProviderAccountDoc["credentialKind"] {
  return value === "token" || value === "bearer" || value === "session" || value === "cookie" || value === "plan";
}

function isProviderAccountStatus(value: unknown): value is ProviderAccountDoc["status"] {
  return (
    value === "connected" ||
    value === "disconnected" ||
    value === "stale" ||
    value === "error" ||
    value === "disabled" ||
    value === "deleted"
  );
}

export function isProviderAccountStorageScope(value: unknown): value is ProviderAccountStorageScope {
  return (
    value === "cloud_refreshable" || value === "local_only" || value === "device_keychain" || value === "server_private"
  );
}

export function parseProviderAccountDoc(raw: unknown): ProviderAccountDoc | undefined {
  if (!isRecord(raw)) return undefined;
  if (
    typeof raw.id !== "string" ||
    typeof raw.providerID !== "string" ||
    typeof raw.label !== "string" ||
    !isProviderAccountStatus(raw.status) ||
    !isCredentialKind(raw.credentialKind) ||
    !isProviderAccountStorageScope(raw.storageScope) ||
    typeof raw.redactedLabel !== "string" ||
    typeof raw.isDefault !== "boolean" ||
    typeof raw.sortKey !== "number" ||
    typeof raw.schemaVersion !== "number" ||
    typeof raw.createdAt !== "string" ||
    typeof raw.updatedAt !== "string"
  ) {
    return undefined;
  }
  return {
    id: raw.id,
    providerID: raw.providerID,
    label: raw.label,
    status: raw.status,
    credentialKind: raw.credentialKind,
    storageScope: raw.storageScope,
    redactedLabel: raw.redactedLabel,
    isDefault: raw.isDefault,
    sortKey: raw.sortKey,
    schemaVersion: raw.schemaVersion,
    createdAt: raw.createdAt,
    updatedAt: raw.updatedAt,
    identityHint: typeof raw.identityHint === "string" ? raw.identityHint : undefined,
    sourceDeviceID: typeof raw.sourceDeviceID === "string" ? raw.sourceDeviceID : undefined,
    linkedSwitcherProfileID: typeof raw.linkedSwitcherProfileID === "string" ? raw.linkedSwitcherProfileID : undefined,
    lastValidatedAt: typeof raw.lastValidatedAt === "string" ? raw.lastValidatedAt : undefined,
    lastRefreshAt: typeof raw.lastRefreshAt === "string" ? raw.lastRefreshAt : undefined,
    lastErrorCode: typeof raw.lastErrorCode === "string" ? raw.lastErrorCode : undefined,
    endpointProfileID: typeof raw.endpointProfileID === "string" ? raw.endpointProfileID : undefined,
    region:
      raw.region === "cn" || raw.region === "sgp" || raw.region === "ams" || raw.region === "global"
        ? raw.region
        : undefined,
    tokenPlanTier:
      raw.tokenPlanTier === "lite" ||
      raw.tokenPlanTier === "standard" ||
      raw.tokenPlanTier === "pro" ||
      raw.tokenPlanTier === "max"
        ? raw.tokenPlanTier
        : undefined,
    tokenPlanBillingCycle:
      raw.tokenPlanBillingCycle === "monthly" || raw.tokenPlanBillingCycle === "annual"
        ? raw.tokenPlanBillingCycle
        : undefined,
    authMethodID: typeof raw.authMethodID === "string" ? raw.authMethodID : undefined,
  };
}

export function parseProviderAccountSecretRefDoc(raw: unknown): ProviderAccountSecretRefDoc | undefined {
  if (!isRecord(raw)) return undefined;
  if (
    typeof raw.uid !== "string" ||
    typeof raw.providerID !== "string" ||
    typeof raw.accountID !== "string" ||
    typeof raw.secretVersionName !== "string" ||
    typeof raw.createdAt !== "string" ||
    typeof raw.updatedAt !== "string"
  ) {
    return undefined;
  }
  return {
    uid: raw.uid,
    providerID: raw.providerID,
    accountID: raw.accountID,
    secretVersionName: raw.secretVersionName,
    createdAt: raw.createdAt,
    updatedAt: raw.updatedAt,
  };
}

function isProviderConnectionStatus(value: unknown): value is ProviderConnectionDoc["status"] {
  return value === "connected" || value === "disconnected" || value === "error" || value === "stale";
}

export function parseProviderConnectionDoc(raw: unknown): ProviderConnectionDoc | undefined {
  if (!isRecord(raw)) return undefined;
  if (
    !isProvider(raw.provider) ||
    !isProviderConnectionStatus(raw.status) ||
    !isCredentialKind(raw.credentialKind) ||
    typeof raw.redactedLabel !== "string" ||
    typeof raw.schemaVersion !== "number"
  ) {
    return undefined;
  }
  return {
    provider: raw.provider,
    status: raw.status,
    credentialKind: raw.credentialKind,
    redactedLabel: raw.redactedLabel,
    schemaVersion: raw.schemaVersion,
    lastValidatedAt: typeof raw.lastValidatedAt === "string" ? raw.lastValidatedAt : undefined,
    lastRefreshAt: typeof raw.lastRefreshAt === "string" ? raw.lastRefreshAt : undefined,
    lastErrorCode: typeof raw.lastErrorCode === "string" ? raw.lastErrorCode : undefined,
  };
}

export function parseHostedQuotaEntitlementDoc(raw: unknown): HostedQuotaEntitlementDoc | undefined {
  if (!isRecord(raw)) return undefined;
  const environment = parseAppStoreEnvironment(raw.environment);
  const source = parseHostedQuotaEntitlementSource(raw.source);
  if (
    typeof raw.id !== "string" ||
    typeof raw.active !== "boolean" ||
    typeof raw.productID !== "string" ||
    typeof raw.transactionID !== "string" ||
    typeof raw.originalTransactionID !== "string" ||
    !environment ||
    typeof raw.signedTransactionHash !== "string" ||
    typeof raw.lastVerifiedAt !== "string" ||
    !source ||
    typeof raw.verificationVersion !== "number" ||
    typeof raw.schemaVersion !== "number" ||
    typeof raw.updatedAt !== "string"
  ) {
    return undefined;
  }
  return {
    id: raw.id,
    active: raw.active,
    productID: raw.productID,
    transactionID: raw.transactionID,
    originalTransactionID: raw.originalTransactionID,
    expiresAt: typeof raw.expiresAt === "string" ? raw.expiresAt : undefined,
    expireAt: isTimestampWithToMillis(raw.expireAt)
      ? (raw.expireAt as HostedQuotaEntitlementDoc["expireAt"])
      : undefined,
    revokedAt: typeof raw.revokedAt === "string" ? raw.revokedAt : undefined,
    revocationReason: typeof raw.revocationReason === "number" ? raw.revocationReason : undefined,
    environment,
    ownershipType:
      raw.ownershipType === "PURCHASED" || raw.ownershipType === "FAMILY_SHARED" ? raw.ownershipType : undefined,
    appAccountToken: typeof raw.appAccountToken === "string" ? raw.appAccountToken : undefined,
    signedTransactionHash: raw.signedTransactionHash,
    signedDateMs: typeof raw.signedDateMs === "number" ? raw.signedDateMs : undefined,
    lastNotificationUUID: typeof raw.lastNotificationUUID === "string" ? raw.lastNotificationUUID : undefined,
    lastVerifiedAt: raw.lastVerifiedAt,
    source,
    verificationVersion: raw.verificationVersion,
    schemaVersion: raw.schemaVersion,
    updatedAt: raw.updatedAt,
  };
}

export function parseEntitlementBindingDoc(raw: unknown): EntitlementBindingDoc | undefined {
  if (!isRecord(raw)) return undefined;
  if (
    typeof raw.id !== "string" ||
    typeof raw.uid !== "string" ||
    typeof raw.productID !== "string" ||
    typeof raw.createdAt !== "string" ||
    typeof raw.schemaVersion !== "number"
  ) {
    return undefined;
  }
  return {
    id: raw.id,
    uid: raw.uid,
    productID: raw.productID,
    clientPlatform:
      raw.clientPlatform === "ios" || raw.clientPlatform === "ipados" || raw.clientPlatform === "macos"
        ? raw.clientPlatform
        : undefined,
    consumedAt: typeof raw.consumedAt === "string" ? raw.consumedAt : undefined,
    createdAt: raw.createdAt,
    schemaVersion: raw.schemaVersion,
  };
}

export function parseRollupJobDoc(raw: unknown): RollupJobDoc | undefined {
  if (!isRecord(raw) || typeof raw.dirty !== "boolean") return undefined;
  return {
    dirty: raw.dirty,
    dirtiedAt: typeof raw.dirtiedAt === "string" ? raw.dirtiedAt : undefined,
    lastComputedAt: typeof raw.lastComputedAt === "string" ? raw.lastComputedAt : undefined,
    lastErrorCode: typeof raw.lastErrorCode === "string" ? raw.lastErrorCode : undefined,
  };
}

function parseModelBenchmarkSource(value: unknown): ModelBenchmarkSource | undefined {
  switch (value) {
    case "artificial_analysis":
    case "terminal_bench":
    case "design_arena":
    case "huggingface":
    case "manual_fixture":
    case "cached_fixture":
      return value;
    default:
      return undefined;
  }
}

function parseModelBenchmarkTaskCategory(value: unknown): ModelBenchmarkTaskCategory | undefined {
  switch (value) {
    case "general":
    case "coding":
    case "terminal":
    case "design":
    case "agent":
    case "analysis":
    case "unknown":
      return value;
    default:
      return undefined;
  }
}

function parseModelBenchmarkFreshness(value: unknown): ModelBenchmarkFreshness | undefined {
  switch (value) {
    case "fresh":
    case "stale":
    case "unavailable":
    case "cached":
    case "manual":
      return value;
    default:
      return undefined;
  }
}

export function parseModelBenchmarkSnapshotDoc(raw: unknown): ModelBenchmarkSnapshotDoc | undefined {
  if (!isRecord(raw)) return undefined;
  const source = parseModelBenchmarkSource(raw.source);
  const taskCategory = parseModelBenchmarkTaskCategory(raw.taskCategory);
  const freshness = parseModelBenchmarkFreshness(raw.freshness);
  if (
    typeof raw.id !== "string" ||
    !source ||
    typeof raw.fetchedAt !== "string" ||
    typeof raw.modelID !== "string" ||
    !taskCategory ||
    !freshness ||
    typeof raw.schemaVersion !== "number" ||
    typeof raw.updatedAt !== "string"
  ) {
    return undefined;
  }
  return {
    id: raw.id,
    source,
    sourceURL: typeof raw.sourceURL === "string" ? raw.sourceURL : undefined,
    attribution: typeof raw.attribution === "string" ? raw.attribution : undefined,
    fetchedAt: raw.fetchedAt,
    modelID: raw.modelID,
    providerID: typeof raw.providerID === "string" ? raw.providerID : undefined,
    taskCategory,
    score: typeof raw.score === "number" ? raw.score : undefined,
    rank: typeof raw.rank === "number" ? raw.rank : undefined,
    costSignal: typeof raw.costSignal === "number" ? raw.costSignal : undefined,
    inputCostPerMtoken: typeof raw.inputCostPerMtoken === "number" ? raw.inputCostPerMtoken : undefined,
    outputCostPerMtoken: typeof raw.outputCostPerMtoken === "number" ? raw.outputCostPerMtoken : undefined,
    blendedCostPerMtoken: typeof raw.blendedCostPerMtoken === "number" ? raw.blendedCostPerMtoken : undefined,
    latencySignal: typeof raw.latencySignal === "number" ? raw.latencySignal : undefined,
    contextWindowTokens: typeof raw.contextWindowTokens === "number" ? raw.contextWindowTokens : undefined,
    reliabilitySignal: typeof raw.reliabilitySignal === "number" ? raw.reliabilitySignal : undefined,
    confidence: typeof raw.confidence === "number" ? raw.confidence : undefined,
    freshness,
    schemaVersion: raw.schemaVersion,
    updatedAt: raw.updatedAt,
  };
}

export function parseModelBenchmarkSourceStatusDoc(raw: unknown): ModelBenchmarkSourceStatusDoc | undefined {
  if (!isRecord(raw)) return undefined;
  const source = parseModelBenchmarkSource(raw.source);
  const status = raw.status;
  if (
    !source ||
    (status !== "fresh" && status !== "stale" && status !== "unavailable" && status !== "error") ||
    typeof raw.message !== "string" ||
    typeof raw.schemaVersion !== "number" ||
    typeof raw.updatedAt !== "string"
  ) {
    return undefined;
  }
  return {
    source,
    status,
    fetchedAt: typeof raw.fetchedAt === "string" ? raw.fetchedAt : undefined,
    message: raw.message,
    attribution: typeof raw.attribution === "string" ? raw.attribution : undefined,
    schemaVersion: raw.schemaVersion,
    updatedAt: raw.updatedAt,
  };
}

export function parseUsageEventDoc(raw: unknown): UsageEventDoc | undefined {
  if (!isRecord(raw) || !isProvider(raw.provider)) {
    return undefined;
  }
  const schemaVersion = typeof raw.schemaVersion === "number" ? raw.schemaVersion : 1;
  const doc: UsageEventDoc = {
    provider: raw.provider,
    schemaVersion,
  };
  if (typeof raw.providerID === "string") doc.providerID = raw.providerID;
  if (typeof raw.providerAccountID === "string") doc.providerAccountID = raw.providerAccountID;
  if (typeof raw.providerAccountLabel === "string") doc.providerAccountLabel = raw.providerAccountLabel;
  if (isProviderAccountStorageScope(raw.providerAccountSource)) {
    doc.providerAccountSource = raw.providerAccountSource;
  }
  if (typeof raw.model === "string") doc.model = raw.model;
  if (typeof raw.sessionId === "string") doc.sessionId = raw.sessionId;
  if (typeof raw.deviceId === "string") doc.deviceId = raw.deviceId;
  if (typeof raw.sourceDeviceId === "string") doc.sourceDeviceId = raw.sourceDeviceId;
  if (typeof raw.inputTokens === "number") doc.inputTokens = raw.inputTokens;
  if (typeof raw.outputTokens === "number") doc.outputTokens = raw.outputTokens;
  if (typeof raw.cacheCreationTokens === "number") doc.cacheCreationTokens = raw.cacheCreationTokens;
  if (typeof raw.cacheReadTokens === "number") doc.cacheReadTokens = raw.cacheReadTokens;
  if (typeof raw.reasoningTokens === "number") doc.reasoningTokens = raw.reasoningTokens;
  if (typeof raw.totalTokens === "number") doc.totalTokens = raw.totalTokens;
  if (typeof raw.costUsd === "number") doc.costUsd = raw.costUsd;
  if (typeof raw.cost === "number") doc.cost = raw.cost;
  if (typeof raw.provenanceConfidence === "string") doc.provenanceConfidence = raw.provenanceConfidence;
  if (raw.timestamp !== undefined) doc.timestamp = raw.timestamp;
  if (raw.startTime !== undefined) doc.startTime = raw.startTime;
  if (raw.endTime !== undefined) doc.endTime = raw.endTime;
  if (raw.createdAt !== undefined) doc.createdAt = raw.createdAt;
  if (raw.updatedAt !== undefined) doc.updatedAt = raw.updatedAt;
  return doc;
}

export function parseQuotaBucket(raw: unknown): QuotaBucket | undefined {
  if (!isRecord(raw)) return undefined;
  if (
    typeof raw.name !== "string" ||
    typeof raw.used !== "number" ||
    typeof raw.limit !== "number" ||
    typeof raw.remaining !== "number"
  ) {
    return undefined;
  }
  return {
    name: raw.name,
    used: raw.used,
    limit: raw.limit,
    remaining: raw.remaining,
    window: typeof raw.window === "string" ? raw.window : undefined,
    meta: isRecord(raw.meta) ? raw.meta : undefined,
  };
}

export function requireProviderAccountDoc(raw: unknown): ProviderAccountDoc {
  const parsed = parseProviderAccountDoc(raw);
  if (!parsed) {
    throw new Error("Invalid provider account document.");
  }
  return parsed;
}

export function optionalStringField(raw: unknown): string | undefined {
  return typeof raw === "string" ? raw : undefined;
}

export function recordField(raw: unknown, key: string): unknown {
  return isRecord(raw) ? raw[key] : undefined;
}

export function numberField(raw: unknown, key: string): number | undefined {
  const value = recordField(raw, key);
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

export function stringField(raw: unknown, key: string): string | undefined {
  const value = recordField(raw, key);
  return typeof value === "string" ? value : undefined;
}

export function recordArrayField(raw: unknown, key: string): Array<Record<string, unknown>> {
  const value = recordField(raw, key);
  if (!Array.isArray(value)) return [];
  return value.filter(isRecord);
}

export function isStripeSubscription(value: unknown): value is import("stripe").Stripe.Subscription {
  return isRecord(value) && typeof value.id === "string";
}

export function isStripeCheckoutSession(value: unknown): value is import("stripe").Stripe.Checkout.Session {
  return isRecord(value) && typeof value.id === "string";
}

export function stripUndefinedObject(value: object): DocumentData {
  const out: DocumentData = {};
  for (const [key, item] of Object.entries(value)) {
    if (item !== undefined) out[key] = item;
  }
  return out;
}

function parseAppStoreEnvironment(raw: unknown): AppStoreEnvironment | undefined {
  return raw === "Production" || raw === "Sandbox" || raw === "Xcode" || raw === "LocalTesting" ? raw : undefined;
}

function parseHostedQuotaEntitlementSource(raw: unknown): HostedQuotaEntitlementSource | undefined {
  return raw === "apple_jws_verified" || raw === "apple_s2s" || raw === "scheduled_reconcile" ? raw : undefined;
}
