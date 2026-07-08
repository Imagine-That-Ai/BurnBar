using System;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.CloudSync.AppCheck.Attestation;
using OpenBurnBar.CloudSync.AppCheck.Mint;
using OpenBurnBar.CloudSync.AppCheck.Windows.Interop;

namespace OpenBurnBar.CloudSync.AppCheck.Windows;

/// <summary>
/// The REAL Windows TPM attestation producer: it creates a TPM-backed key inside
/// the Microsoft Platform Crypto Provider and attests it with CNG
/// <c>NCryptCreateClaim(NCRYPT_CLAIM_PLATFORM)</c>, binding a single-use nonce, to
/// prove the client is a genuine, unmodified app on genuine hardware.
/// </summary>
/// <remarks>
/// STATUS — R14 / AC-013 / DEV-HOST DEFERRED. This adapter Roslyn-compiles on the
/// macOS authoring host (<c>EnableWindowsTargeting</c>) and is the seam the WinUI
/// app wires in place of <see cref="MockAttestationProducer"/>, but it RUNS only on
/// a Windows host with a TPM: the CNG P/Invokes here need a real Platform Crypto
/// Provider. The end-to-end TPM verify also needs AC-013's server-side TPM verifier
/// (the server today registers ONLY the mock verifier; its production registry has
/// a reserved <c>verifiers.set("tpm", ...)</c> slot). Until AC-013 lands the server
/// verifier + finalizes the claim wire encoding, the <see cref="WindowsAttestationClaim.Mac"/>
/// field carries a PROVISIONAL base64 of the raw platform-claim blob. THIS DOES NOT
/// WEAKEN THE GATE: the server only mints when an accepting verifier proves the
/// claim; a provisional/unverifiable claim mints nothing.
///
/// Fail-closed: any failure to reach the TPM / produce a claim throws
/// <see cref="AppCheckMintException"/> with <see cref="AppCheckMintFailure.AttestationUnavailable"/>
/// — never a fabricated claim. The mock path (macOS tests) never touches this class.
/// </remarks>
[SupportedOSPlatform("windows")]
public sealed class TpmAttestationProducer : IAttestationProducer
{
    /// <summary>The persisted TPM attestation key name (stable per install).</summary>
    public const string DefaultKeyName = "OpenBurnBar.AppCheck.PlatformAttestationKey.v1";

    /// <summary>The attestation kind AC-013's server verifier will answer to.</summary>
    public const string TpmKind = "tpm";

    private readonly string _keyName;
    private readonly INonceSource _nonceSource;

    public TpmAttestationProducer(string? keyName = null, INonceSource? nonceSource = null)
    {
        _keyName = string.IsNullOrWhiteSpace(keyName) ? DefaultKeyName : keyName!;
        _nonceSource = nonceSource ?? new RandomNonceSource();
    }

    /// <inheritdoc />
    public string Kind => TpmKind;

    /// <inheritdoc />
    public ValueTask<WindowsAttestationClaim> ProduceAsync(
        string appId,
        long nowMillis,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrEmpty(appId))
        {
            throw new ArgumentException("appId is required to bind the attestation.", nameof(appId));
        }
        cancellationToken.ThrowIfCancellationRequested();

        if (!OperatingSystem.IsWindows())
        {
            // Fail closed on the wrong platform rather than fabricate a claim.
            throw AppCheckMintException.AttestationUnavailable(
                "TPM attestation requires a Windows host with a Platform Crypto Provider.");
        }

        var nonce = _nonceSource.NextNonce();
        var claimBlob = CreatePlatformClaim(nonce, cancellationToken);
        var mac = Convert.ToBase64String(claimBlob);

