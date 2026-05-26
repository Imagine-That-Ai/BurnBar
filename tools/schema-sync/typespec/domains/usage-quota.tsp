/**
 * Usage, quota, and rollup Firestore document contracts.
 * Collection paths documented in manifest.json.
 */
namespace OpenBurnBar.Firestore.UsageQuota;

/** Firestore: users/{uid}/usage/{docId} */
model UsageEventDoc {
  provider: string;
  providerID?: string;
  providerAccountID?: string;
  providerAccountLabel?: string;
  providerAccountSource?: string;
  model?: string;
  sessionId?: string;
  deviceId?: string;
  sourceDeviceId?: string;
  inputTokens?: int32;
  outputTokens?: int32;
  cacheReadTokens?: int32;
  cacheWriteTokens?: int32;
  totalTokens?: int32;
  costUSD?: float32;
  currency?: string;
  recordedAt: string;
  eventKind?: string;
  idempotencyKey?: string;
}

/** Firestore: users/{uid}/usage_rollups/{windowKey} */
model UsageRollupDoc {
  today: float32;
  @encodedName("7d") sevenDay: float32;
  @encodedName("30d") thirtyDay: float32;
  @encodedName("90d") ninetyDay: float32;
  all_time: float32;
  totals: Record<float32>;
  providerSummaries: ProviderSummary[];
  accountSummaries?: ProviderAccountSummary[];
  modelSummaries: ModelSummary[];
  deviceSummaries: DeviceSummary[];
  dailyPoints: Record<float32>;
  updatedAt?: string;
}

model ProviderSummary {
  provider: string;
  providerID?: string;
  totalCostUSD?: float32;
  totalTokens?: int32;
}

model ProviderAccountSummary {
  accountID: string;
  providerID?: string;
  label?: string;
  totalCostUSD?: float32;
}

model ModelSummary {
  model: string;
  provider?: string;
  totalCostUSD?: float32;
  totalTokens?: int32;
}

model DeviceSummary {
  deviceId: string;
  totalCostUSD?: float32;
  totalTokens?: int32;
}

/** Firestore: users/{uid}/quota_snapshots/{provider}_{sourceId} */
model QuotaSnapshotDoc {
  sourceKind: "provider";
  sourceId: string;
  provider: string;
  providerID?: string;
  accountID?: string;
  accountLabel?: string;
  accountStorageScope?: string;
  fetchedAt: string;
  sourceLabel?: string;
  buckets?: QuotaBucket[];
  resetAt?: string;
  planTier?: string;
}

model QuotaBucket {
  name: string;
  used?: float32;
  limit?: float32;
  unit?: string;
  resetAt?: string;
}
