using System.Collections;

namespace OpenBurnBar.App.Configuration;

/// <summary>
/// Fails release composition before product storage or process launch can consume
/// plaintext credential overrides from the ambient host environment.
/// </summary>
public static class ReleaseConfigurationGuard
{
    public static IReadOnlyList<string> ForbiddenPlaintextCredentialVariables { get; } =
        new[]
        {
            "OPENBURNBAR_SQLCIPHER_PATH",
            "OPENBURNBAR_SQLCIPHER_PASSPHRASE",
            "OPENBURNBAR_FIREBASE_ID_TOKEN",
            "OPENBURNBAR_APP_CHECK_TOKEN",
            "OPENBURNBAR_VAULT_KEY_B64",
        };

    public static void ThrowIfPlaintextCredentialEnvironmentPresent(
        IEnumerable<KeyValuePair<string, string?>>? source = null)
    {
        source ??= Environment.GetEnvironmentVariables()
            .Cast<DictionaryEntry>()
            .Select(entry => new KeyValuePair<string, string?>((string)entry.Key, entry.Value?.ToString()));

        var forbidden = new HashSet<string>(ForbiddenPlaintextCredentialVariables, StringComparer.OrdinalIgnoreCase);
        string[] present = source
            .Where(pair => !string.IsNullOrWhiteSpace(pair.Key)
                && !string.IsNullOrWhiteSpace(pair.Value)
                && forbidden.Contains(pair.Key))
            .Select(pair => pair.Key)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .OrderBy(name => name, StringComparer.OrdinalIgnoreCase)
            .ToArray();

        if (present.Length == 0)
        {
            return;
        }

        throw new SecretStoreException(
            SecretStoreFailureKind.WriteDenied,
            "Release composition refuses plaintext credential environment variables: "
                + string.Join(", ", present)
                + ". Use the protected OpenBurnBar secret store instead.",
            present[0]);
    }
}
