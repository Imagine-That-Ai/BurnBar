// P/Invoke surface for the CNG key-storage + TPM key-attestation APIs
// (ncrypt.dll) used by the REAL Windows App Check attestation producer.
//
// The genuine, hardware-rooted proof that a Windows client is an unmodified app
// is a TPM key-attestation claim: a persisted key created inside the Microsoft
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

    /// <summary>NCryptCreateClaim claim type: platform (TPM) key attestation.</summary>
    internal const int NCRYPT_CLAIM_PLATFORM = 0x00010000;

    /// <summary>NCryptCreatePersistedKey flag: overwrite an existing key with the same name.</summary>
    internal const int NCRYPT_OVERWRITE_KEY_FLAG = 0x00000080;

    /// <summary>NCRYPTBUFFER buffer type: the key-attestation challenge/nonce.</summary>
    internal const int NCRYPTBUFFER_PKCS_ALG_OID = 41; // unused placeholder kept for clarity
    internal const int NCRYPTBUFFER_CLAIM_KEYATTESTATION_NONCE = 91;

    /// <summary>ECDSA P-256 is the attestation subject-key algorithm.</summary>
    internal const string BCRYPT_ECDSA_P256_ALGORITHM = "ECDSA_P256";

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

    [DllImport(Dll, SetLastError = false)]
    internal static extern int NCryptFreeObject(IntPtr hObject);
}
