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
/// prove possession of a hardware-backed installation key.
/// </summary>
/// <remarks>
/// This adapter cross-compiles on the macOS authoring host but runs only on a
/// Windows host with a TPM. It binds the server challenge, exports the public
/// half of the non-exportable TPM-backed subject key, and sends both to the
/// Windows-hosted <c>NCryptVerifyClaim</c> service through the mint backend.
///
/// Fail-closed: any failure to reach the TPM / produce a claim throws
/// <see cref="AppCheckMintException"/> with <see cref="AppCheckMintFailure.AttestationUnavailable"/>
/// — never a fabricated claim. The mock path (macOS tests) never touches this class.
/// </remarks>
[SupportedOSPlatform("windows")]
public sealed class TpmAttestationProducer : IAttestationProducer
{
    /// <summary>The persisted TPM attestation key name (stable per install).</summary>
    public const string DefaultKeyName = "OpenBurnBar.AppCheck.PlatformAttestationKey.v2";

    /// <summary>The attestation kind AC-013's server verifier will answer to.</summary>
    public const string TpmKind = "tpm";

    private readonly string _keyName;

    public TpmAttestationProducer(string? keyName = null)
    {
        _keyName = string.IsNullOrWhiteSpace(keyName) ? DefaultKeyName : keyName!;
    }

    /// <inheritdoc />
    public string Kind => TpmKind;

    /// <inheritdoc />
    public bool RequiresServerChallenge => true;

    /// <inheritdoc />
    public ValueTask<WindowsAttestationClaim> ProduceAsync(
        string appId,
        long nowMillis,
        AttestationChallenge? challenge = null,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrEmpty(appId))
        {
            throw new ArgumentException("appId is required to bind the attestation.", nameof(appId));
        }
        cancellationToken.ThrowIfCancellationRequested();

        if (challenge is null || string.IsNullOrWhiteSpace(challenge.ChallengeId) || string.IsNullOrWhiteSpace(challenge.Nonce))
        {
            throw AppCheckMintException.AttestationUnavailable(
                "TPM attestation requires a server-issued one-time challenge.");
        }
        if (challenge.ExpiresAtMs <= nowMillis)
        {
            throw AppCheckMintException.AttestationUnavailable("The App Check attestation challenge expired.");
        }

        if (!OperatingSystem.IsWindows())
        {
            // Fail closed on the wrong platform rather than fabricate a claim.
            throw AppCheckMintException.AttestationUnavailable(
                "TPM attestation requires a Windows host with a Platform Crypto Provider.");
        }

        var nonce = challenge.Nonce;
        var (claimBlob, subjectPublicKey) = CreatePlatformClaim(nonce, cancellationToken);
        var mac = Convert.ToBase64String(claimBlob);

