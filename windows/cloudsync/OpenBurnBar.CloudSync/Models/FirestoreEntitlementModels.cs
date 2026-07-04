using System.Text.Json.Serialization;

namespace OpenBurnBar.CloudSync.Models;

// Port of OpenBurnBarFirestoreModels/EntitlementModels.swift — Domain: entitlements.

public sealed record FirestoreEscrowDeviceDoc
{
    [JsonPropertyName("deviceId")] public required string DeviceId { get; init; }
    [JsonPropertyName("trustState")] public required string TrustState { get; init; }
    [JsonPropertyName("registeredAt")] public required string RegisteredAt { get; init; }
    [JsonPropertyName("approvedAt")] public string? ApprovedAt { get; init; }
}
