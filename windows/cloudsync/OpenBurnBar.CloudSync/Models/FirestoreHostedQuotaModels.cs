using System.Text.Json.Serialization;

namespace OpenBurnBar.CloudSync.Models;

// Port of OpenBurnBarFirestoreModels/HostedQuotaModels.swift — Domain: hosted-quota.

public sealed record FirestoreEntitlementBindingDoc
{
    [JsonPropertyName("appAccountToken")] public required string AppAccountToken { get; init; }
    [JsonPropertyName("uid")] public required string Uid { get; init; }
    [JsonPropertyName("createdAt")] public required string CreatedAt { get; init; }
}