        var claim = new WindowsAttestationClaim
        {
            Kind = TpmKind,
            AppId = appId,
            Nonce = nonce,
            IssuedAtMs = nowMillis,
            Mac = mac, // Base64 raw CNG platform-claim blob; verified only on the Windows service.
            ChallengeId = challenge.ChallengeId,
            SubjectPublicKey = Convert.ToBase64String(subjectPublicKey),
        };
        return new ValueTask<WindowsAttestationClaim>(claim);
    }

    /// <summary>
    /// Create a TPM platform key-attestation claim over <paramref name="nonce"/>.
    /// Every native handle is released in reverse order; any CNG failure fails
    /// closed as <see cref="AppCheckMintFailure.AttestationUnavailable"/>.
    /// </summary>
    private (byte[] ClaimBlob, byte[] SubjectPublicKey) CreatePlatformClaim(
        string nonce,
        CancellationToken cancellationToken)
    {
        var provider = IntPtr.Zero;
        var subjectKey = IntPtr.Zero;
        var nonceBufferPtr = IntPtr.Zero;
        var pcrMaskBufferPtr = IntPtr.Zero;
        var bufferDescPtr = IntPtr.Zero;

        try
        {
            Check(NCryptNative.NCryptOpenStorageProvider(
                out provider, NCryptNative.PlatformCryptoProvider, 0), "NCryptOpenStorageProvider");

            subjectKey = OpenOrCreateAttestationKey(provider);

            // Bind the nonce as the platform-claim nonce so the resulting claim is
            // fresh and single-use (defeats replay of a captured claim).
            var nonceBytes = System.Text.Encoding.UTF8.GetBytes(nonce);
            nonceBufferPtr = Marshal.AllocHGlobal(nonceBytes.Length);
            Marshal.Copy(nonceBytes, 0, nonceBufferPtr, nonceBytes.Length);
            pcrMaskBufferPtr = Marshal.AllocHGlobal(sizeof(int));
            Marshal.WriteInt32(pcrMaskBufferPtr, NCryptNative.TPM_PLATFORM_CLAIM_ALL_PCRS);

            var pcrMaskBuffer = new NCryptNative.NCryptBuffer
            {
                cbBuffer = sizeof(int),
                BufferType = NCryptNative.NCRYPTBUFFER_TPM_PLATFORM_CLAIM_PCR_MASK,
                pvBuffer = pcrMaskBufferPtr,
            };
            var nonceBuffer = new NCryptNative.NCryptBuffer
            {
                cbBuffer = nonceBytes.Length,
                BufferType = NCryptNative.NCRYPTBUFFER_TPM_PLATFORM_CLAIM_NONCE,
                pvBuffer = nonceBufferPtr,
            };
            int nativeBufferSize = Marshal.SizeOf<NCryptNative.NCryptBuffer>();
            bufferDescPtr = Marshal.AllocHGlobal(nativeBufferSize * 2);
            Marshal.StructureToPtr(pcrMaskBuffer, bufferDescPtr, false);
            Marshal.StructureToPtr(nonceBuffer, IntPtr.Add(bufferDescPtr, nativeBufferSize), false);

            var desc = new NCryptNative.NCryptBufferDesc
            {
                ulVersion = NCryptNative.NCRYPTBUFFER_VERSION,
                cBuffers = 2,
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

            Check(NCryptNative.NCryptExportKey(
                subjectKey,
                IntPtr.Zero,
                NCryptNative.BCRYPT_ECCPUBLIC_BLOB,
                IntPtr.Zero,
                null,
                0,
                out var publicKeySize,
                0), "NCryptExportKey(size)");
            if (publicKeySize <= 0)
            {
                throw AppCheckMintException.AttestationUnavailable("TPM returned an empty public key size.");
            }
            var subjectPublicKey = new byte[publicKeySize];
            Check(NCryptNative.NCryptExportKey(
                subjectKey,
                IntPtr.Zero,
                NCryptNative.BCRYPT_ECCPUBLIC_BLOB,
                IntPtr.Zero,
                subjectPublicKey,
                subjectPublicKey.Length,
                out _,
                0), "NCryptExportKey(fill)");

            return (claimBlob, subjectPublicKey);
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
            if (pcrMaskBufferPtr != IntPtr.Zero) Marshal.FreeHGlobal(pcrMaskBufferPtr);
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
        try
        {
            // NCRYPT_CLAIM_PLATFORM is signed by an AIK. A normal TPM signing
            // key is not sufficient and fails with TPM_E_PCP_KEY_NOT_AIK.
            int usagePolicy = NCryptNative.NCRYPT_PCP_IDENTITY_KEY;
            Check(NCryptNative.NCryptSetProperty(
                key,
                NCryptNative.NCRYPT_PCP_KEY_USAGE_POLICY_PROPERTY,
                ref usagePolicy,
                sizeof(int),
                0), "NCryptSetProperty(PCP_KEY_USAGE_POLICY)");
            Check(NCryptNative.NCryptFinalizeKey(key, 0), "NCryptFinalizeKey");
            return key;
        }
        catch
        {
            // DeleteKey frees the handle on success. If deletion itself fails,
            // still release the native handle before propagating the root error.
            if (NCryptNative.NCryptDeleteKey(key, 0) != NCryptNative.ERROR_SUCCESS)
            {
                NCryptNative.NCryptFreeObject(key);
            }
            throw;
        }
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
