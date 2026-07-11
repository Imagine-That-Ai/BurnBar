namespace OpenBurnBar.App.Configuration;

/// <summary>Stable app-wide protected-storage account names.</summary>
public static class AppSecretNames
{
    public const string SqlCipherPassphrase = "openburnbar.windows.sqlcipher.passphrase";
    public const string FirebaseIdToken = "openburnbar.windows.firebase.id-token";
    public const string AppCheckToken = "openburnbar.windows.firebase.app-check-token";
    public const string CloudVaultKeyB64 = "openburnbar.windows.cloud-vault.key-b64";
    public const string OAuthRefreshToken = "openburnbar.windows.oauth.refresh-token";
    public const string OAuthSession = "openburnbar.windows.oauth.session";
    public const string ChatApprovedExecutables = "openburnbar.windows.chat.approved-executables.v1";

    public static string ProviderSecret(string providerId, string accountId, string secretKind)
    {
        if (string.IsNullOrWhiteSpace(providerId)) throw new ArgumentException("providerId is required.", nameof(providerId));
        if (string.IsNullOrWhiteSpace(accountId)) throw new ArgumentException("accountId is required.", nameof(accountId));
        if (string.IsNullOrWhiteSpace(secretKind)) throw new ArgumentException("secretKind is required.", nameof(secretKind));

        return "openburnbar.windows.provider."
            + Normalize(providerId) + "."
            + Normalize(accountId) + "."
            + Normalize(secretKind);
    }

    private static string Normalize(string value)
    {
        Span<char> buffer = stackalloc char[value.Length];
        var count = 0;
        foreach (char ch in value.Trim())
        {
            if ((ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9'))
            {
                buffer[count++] = ch;
            }
            else if (ch >= 'A' && ch <= 'Z')
            {
                buffer[count++] = char.ToLowerInvariant(ch);
            }
            else
            {
                buffer[count++] = '-';
            }
        }

        return new string(buffer[..count]).Trim('-');
    }
}
