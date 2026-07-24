using System.Text.Json.Serialization;

namespace OpenBurnBar.CloudSync.Models;

// Port of OpenBurnBarFirestoreModels/IrohPairingModels.swift — Domain: iroh-pairing.

public sealed record FirestoreIrohPairingDoc
{
    [JsonPropertyName("pairingCodeDigest")] public required string PairingCodeDigest { get; init; }
    [JsonPropertyName("status")] public required string Status { get; init; }
    [JsonPropertyName("createdAt")] public required string CreatedAt { get; init; }
    [JsonPropertyName("expiresAt")] public required string ExpiresAt { get; init; }
    [JsonPropertyName("platform")] public string? Platform { get; init; }
}

public sealed record FirestoreIrohControllerRouteDoc
{
    [JsonPropertyName("connectionId")] public required string ConnectionId { get; init; }
    [JsonPropertyName("sourceDeviceId")] public required string SourceDeviceId { get; init; }
    [JsonPropertyName("transportNodeId")] public required string TransportNodeId { get; init; }
    [JsonPropertyName("authorityPeerNodeId")] public required string AuthorityPeerNodeId { get; init; }
    [JsonPropertyName("authorityPublicKeySHA256")] public required string AuthorityPublicKeySHA256 { get; init; }
    [JsonPropertyName("status")] public required string Status { get; init; }
    [JsonPropertyName("generation")] public required long Generation { get; init; }
    [JsonPropertyName("registeredAtMillis")] public required long RegisteredAtMillis { get; init; }
    [JsonPropertyName("expiresAtMillis")] public required long ExpiresAtMillis { get; init; }
    [JsonPropertyName("revokedAtMillis")] public long? RevokedAtMillis { get; init; }
    [JsonPropertyName("schemaVersion")] public required long SchemaVersion { get; init; }
    [JsonPropertyName("updatedAt")] public required string UpdatedAt { get; init; }
}

public sealed record FirestoreIrohControllerRouteChallengeDoc
{
    [JsonPropertyName("challengeId")] public required string ChallengeId { get; init; }
    [JsonPropertyName("challengeNonce")] public required string ChallengeNonce { get; init; }
    [JsonPropertyName("connectionId")] public required string ConnectionId { get; init; }
    [JsonPropertyName("sourceDeviceId")] public required string SourceDeviceId { get; init; }
    [JsonPropertyName("transportNodeId")] public required string TransportNodeId { get; init; }
    [JsonPropertyName("authorityPeerNodeId")] public required string AuthorityPeerNodeId { get; init; }
    [JsonPropertyName("proofKind")] public required string ProofKind { get; init; }
    [JsonPropertyName("expectedPriorGeneration")] public required long ExpectedPriorGeneration { get; init; }
    [JsonPropertyName("expectedRegisteredAtMillis")] public long? ExpectedRegisteredAtMillis { get; init; }
    [JsonPropertyName("registrationGeneration")] public required long RegistrationGeneration { get; init; }
    [JsonPropertyName("canonicalPayloadBase64")] public required string CanonicalPayloadBase64 { get; init; }
    [JsonPropertyName("issuedAtMillis")] public required long IssuedAtMillis { get; init; }
    [JsonPropertyName("expiresAtMillis")] public required long ExpiresAtMillis { get; init; }
    [JsonPropertyName("status")] public required string Status { get; init; }
    [JsonPropertyName("consumedAtMillis")] public long? ConsumedAtMillis { get; init; }
    [JsonPropertyName("schemaVersion")] public required long SchemaVersion { get; init; }
    [JsonPropertyName("expireAt")] public required string ExpireAt { get; init; }
}
