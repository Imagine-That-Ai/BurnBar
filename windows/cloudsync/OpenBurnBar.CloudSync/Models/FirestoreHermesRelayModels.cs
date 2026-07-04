using System.Text.Json.Serialization;

namespace OpenBurnBar.CloudSync.Models;

// Port of OpenBurnBarFirestoreModels/HermesRelayModels.swift — Domain: hermes-relay.

public sealed record FirestoreHermesRelayRequestDoc
{
    [JsonPropertyName("operation")] public required string Operation { get; init; }
    [JsonPropertyName("status")] public required string Status { get; init; }
    [JsonPropertyName("sessionId")] public string? SessionId { get; init; }
    [JsonPropertyName("createdAt")] public required string CreatedAt { get; init; }
    [JsonPropertyName("updatedAt")] public string? UpdatedAt { get; init; }
}

public sealed record FirestoreHermesRelayChunkDoc
{
    [JsonPropertyName("requestId")] public required string RequestId { get; init; }
    [JsonPropertyName("chunkIndex")] public required long ChunkIndex { get; init; }
    [JsonPropertyName("payloadBase64")] public required string PayloadBase64 { get; init; }
    [JsonPropertyName("createdAt")] public required string CreatedAt { get; init; }
}
