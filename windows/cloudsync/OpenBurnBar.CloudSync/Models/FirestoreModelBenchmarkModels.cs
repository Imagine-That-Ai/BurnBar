using System.Text.Json.Serialization;

namespace OpenBurnBar.CloudSync.Models;

// Port of OpenBurnBarFirestoreModels/ModelBenchmarkModels.swift — Domain: model-benchmarks.

/// Firestore: model_benchmark_snapshots/{source_model_task_timestamp}
public sealed record FirestoreModelBenchmarkSnapshotDoc
{
    [JsonPropertyName("id")] public required string Id { get; init; }
    [JsonPropertyName("source")] public required string Source { get; init; }
    [JsonPropertyName("sourceURL")] public string? SourceURL { get; init; }
    [JsonPropertyName("attribution")] public string? Attribution { get; init; }
    [JsonPropertyName("fetchedAt")] public required string FetchedAt { get; init; }
    [JsonPropertyName("modelID")] public required string ModelID { get; init; }
    [JsonPropertyName("providerID")] public string? ProviderID { get; init; }
    [JsonPropertyName("taskCategory")] public required string TaskCategory { get; init; }
    [JsonPropertyName("score")] public double? Score { get; init; }
    [JsonPropertyName("rank")] public long? Rank { get; init; }
    [JsonPropertyName("costSignal")] public double? CostSignal { get; init; }
    [JsonPropertyName("inputCostPerMtoken")] public double? InputCostPerMtoken { get; init; }
    [JsonPropertyName("outputCostPerMtoken")] public double? OutputCostPerMtoken { get; init; }
    [JsonPropertyName("blendedCostPerMtoken")] public double? BlendedCostPerMtoken { get; init; }
    [JsonPropertyName("latencySignal")] public double? LatencySignal { get; init; }
    [JsonPropertyName("contextWindowTokens")] public long? ContextWindowTokens { get; init; }
    [JsonPropertyName("reliabilitySignal")] public double? ReliabilitySignal { get; init; }
    [JsonPropertyName("confidence")] public double? Confidence { get; init; }
    [JsonPropertyName("freshness")] public required string Freshness { get; init; }
    [JsonPropertyName("schemaVersion")] public required long SchemaVersion { get; init; }
    [JsonPropertyName("updatedAt")] public required string UpdatedAt { get; init; }
}

/// Firestore: model_benchmark_source_status/{source}
public sealed record FirestoreModelBenchmarkSourceStatusDoc
{
    [JsonPropertyName("source")] public required string Source { get; init; }
    [JsonPropertyName("status")] public required string Status { get; init; }
    [JsonPropertyName("fetchedAt")] public string? FetchedAt { get; init; }
    [JsonPropertyName("message")] public required string Message { get; init; }
    [JsonPropertyName("attribution")] public string? Attribution { get; init; }
    [JsonPropertyName("schemaVersion")] public required long SchemaVersion { get; init; }
    [JsonPropertyName("updatedAt")] public required string UpdatedAt { get; init; }
}
