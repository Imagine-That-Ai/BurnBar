using System.Text.Json.Serialization;

namespace OpenBurnBar.CloudSync.Models;

// Port of OpenBurnBarFirestoreModels/PiAgentRelayModels.swift — Domain: pi-agent-relay.

public sealed record FirestorePiAgentConnectionDoc
{
    [JsonPropertyName("mode")] public required string Mode { get; init; }
    [JsonPropertyName("status")] public required string Status { get; init; }
    [JsonPropertyName("endpointURL")] public string? EndpointURL { get; init; }
    [JsonPropertyName("createdAt")] public required string CreatedAt { get; init; }
    [JsonPropertyName("updatedAt")] public string? UpdatedAt { get; init; }
}
