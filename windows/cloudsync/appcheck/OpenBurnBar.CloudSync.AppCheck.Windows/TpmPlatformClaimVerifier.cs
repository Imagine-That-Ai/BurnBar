using System;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Text;
using OpenBurnBar.CloudSync.AppCheck.Windows.Interop;

namespace OpenBurnBar.CloudSync.AppCheck.Windows;

/// <summary>Windows-hosted remote verifier for CNG platform attestation claims.</summary>
[SupportedOSPlatform("windows")]
public sealed class TpmPlatformClaimVerifier
{
    public TpmClaimVerificationResult Verify(
        byte[] subjectPublicKey,
        byte[] platformClaim,
        string nonce)
    {
        if (subjectPublicKey is null || subjectPublicKey.Length == 0)
            throw new ArgumentException("A CNG public-key blob is required.", nameof(subjectPublicKey));
        if (platformClaim is null || platformClaim.Length == 0)
            throw new ArgumentException("A platform claim is required.", nameof(platformClaim));
        if (string.IsNullOrWhiteSpace(nonce))
            throw new ArgumentException("A server nonce is required.", nameof(nonce));
        if (!OperatingSystem.IsWindows())
            return new TpmClaimVerificationResult(false, unchecked((int)0x80090029));

        var provider = IntPtr.Zero;
        var subjectKey = IntPtr.Zero;
        var nonceBufferPtr = IntPtr.Zero;
        var bufferDescPtr = IntPtr.Zero;
        try
        {
            var status = NCryptNative.NCryptOpenStorageProvider(
                out provider,
                NCryptNative.SoftwareKeyStorageProvider,
                0);
            if (status != NCryptNative.ERROR_SUCCESS) return new(false, status);

            status = NCryptNative.NCryptImportKey(
                provider,
                IntPtr.Zero,
                NCryptNative.BCRYPT_ECCPUBLIC_BLOB,
                IntPtr.Zero,
                out subjectKey,
                subjectPublicKey,
                subjectPublicKey.Length,
                0);
            if (status != NCryptNative.ERROR_SUCCESS) return new(false, status);

            var nonceBytes = Encoding.UTF8.GetBytes(nonce);
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
            var parameters = new NCryptNative.NCryptBufferDesc
            {
                ulVersion = NCryptNative.NCRYPTBUFFER_VERSION,
                cBuffers = 1,
                pBuffers = bufferDescPtr,
            };

            status = NCryptNative.NCryptVerifyClaim(
                subjectKey,
                IntPtr.Zero,
                NCryptNative.NCRYPT_CLAIM_PLATFORM,
                ref parameters,
                platformClaim,
                platformClaim.Length,
                IntPtr.Zero,
                0);
            return new(status == NCryptNative.ERROR_SUCCESS, status);
        }
        finally
        {
            if (bufferDescPtr != IntPtr.Zero) Marshal.FreeHGlobal(bufferDescPtr);
            if (nonceBufferPtr != IntPtr.Zero) Marshal.FreeHGlobal(nonceBufferPtr);
            if (subjectKey != IntPtr.Zero) NCryptNative.NCryptFreeObject(subjectKey);
            if (provider != IntPtr.Zero) NCryptNative.NCryptFreeObject(provider);
        }
    }
}

public sealed record TpmClaimVerificationResult(bool Valid, int NativeStatus);
