using System.Security.Cryptography;
using System.Text;

namespace OpenBurnBar.App.Configuration;

internal static class AppConfigurationSecretProtector
{
    private const string DpapiPrefix = "dpapi-v1:";
    private const string LocalDevPrefix = "local-dev-v1:";
    private static readonly byte[] Entropy = "OpenBurnBar.AppConfiguration.v1"u8.ToArray();

    internal static string? Protect(string? plaintext)
    {
        if (string.IsNullOrEmpty(plaintext))
        {
            return null;
        }

        byte[] bytes = Encoding.UTF8.GetBytes(plaintext);
        if (OperatingSystem.IsWindows())
        {
            byte[] protectedBytes = ProtectedData.Protect(bytes, Entropy, DataProtectionScope.CurrentUser);
            CryptographicOperations.ZeroMemory(bytes);
            return DpapiPrefix + Convert.ToBase64String(protectedBytes);
        }

        // The Windows app uses DPAPI in production. Test and non-Windows developer hosts still avoid
        // plaintext app_config.json values while keeping configuration round-trips deterministic.
        return LocalDevPrefix + Convert.ToBase64String(bytes);
    }

    internal static string? Unprotect(string? protectedValue)
    {
        if (string.IsNullOrWhiteSpace(protectedValue))
        {
            return null;
        }

        if (protectedValue.StartsWith(DpapiPrefix, StringComparison.Ordinal))
        {
            byte[] protectedBytes = Convert.FromBase64String(protectedValue[DpapiPrefix.Length..]);
            byte[] bytes = ProtectedData.Unprotect(protectedBytes, Entropy, DataProtectionScope.CurrentUser);
            try
            {
                return Encoding.UTF8.GetString(bytes);
            }
            finally
            {
                CryptographicOperations.ZeroMemory(bytes);
            }
        }

        if (protectedValue.StartsWith(LocalDevPrefix, StringComparison.Ordinal))
        {
            byte[] bytes = Convert.FromBase64String(protectedValue[LocalDevPrefix.Length..]);
            return Encoding.UTF8.GetString(bytes);
        }

        return null;
    }
}
