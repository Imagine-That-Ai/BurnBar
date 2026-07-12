using System.Runtime.InteropServices;

namespace OpenBurnBar.App.Configuration;

internal sealed class WindowsDpapiSecretProtector : ISecretProtector
{
    public static readonly WindowsDpapiSecretProtector Instance = new();

    private const int CryptProtectUiForbidden = 0x1;

    public string BackendName => "windows-dpapi-current-user";

    public byte[] Protect(byte[] plaintext, byte[] entropy)
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new SecretStoreException(
                SecretStoreFailureKind.ProtectedStorageUnavailable,
                "DPAPI is only available on Windows.");
        }

        return Crypt(plaintext, entropy, protect: true);
    }

    public byte[] Unprotect(byte[] protectedBytes, byte[] entropy)
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new SecretStoreException(
                SecretStoreFailureKind.ProtectedStorageUnavailable,
                "DPAPI is only available on Windows.");
        }

        return Crypt(protectedBytes, entropy, protect: false);
    }

    private static byte[] Crypt(byte[] input, byte[] entropy, bool protect)
    {
        var inputBlob = default(DATA_BLOB);
        var entropyBlob = default(DATA_BLOB);
        var outputBlob = default(DATA_BLOB);
        try
        {
            inputBlob = BlobFrom(input);
            entropyBlob = BlobFrom(entropy);

            bool ok = protect
                ? CryptProtectData(ref inputBlob, "OpenBurnBar", ref entropyBlob, IntPtr.Zero, IntPtr.Zero, CryptProtectUiForbidden, out outputBlob)
                : CryptUnprotectData(ref inputBlob, IntPtr.Zero, ref entropyBlob, IntPtr.Zero, IntPtr.Zero, CryptProtectUiForbidden, out outputBlob);

            if (!ok)
            {
                int error = Marshal.GetLastWin32Error();
                throw new SecretStoreException(
                    protect ? SecretStoreFailureKind.WriteDenied : SecretStoreFailureKind.ReadDenied,
                    $"DPAPI {(protect ? "protect" : "unprotect")} failed with Win32={error}.");
            }

            var output = new byte[outputBlob.cbData];
            Marshal.Copy(outputBlob.pbData, output, 0, output.Length);
            return output;
        }
        finally
        {
            FreeBlob(inputBlob);
            FreeBlob(entropyBlob);
            if (outputBlob.pbData != IntPtr.Zero)
            {
                LocalFree(outputBlob.pbData);
            }
        }
    }

    private static DATA_BLOB BlobFrom(byte[] data)
    {
        var blob = new DATA_BLOB { cbData = data.Length };
        if (data.Length > 0)
        {
            blob.pbData = Marshal.AllocHGlobal(data.Length);
            Marshal.Copy(data, 0, blob.pbData, data.Length);
        }

        return blob;
    }

    private static void FreeBlob(DATA_BLOB blob)
    {
        if (blob.pbData != IntPtr.Zero)
        {
            Marshal.FreeHGlobal(blob.pbData);
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DATA_BLOB
    {
        public int cbData;
        public IntPtr pbData;
    }

    [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CryptProtectData(
        ref DATA_BLOB pDataIn,
        string? szDataDescr,
        ref DATA_BLOB pOptionalEntropy,
        IntPtr pvReserved,
        IntPtr pPromptStruct,
        int dwFlags,
        out DATA_BLOB pDataOut);

    [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CryptUnprotectData(
        ref DATA_BLOB pDataIn,
        IntPtr ppszDataDescr,
        ref DATA_BLOB pOptionalEntropy,
        IntPtr pvReserved,
        IntPtr pPromptStruct,
        int dwFlags,
        out DATA_BLOB pDataOut);

    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr hMem);
}
