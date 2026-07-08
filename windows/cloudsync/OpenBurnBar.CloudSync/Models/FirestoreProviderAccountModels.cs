using System.Text.Json.Serialization;

namespace OpenBurnBar.CloudSync.Models;

// Port of OpenBurnBarFirestoreModels/ProviderAccountModels.swift — Domain: provider-account.
// Firestore: users/{uid}/provider_accounts/{accountID}

public sealed record FirestoreProviderAccountDoc
{
    [JsonPropertyName("id")] public required string Id { get; init; }
    [JsonPropertyName("providerID")] public required string ProviderID { get; init; }
    [JsonPropertyName("label")] public required string Label { get; init; }
    [JsonPropertyName("identityHint")] public string? IdentityHint { get; init; }
    [JsonPropertyName("status")] public required string Status { get; init; }
    [JsonPropertyName("credentialKind")] public required string CredentialKind { get; init; }
    [JsonPropertyName("storageScope")] public required string StorageScope { get; init; }
    [JsonPropertyName("redactedLabel")] public required string RedactedLabel { get; init; }
    [JsonPropertyName("sourceDeviceID")] public string? SourceDeviceID { get; init; }
    [JsonPropertyName("linkedSwitcherProfileID")] public string? LinkedSwitcherProfileID { get; init; }
    [JsonPropertyName("isDefault")] public required bool IsDefault { get; init; }
    [JsonPropertyName("sortKey")] public required long SortKey { get; init; }
    [JsonPropertyName("lastValidatedAt")] public string? LastValidatedAt { get; init; }
    [JsonPropertyName("lastRefreshAt")] public string? LastRefreshAt { get; init; }
    [JsonPropertyName("lastErrorCode")] public string? LastErrorCode { get; init; }
    [JsonPropertyName("endpointProfileID")] public string? EndpointProfileID { get; init; }
    [JsonPropertyName("region")] public string? Region { get; init; }
    [JsonPropertyName("tokenPlanTier")] public string? TokenPlanTier { get; init; }
    [JsonPropertyName("tokenPlanBillingCycle")] public string? TokenPlanBillingCycle { get; init; }
    [JsonPropertyName("authMethodID")] public string? AuthMethodID { get; init; }
    [JsonPropertyName("schemaVersion")] public required long SchemaVersion { get; init; }
    [JsonPropertyName("createdAt")] public required string CreatedAt { get; init; }
    [JsonPropertyName("updatedAt")] public required string UpdatedAt { get; init; }
}

public sealed record FirestoreProviderAccountConnectContext
{
    [JsonPropertyName("endpointProfileID")] public string? EndpointProfileID { get; init; }
    [JsonPropertyName("region")] public string? Region { get; init; }
    [JsonPropertyName("tokenPlanTier")] public string? TokenPlanTier { get; init; }
    [JsonPropertyName("tokenPlanBillingCycle")] public string? TokenPlanBillingCycle { get; init; }
    [JsonPropertyName("authMethodID")] public string? AuthMethodID { get; init; }
}
