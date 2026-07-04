namespace OpenBurnBar.CloudSync.Crypto
{
    /// <summary>
    /// The at-rest AES-256-GCM detached envelope for a short encrypted string —
    /// the C# mirror of Swift <c>CloudVaultSealedText</c>. <see cref="SchemaVersion"/>
    /// is <c>null</c> for a legacy v1 (no-AAD) seal and <c>2</c> for a path-bound v2
    /// seal. Nonce / ciphertext / tag are Base64. The plaintext is never present.
    /// </summary>
    public sealed record CloudVaultSealedText(
        int? SchemaVersion,
        string Algorithm,
        int KeyVersion,
        string Nonce,
        string Ciphertext,
        string Tag,
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
        int SchemaVersion,
        string Algorithm,
        int KeyVersion,
        string? PlaintextSha256,
        string? PlaintextHmac,
        int? IntegrityHashVersion,
        string SealedBoxBase64,
        string? Aad);

    /// <summary>
    /// The at-rest AES-256-GCM combined envelope for a structured payload — the C#
    /// mirror of Swift <c>CloudVaultSealedPayload</c>. Bound to
    /// <see cref="VaultKeyId"/> so an opener refuses a payload sealed under a
    /// different vault key. <see cref="SealedBoxBase64"/> is the combined box.
    /// </summary>
    public sealed record CloudVaultSealedPayload(
        int SchemaVersion,
        string Algorithm,
        int KeyVersion,
        string VaultKeyId,
        string SealedBoxBase64,
        string? Aad);
}
