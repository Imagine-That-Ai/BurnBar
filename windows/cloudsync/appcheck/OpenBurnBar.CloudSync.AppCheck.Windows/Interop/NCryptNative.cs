// P/Invoke surface for the CNG key-storage + TPM key-attestation APIs
// (ncrypt.dll) used by the REAL Windows App Check attestation producer.
//
// The hardware-rooted Windows installation signal is a TPM key-attestation
// claim: a persisted key created inside the Microsoft
// Platform Crypto Provider (the TPM-backed CNG provider) is attested with
// NCryptCreateClaim(NCRYPT_CLAIM_PLATFORM), binding a server-supplied nonce. The
// resulting claim blob is what AC-013's server verifier will validate against the
// TPM's Endorsement/Attestation key chain.
//
// Declarations only — every method is `internal`. The whole assembly's P/Invokes
// are pinned to the OS "safe directories" search path (app dir + System32 +
// AddDllDirectory dirs; excludes the current directory + PATH) to mitigate DLL
// planting / side-loading (R19): ncrypt.dll lives in System32 and is found
// without a plantable search. This assembly targets net8.0-windows and RUNS only
// on a Windows host with a TPM; on the macOS authoring host it Roslyn-compiles
// (EnableWindowsTargeting) but never loads the native DLL.

using System;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;

// The whole assembly is Windows-only (ncrypt.dll + TPM). Marking it here satisfies
// the platform-compatibility analyzer (CA1416) while still compiling on macOS.
[assembly: SupportedOSPlatform("windows")]

// Pin every P/Invoke in this assembly to the OS safe-directories search path (R19).
[assembly: DefaultDllImportSearchPaths(DllImportSearchPath.SafeDirectories)]

namespace OpenBurnBar.CloudSync.AppCheck.Windows.Interop;

/// <summary>CNG NCRYPT_* handles are opaque native pointers.</summary>
internal static class NCryptNative
{
    internal const string Dll = "ncrypt.dll";

    /// <summary>The TPM-backed CNG key-storage provider.</summary>
    internal const string PlatformCryptoProvider = "Microsoft Platform Crypto Provider";
    internal const string SoftwareKeyStorageProvider = "Microsoft Software Key Storage Provider";

    /// <summary>NCryptCreateClaim claim type: platform (TPM) key attestation.</summary>
    internal const int NCRYPT_CLAIM_PLATFORM = 0x00010000;

    /// <summary>
    /// NCRYPTBUFFER types for TPM platform-claim PCR selection and nonce. The
    /// nonce type is distinct
    /// from NCRYPTBUFFER_CLAIM_KEYATTESTATION_NONCE (49), which applies to other
    /// claim types.
    /// </summary>
    // Windows SDK ncrypt.h (Windows 10 RS5+). This value is part of the native ABI.
    internal const int NCRYPTBUFFER_TPM_PLATFORM_CLAIM_PCR_MASK = 80;
    internal const int NCRYPTBUFFER_TPM_PLATFORM_CLAIM_NONCE = 81;
    internal const int TPM_PLATFORM_CLAIM_ALL_PCRS = 0x00FFFFFF;

    /// <summary>Marks a Platform Crypto Provider key as an Attestation Identity Key.</summary>
    internal const string NCRYPT_PCP_KEY_USAGE_POLICY_PROPERTY = "PCP_KEY_USAGE_POLICY";
    internal const int NCRYPT_PCP_IDENTITY_KEY = 0x00000008;

    /// <summary>ECDSA P-256 is the attestation subject-key algorithm.</summary>
    internal const string BCRYPT_ECDSA_P256_ALGORITHM = "ECDSA_P256";
    internal const string BCRYPT_ECCPUBLIC_BLOB = "ECCPUBLICBLOB";

    // NTSTATUS-style HRESULT; 0 == ERROR_SUCCESS.
    internal const int ERROR_SUCCESS = 0;

    [StructLayout(LayoutKind.Sequential)]
    internal struct NCryptBuffer
    {
        public int cbBuffer;
        public int BufferType;
        public IntPtr pvBuffer;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct NCryptBufferDesc
    {
        public int ulVersion;
        public int cBuffers;
        public IntPtr pBuffers;
    }

    internal const int NCRYPTBUFFER_VERSION = 0;

    [DllImport(Dll, CharSet = CharSet.Unicode, SetLastError = false)]
    internal static extern int NCryptOpenStorageProvider(
        out IntPtr phProvider,
        string pszProviderName,
        int dwFlags);

    [DllImport(Dll, CharSet = CharSet.Unicode, SetLastError = false)]
    internal static extern int NCryptCreatePersistedKey(
        IntPtr hProvider,
        out IntPtr phKey,
        string pszAlgId,
        string? pszKeyName,
        int dwLegacyKeySpec,
        int dwFlags);

    [DllImport(Dll, CharSet = CharSet.Unicode, SetLastError = false)]
    internal static extern int NCryptOpenKey(
        IntPtr hProvider,
        out IntPtr phKey,
        string pszKeyName,
        int dwLegacyKeySpec,
        int dwFlags);

    [DllImport(Dll, SetLastError = false)]
    internal static extern int NCryptFinalizeKey(IntPtr hKey, int dwFlags);

    [DllImport(Dll, CharSet = CharSet.Unicode, SetLastError = false)]
    internal static extern int NCryptSetProperty(
        IntPtr hObject,
        string pszProperty,
        ref int pbInput,
        int cbInput,
        int dwFlags);

    [DllImport(Dll, SetLastError = false)]
    internal static extern int NCryptDeleteKey(IntPtr hKey, int dwFlags);

    /// <summary>
    /// Create a key-attestation claim. Called first with pbClaimBlob = null to size
    /// the output, then again with a caller-allocated buffer.
    /// </summary>
    [DllImport(Dll, SetLastError = false)]
    internal static extern int NCryptCreateClaim(
        IntPtr hSubjectKey,
        IntPtr hAuthorityKey,
        int dwClaimType,
        ref NCryptBufferDesc pParameterList,
        byte[]? pbClaimBlob,
        int cbClaimBlob,
        out int pcbResult,
        int dwFlags);

    [DllImport(Dll, CharSet = CharSet.Unicode, SetLastError = false)]
    internal static extern int NCryptExportKey(
        IntPtr hKey,
        IntPtr hExportKey,
        string pszBlobType,
        IntPtr pParameterList,
        byte[]? pbOutput,
        int cbOutput,
        out int pcbResult,
        int dwFlags);

    [DllImport(Dll, CharSet = CharSet.Unicode, SetLastError = false)]
    internal static extern int NCryptImportKey(
        IntPtr hProvider,
        IntPtr hImportKey,
        string pszBlobType,
        IntPtr pParameterList,
        out IntPtr phKey,
        byte[] pbData,
        int cbData,
        int dwFlags);

    [DllImport(Dll, SetLastError = false)]
    internal static extern int NCryptVerifyClaim(
        IntPtr hSubjectKey,
        IntPtr hAuthorityKey,
        int dwClaimType,
        ref NCryptBufferDesc pParameterList,
        byte[] pbClaimBlob,
        int cbClaimBlob,
        ref NCryptBufferDesc pOutput,
        int dwFlags);

    [DllImport(Dll, SetLastError = false)]
    internal static extern int NCryptFreeBuffer(IntPtr pvInput);

    [DllImport(Dll, SetLastError = false)]
    internal static extern int NCryptFreeObject(IntPtr hObject);
}
