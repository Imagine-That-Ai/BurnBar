using System.Text.Json.Serialization;

namespace OpenBurnBar.CloudSync.Models;

// Port of OpenBurnBarFirestoreModels/DeviceLinkModels.swift — Domain: device-links.
// Firestore: users/{uid}/provider_account_device_links/{accountID}_{deviceID}

public sealed record FirestoreProviderAccountDeviceLinkDoc
{
    [JsonPropertyName("id")] public required string Id { get; init; }
    [JsonPropertyName("accountID")] public required string AccountID { get; init; }
    [JsonPropertyName("deviceID")] public required string DeviceID { get; init; }
    [JsonPropertyName("deviceDisplayName")] public required string DeviceDisplayName { get; init; }
    [JsonPropertyName("capability")] public required string Capability { get; init; }
    [JsonPropertyName("status")] public required string Status { get; init; }
    [JsonPropertyName("lastObservedAt")] public required string LastObservedAt { get; init; }
    [JsonPropertyName("createdAt")] public required string CreatedAt { get; init; }
    [JsonPropertyName("updatedAt")] public required string UpdatedAt { get; init; }
    [JsonPropertyName("schemaVersion")] public required long SchemaVersion { get; init; }
}
