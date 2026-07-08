using System.Text.Json.Serialization;

namespace OpenBurnBar.CloudSync.Models;

// Port of OpenBurnBarCore/Sources/OpenBurnBarFirestoreModels/ComputerUseModels.swift
// Domain: computer-use. Swift `Int` -> `long` (Swift Int is 64-bit on these hosts;
// publishedAtMillis exceeds Int32). Property names bind to the Swift Codable keys
// verbatim via [JsonPropertyName].

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
