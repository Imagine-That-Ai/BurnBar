using System.Collections.Generic;
using System.Text.Json.Serialization;

namespace OpenBurnBar.CloudSync.Models;

// Port of OpenBurnBarCore/Sources/OpenBurnBarFirestoreModels/ComputerUseModels.swift
// Domain: computer-use. Swift `Int` -> `long` (Swift Int is 64-bit on these hosts;
// publishedAtMillis exceeds Int32). Property names bind to the Swift Codable keys
// verbatim via [JsonPropertyName].

/// <summary>
/// Short-lived, domain-tagged capability token for privileged input leaves
/// (Remote Unlock vs Computer Use). Firestore wire name: capabilityToken.
/// </summary>
public sealed record FirestoreCapabilityToken
{
    [JsonPropertyName("schemaVersion")] public required long SchemaVersion { get; init; }
    [JsonPropertyName("domain")] public required string Domain { get; init; }
    [JsonPropertyName("nonce")] public required string Nonce { get; init; }
    [JsonPropertyName("issuedAt")] public required string IssuedAt { get; init; }
    [JsonPropertyName("expiresAt")] public required string ExpiresAt { get; init; }
    [JsonPropertyName("allowedActionKinds")] public required IReadOnlyList<string> AllowedActionKinds { get; init; }
    [JsonPropertyName("scopeHash")] public required string ScopeHash { get; init; }
    [JsonPropertyName("actionBudget")] public required long ActionBudget { get; init; }
    [JsonPropertyName("boundEscrowDeviceId")] public string? BoundEscrowDeviceId { get; init; }
    [JsonPropertyName("attestationHashBlake3")] public string? AttestationHashBlake3 { get; init; }
    [JsonPropertyName("signatureEd25519Base64")] public string? SignatureEd25519Base64 { get; init; }
}

public sealed record FirestoreComputerUsePhoneAuthorityDoc
{
    [JsonPropertyName("deviceId")] public required string DeviceId { get; init; }
    [JsonPropertyName("connectionId")] public required string ConnectionId { get; init; }
    [JsonPropertyName("peerNodeId")] public required string PeerNodeId { get; init; }
    [JsonPropertyName("publicKeyBase64")] public required string PublicKeyBase64 { get; init; }
    [JsonPropertyName("publishedAtMillis")] public required long PublishedAtMillis { get; init; }
    [JsonPropertyName("protocolVersion")] public required long ProtocolVersion { get; init; }
    [JsonPropertyName("schemaVersion")] public required long SchemaVersion { get; init; }
    [JsonPropertyName("createdAt")] public required string CreatedAt { get; init; }
    [JsonPropertyName("updatedAt")] public required string UpdatedAt { get; init; }
}

public sealed record FirestoreRelaySenderKeyDoc
{
    [JsonPropertyName("id")] public required string Id { get; init; }
    [JsonPropertyName("deviceId")] public required string DeviceId { get; init; }
    [JsonPropertyName("peerNodeId")] public required string PeerNodeId { get; init; }
    [JsonPropertyName("keyId")] public required string KeyId { get; init; }
    [JsonPropertyName("publicKeyBase64")] public required string PublicKeyBase64 { get; init; }
    [JsonPropertyName("relayKeyVersion")] public required long RelayKeyVersion { get; init; }
    [JsonPropertyName("relayEncryption")] public required string RelayEncryption { get; init; }
    [JsonPropertyName("signalIdentityKeyVersion")] public required long SignalIdentityKeyVersion { get; init; }
    [JsonPropertyName("signalIdentityFingerprint")] public required string SignalIdentityFingerprint { get; init; }
    [JsonPropertyName("signalIdentityVerification")] public required string SignalIdentityVerification { get; init; }
    [JsonPropertyName("status")] public required string Status { get; init; }
    [JsonPropertyName("publishedAtMillis")] public required long PublishedAtMillis { get; init; }
    [JsonPropertyName("createdAt")] public required string CreatedAt { get; init; }
    [JsonPropertyName("updatedAt")] public required string UpdatedAt { get; init; }
    [JsonPropertyName("schemaVersion")] public required long SchemaVersion { get; init; }
}

public sealed record FirestoreAgentGrantAuthorityDoc
{
    [JsonPropertyName("id")] public required string Id { get; init; }
    [JsonPropertyName("deviceId")] public required string DeviceId { get; init; }
    [JsonPropertyName("peerNodeId")] public required string PeerNodeId { get; init; }
    [JsonPropertyName("publicKeyBase64")] public required string PublicKeyBase64 { get; init; }
    [JsonPropertyName("authorityKind")] public required string AuthorityKind { get; init; }
    [JsonPropertyName("status")] public required string Status { get; init; }
    [JsonPropertyName("publishedAtMillis")] public required long PublishedAtMillis { get; init; }
    [JsonPropertyName("createdAt")] public required string CreatedAt { get; init; }
    [JsonPropertyName("updatedAt")] public required string UpdatedAt { get; init; }
    [JsonPropertyName("schemaVersion")] public required long SchemaVersion { get; init; }
}
