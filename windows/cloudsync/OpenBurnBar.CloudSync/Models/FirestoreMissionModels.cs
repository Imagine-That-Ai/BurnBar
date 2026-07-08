using System.Text.Json.Serialization;

namespace OpenBurnBar.CloudSync.Models;

// Port of OpenBurnBarFirestoreModels/MissionModels.swift — Domain: missions.

public sealed record FirestoreMissionDispatchDoc
{
    [JsonPropertyName("missionId")] public required string MissionId { get; init; }
    [JsonPropertyName("status")] public required string Status { get; init; }
    [JsonPropertyName("createdAt")] public required string CreatedAt { get; init; }
    [JsonPropertyName("updatedAt")] public string? UpdatedAt { get; init; }
    [JsonPropertyName("payloadSummary")] public string? PayloadSummary { get; init; }
}
