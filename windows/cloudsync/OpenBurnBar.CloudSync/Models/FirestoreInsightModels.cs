using System.Text.Json.Serialization;

namespace OpenBurnBar.CloudSync.Models;

// Port of OpenBurnBarFirestoreModels/InsightModels.swift — Domain: insights.

public sealed record FirestoreInsightCanvasDoc
{
    [JsonPropertyName("id")] public required string Id { get; init; }
    [JsonPropertyName("title")] public required string Title { get; init; }
    [JsonPropertyName("theme")] public required string Theme { get; init; }
    [JsonPropertyName("origin")] public required string Origin { get; init; }
    [JsonPropertyName("updatedAt")] public required string UpdatedAt { get; init; }
}
