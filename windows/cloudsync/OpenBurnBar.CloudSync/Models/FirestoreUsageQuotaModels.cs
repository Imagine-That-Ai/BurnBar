using System.Collections.Generic;
using System.Text.Json.Serialization;

namespace OpenBurnBar.CloudSync.Models;

// Port of OpenBurnBarFirestoreModels/UsageQuotaModels.swift — Domain: usage-quota.

/// Firestore: users/{uid}/usage/{docId}
public sealed record FirestoreUsageEventDoc
{
    [JsonPropertyName("provider")] public required string Provider { get; init; }
    [JsonPropertyName("providerID")] public string? ProviderID { get; init; }
    [JsonPropertyName("providerAccountID")] public string? ProviderAccountID { get; init; }
    [JsonPropertyName("providerAccountLabel")] public string? ProviderAccountLabel { get; init; }
    [JsonPropertyName("providerAccountSource")] public string? ProviderAccountSource { get; init; }
    [JsonPropertyName("model")] public string? Model { get; init; }
    [JsonPropertyName("sessionId")] public string? SessionId { get; init; }
    [JsonPropertyName("deviceId")] public string? DeviceId { get; init; }
    [JsonPropertyName("sourceDeviceId")] public string? SourceDeviceId { get; init; }
    [JsonPropertyName("executionSourceID")] public string? ExecutionSourceID { get; init; }
    [JsonPropertyName("executionSourceName")] public string? ExecutionSourceName { get; init; }
    [JsonPropertyName("executionSourceKind")] public string? ExecutionSourceKind { get; init; }
    [JsonPropertyName("executionSourceConfidence")] public string? ExecutionSourceConfidence { get; init; }
    [JsonPropertyName("inputTokens")] public long? InputTokens { get; init; }
    [JsonPropertyName("outputTokens")] public long? OutputTokens { get; init; }
    [JsonPropertyName("cacheReadTokens")] public long? CacheReadTokens { get; init; }
    [JsonPropertyName("cacheWriteTokens")] public long? CacheWriteTokens { get; init; }
    [JsonPropertyName("totalTokens")] public long? TotalTokens { get; init; }
    [JsonPropertyName("costUSD")] public double? CostUSD { get; init; }
    [JsonPropertyName("currency")] public string? Currency { get; init; }
    [JsonPropertyName("recordedAt")] public required string RecordedAt { get; init; }
    [JsonPropertyName("eventKind")] public string? EventKind { get; init; }
    [JsonPropertyName("idempotencyKey")] public string? IdempotencyKey { get; init; }
}

public sealed record FirestoreQuotaBucket
{
    [JsonPropertyName("name")] public required string Name { get; init; }
    [JsonPropertyName("used")] public double? Used { get; init; }
    [JsonPropertyName("limit")] public double? Limit { get; init; }
    [JsonPropertyName("unit")] public string? Unit { get; init; }
    [JsonPropertyName("resetAt")] public string? ResetAt { get; init; }
}

/// Firestore: users/{uid}/quota_snapshots/{snapshotId}
public sealed record FirestoreQuotaSnapshotDoc
{
    [JsonPropertyName("sourceKind")] public required string SourceKind { get; init; }
    [JsonPropertyName("sourceId")] public required string SourceId { get; init; }
    [JsonPropertyName("provider")] public required string Provider { get; init; }
    [JsonPropertyName("providerID")] public string? ProviderID { get; init; }
    [JsonPropertyName("accountID")] public string? AccountID { get; init; }
    [JsonPropertyName("accountLabel")] public string? AccountLabel { get; init; }
    [JsonPropertyName("accountStorageScope")] public string? AccountStorageScope { get; init; }
    [JsonPropertyName("fetchedAt")] public required string FetchedAt { get; init; }
    [JsonPropertyName("sourceLabel")] public string? SourceLabel { get; init; }
    [JsonPropertyName("buckets")] public IReadOnlyList<FirestoreQuotaBucket>? Buckets { get; init; }
    [JsonPropertyName("resetAt")] public string? ResetAt { get; init; }
    [JsonPropertyName("planTier")] public string? PlanTier { get; init; }
}
