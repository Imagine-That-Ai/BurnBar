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
