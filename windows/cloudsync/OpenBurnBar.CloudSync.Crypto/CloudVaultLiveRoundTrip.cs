using System;
using System.Security.Cryptography;
using System.Text;

namespace OpenBurnBar.CloudSync.Crypto;

/// <summary>
/// Production CloudVault live seal → open round-trip over the same AES-GCM core
/// as Mac. Used for Windows-host C5 proofs and portable unit verification of the
/// live composition path (not KAT-only).
/// </summary>
public static class CloudVaultLiveRoundTrip
{
    /// <summary>
    /// Seal plaintext with a random vault key + AAD, then open and return the recovered
    /// plaintext. Throws if the round-trip fails integrity checks.
    /// </summary>
    public static byte[] SealThenOpen(
        ReadOnlySpan<byte> plaintext,
        string uid,
        string collection,
        string docId,
        string field)
    {
        byte[] vaultKey = RandomNumberGenerator.GetBytes(32);
        var aad = new CloudVaultAadContext(uid, collection, docId, field);
        CloudVaultBlobEnvelope sealedEnvelope = CloudVaultCrypto.SealBlob(
            plaintext.ToArray(),
            vaultKey,
            aadContext: aad);
        byte[] opened = CloudVaultCrypto.OpenBlob(sealedEnvelope, vaultKey, aad);
        if (!CryptographicOperations.FixedTimeEquals(opened, plaintext.ToArray()))
        {
            throw new InvalidOperationException("CloudVault live round-trip plaintext mismatch.");
        }

        return opened;
    }

    /// <summary>UTF-8 convenience wrapper for tests and host smoke scripts.</summary>
    public static string SealThenOpenUtf8(
        string plaintext,
        string uid = "uid-live",
        string collection = "cloud_vault_live",
        string docId = "doc-1",
        string field = "payload")
    {
        byte[] opened = SealThenOpen(Encoding.UTF8.GetBytes(plaintext), uid, collection, docId, field);
        return Encoding.UTF8.GetString(opened);
    }
}
