// CNG/TPM-backed implementations of the portable handshake crypto seams.
//
// This is the point where the portable signed-nonce state machine
// (OpenBurnBar.Pal.Ipc) meets real Windows crypto: the local signer is an
// ECDSA-P256 key held in a non-exportable CNG key (backed by the Microsoft
// Platform Crypto Provider / TPM where available, per R15), and the peer verifier
// is that peer's pinned public key. The wire format and the transcript are shared
// with the macOS ECDSA test credentials, so VAL-P0-CONPTY-019 re-runs the exact
// same handshake assertions with these credentials on Windows.
//
// Scaffold for VAL-P0-CONPTY-018 (compiles on macOS; CngKey throws off-Windows at
// runtime). Provisioning the TPM key and pinning the peer key are wired here; the
// live round-trip is CONPTY-019.

using System;
using System.Security.Cryptography;
using OpenBurnBar.Pal.Ipc;

namespace OpenBurnBar.Pal.Ipc.Windows;

/// <summary>
/// Signs handshake transcripts with a non-exportable CNG ECDSA-P256 key.
/// </summary>
public sealed class CngNonceSigner : INonceSigner, IDisposable
{
    private readonly ECDsaCng _ecdsa;

    /// <param name="key">A CNG key handle. In production this is opened from the
    /// Microsoft Platform Crypto Provider (TPM), created non-exportable and
    /// Hello-gated for RELEASE (R15). Ownership transfers to this signer.</param>
    public CngNonceSigner(CngKey key)
    {
        ArgumentNullException.ThrowIfNull(key);
        _ecdsa = new ECDsaCng(key);
    }

    public byte[] Sign(ReadOnlySpan<byte> message) =>
        _ecdsa.SignData(message, HashAlgorithmName.SHA256);

    /// <summary>Exports this signer's PUBLIC key for pinning by the peer.</summary>
    public byte[] ExportPublicKey() => _ecdsa.ExportSubjectPublicKeyInfo();

    public void Dispose() => _ecdsa.Dispose();
}

/// <summary>
/// Verifies handshake transcripts against a peer's pinned ECDSA-P256 public key.
/// </summary>
public sealed class CngNonceVerifier : INonceVerifier, IDisposable
{
    private readonly ECDsa _ecdsa;

    /// <param name="peerPublicKeySpki">The peer's pinned public key, in
    /// SubjectPublicKeyInfo (SPKI) DER — the format
    /// <see cref="CngNonceSigner.ExportPublicKey"/> produces. Pinning the exact
    /// key is what makes the handshake meaningful: a squatter without the pinned
    /// private key cannot produce a passing signature.</param>
    public CngNonceVerifier(byte[] peerPublicKeySpki)
    {
        ArgumentNullException.ThrowIfNull(peerPublicKeySpki);
        _ecdsa = ECDsa.Create();
        _ecdsa.ImportSubjectPublicKeyInfo(peerPublicKeySpki, out _);
    }

    public bool Verify(ReadOnlySpan<byte> message, ReadOnlySpan<byte> signature) =>
        _ecdsa.VerifyData(message, signature, HashAlgorithmName.SHA256);

    public void Dispose() => _ecdsa.Dispose();
}

/// <summary>
/// Helpers for provisioning the local CNG key in the TPM-backed provider.
/// </summary>
public static class CngNonceKeyProvisioning
{
    /// <summary>The provider that binds keys to the TPM when present (R15).</summary>
    public const string PlatformCryptoProvider = "Microsoft Platform Crypto Provider";

    /// <summary>
    /// Opens (or, when absent, creates) a persisted, non-exportable ECDSA-P256
    /// key under the platform crypto provider. The created key never leaves the
    /// TPM; only its public half is exportable for the peer to pin.
    /// </summary>
    /// <remarks>
    /// CONPTY-019: prove on a TPM-equipped Windows host that
    /// <see cref="CngKey.Open(string, CngProvider)"/> returns a key whose
    /// <see cref="CngExportPolicies"/> forbids private-key export.
    /// </remarks>
    public static CngKey OpenOrCreatePersistedKey(string keyName)
    {
        ArgumentException.ThrowIfNullOrEmpty(keyName);

        var provider = new CngProvider(PlatformCryptoProvider);
        if (CngKey.Exists(keyName, provider))
        {
            return CngKey.Open(keyName, provider);
        }

        var creationParameters = new CngKeyCreationParameters
        {
            Provider = provider,
            KeyCreationOptions = CngKeyCreationOptions.None,
            ExportPolicy = CngExportPolicies.None, // non-exportable private key (R15)
        };

        return CngKey.Create(CngAlgorithm.ECDsaP256, keyName, creationParameters);
    }
}
