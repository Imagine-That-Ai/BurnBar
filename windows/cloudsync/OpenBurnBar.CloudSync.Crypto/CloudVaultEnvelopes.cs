using System.Text.Json.Serialization;

namespace OpenBurnBar.CloudSync.Crypto
{
    /// <summary>
    /// The at-rest AES-256-GCM detached envelope for a short encrypted string —
    /// the C# mirror of Swift <c>CloudVaultSealedText</c>. <see cref="SchemaVersion"/>
    /// is <c>null</c> for a legacy v1 (no-AAD) seal and <c>2</c> for a path-bound v2
    /// seal. Nonce / ciphertext / tag are Base64. The plaintext is never present.
    /// </summary>
    public sealed record CloudVaultSealedText(
        [property: JsonPropertyName("schemaVersion")]
        int? SchemaVersion,
        [property: JsonPropertyName("algorithm")]
        string Algorithm,
        [property: JsonPropertyName("keyVersion")]
        int KeyVersion,
        [property: JsonPropertyName("nonce")]
        string Nonce,
        [property: JsonPropertyName("ciphertext")]
        string Ciphertext,
        [property: JsonPropertyName("tag")]
        string Tag,
        [property: JsonPropertyName("aad")]
        string? Aad);

    /// <summary>
    /// The at-rest AES-256-GCM combined envelope for an encrypted blob — the C#
    /// mirror of Swift <c>CloudVaultBlobEnvelope</c>. <see cref="SealedBoxBase64"/>
    /// is <c>nonce(12) || ciphertext || tag(16)</c>. Integrity is a vault-keyed
    /// plaintext HMAC (<see cref="PlaintextHmac"/>, <see cref="IntegrityHashVersion"/>)
    /// so a reader detects a swapped-but-validly-tagged body. (The non-authenticated
    /// <c>createdAt</c> field of the Firestore document is intentionally omitted —
    /// it is not part of the AEAD and does not affect byte parity.)
    /// </summary>
    public sealed record CloudVaultBlobEnvelope(
        [property: JsonPropertyName("schemaVersion")]
        int SchemaVersion,
        [property: JsonPropertyName("algorithm")]
        string Algorithm,
        [property: JsonPropertyName("keyVersion")]
        int KeyVersion,
        [property: JsonPropertyName("plaintextSHA256")]
        string? PlaintextSha256,
        [property: JsonPropertyName("plaintextHMAC")]
        string? PlaintextHmac,
        [property: JsonPropertyName("integrityHashVersion")]
        int? IntegrityHashVersion,
        [property: JsonPropertyName("sealedBoxBase64")]
        string SealedBoxBase64,
        [property: JsonPropertyName("aad")]
        string? Aad);

    /// <summary>
    /// The at-rest AES-256-GCM combined envelope for a structured payload — the C#
    /// mirror of Swift <c>CloudVaultSealedPayload</c>. Bound to
    /// <see cref="VaultKeyId"/> so an opener refuses a payload sealed under a
    /// different vault key. <see cref="SealedBoxBase64"/> is the combined box.
    /// </summary>
    public sealed record CloudVaultSealedPayload(
        [property: JsonPropertyName("schemaVersion")]
        int SchemaVersion,
        [property: JsonPropertyName("algorithm")]
        string Algorithm,
        [property: JsonPropertyName("keyVersion")]
        int KeyVersion,
        [property: JsonPropertyName("vaultKeyID")]
        string VaultKeyId,
        [property: JsonPropertyName("sealedBoxBase64")]
        string SealedBoxBase64,
        [property: JsonPropertyName("aad")]
        string? Aad);
}
