using System.Text.Json.Serialization;

namespace OpenBurnBar.CloudSync.Models;

// Port of OpenBurnBarFirestoreModels/HostedQuotaModels.swift — Domain: hosted-quota.

public sealed record FirestoreEntitlementBindingDoc
{
    [JsonPropertyName("id")] public required string Id { get; init; }
    [JsonPropertyName("appAccountToken")] public required string AppAccountToken { get; init; }
    [JsonPropertyName("uid")] public required string Uid { get; init; }
    [JsonPropertyName("productID")] public required string ProductId { get; init; }
    [JsonPropertyName("clientPlatform")] public string? ClientPlatform { get; init; }
    [JsonPropertyName("consumedAt")] public string? ConsumedAt { get; init; }
    [JsonPropertyName("createdAt")] public required string CreatedAt { get; init; }
    [JsonPropertyName("schemaVersion")] public required int SchemaVersion { get; init; }
}