        var claim = new WindowsAttestationClaim
        {
            Kind = TpmKind,
            AppId = appId,
            Nonce = nonce,
            IssuedAtMs = nowMillis,
            Mac = mac, // PROVISIONAL: raw platform-claim blob, base64. Finalized by AC-013.
        };
        return new ValueTask<WindowsAttestationClaim>(claim);
    }

    /// <summary>
    /// Create a TPM platform key-attestation claim over <paramref name="nonce"/>.
    /// Every native handle is released in reverse order; any CNG failure fails
    /// closed as <see cref="AppCheckMintFailure.AttestationUnavailable"/>.
    /// </summary>
    private byte[] CreatePlatformClaim(string nonce, CancellationToken cancellationToken)
    {
        var provider = IntPtr.Zero;
        var subjectKey = IntPtr.Zero;
        var nonceBufferPtr = IntPtr.Zero;
        var bufferDescPtr = IntPtr.Zero;

        try
        {
            Check(NCryptNative.NCryptOpenStorageProvider(
                out provider, NCryptNative.PlatformCryptoProvider, 0), "NCryptOpenStorageProvider");

            subjectKey = OpenOrCreateAttestationKey(provider);

            // Bind the nonce as the key-attestation nonce so the resulting claim is
            // fresh and single-use (defeats replay of a captured claim).
            var nonceBytes = System.Text.Encoding.UTF8.GetBytes(nonce);
            nonceBufferPtr = Marshal.AllocHGlobal(nonceBytes.Length);
            Marshal.Copy(nonceBytes, 0, nonceBufferPtr, nonceBytes.Length);

            var nonceBuffer = new NCryptNative.NCryptBuffer
            {
                cbBuffer = nonceBytes.Length,
                BufferType = NCryptNative.NCRYPTBUFFER_CLAIM_KEYATTESTATION_NONCE,
                pvBuffer = nonceBufferPtr,
            };
            bufferDescPtr = Marshal.AllocHGlobal(Marshal.SizeOf<NCryptNative.NCryptBuffer>());
            Marshal.StructureToPtr(nonceBuffer, bufferDescPtr, false);

            var desc = new NCryptNative.NCryptBufferDesc
            {
                ulVersion = NCryptNative.NCRYPTBUFFER_VERSION,
                cBuffers = 1,
                pBuffers = bufferDescPtr,
            };

            cancellationToken.ThrowIfCancellationRequested();

            // First pass: size the claim blob.
            Check(NCryptNative.NCryptCreateClaim(
                subjectKey,
                IntPtr.Zero, // platform claim uses the TPM's attestation identity key
                NCryptNative.NCRYPT_CLAIM_PLATFORM,
                ref desc,
                null,
                0,
                out var claimSize,
                0), "NCryptCreateClaim(size)");

            if (claimSize <= 0)
            {
                throw AppCheckMintException.AttestationUnavailable("TPM returned an empty claim size.");
            }

            var claimBlob = new byte[claimSize];
            Check(NCryptNative.NCryptCreateClaim(
                subjectKey,
                IntPtr.Zero,
                NCryptNative.NCRYPT_CLAIM_PLATFORM,
                ref desc,
                claimBlob,
                claimBlob.Length,
                out _,
                0), "NCryptCreateClaim(fill)");

            return claimBlob;
        }
        catch (AppCheckMintException)
        {
            throw;
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            throw AppCheckMintException.AttestationUnavailable(ex.Message, ex);
        }
        finally
        {
            if (bufferDescPtr != IntPtr.Zero) Marshal.FreeHGlobal(bufferDescPtr);
            if (nonceBufferPtr != IntPtr.Zero) Marshal.FreeHGlobal(nonceBufferPtr);
            if (subjectKey != IntPtr.Zero) NCryptNative.NCryptFreeObject(subjectKey);
            if (provider != IntPtr.Zero) NCryptNative.NCryptFreeObject(provider);
        }
    }

    private IntPtr OpenOrCreateAttestationKey(IntPtr provider)
    {
        // Reuse a persisted key across launches; create + finalize it on first use.
        var status = NCryptNative.NCryptOpenKey(provider, out var key, _keyName, 0, 0);
        if (status == NCryptNative.ERROR_SUCCESS)
        {
            return key;
        }

        Check(NCryptNative.NCryptCreatePersistedKey(
            provider,
            out key,
            NCryptNative.BCRYPT_ECDSA_P256_ALGORITHM,
            _keyName,
            0,
            0), "NCryptCreatePersistedKey");
        Check(NCryptNative.NCryptFinalizeKey(key, 0), "NCryptFinalizeKey");
        return key;
    }

    private static void Check(int status, string api)
    {
        if (status != NCryptNative.ERROR_SUCCESS)
        {
            // CNG returns an NTSTATUS-shaped code; surface it for the dev-host log.
            throw AppCheckMintException.AttestationUnavailable(
                $"{api} failed (0x{status:X8}).");
        }
    }
}
