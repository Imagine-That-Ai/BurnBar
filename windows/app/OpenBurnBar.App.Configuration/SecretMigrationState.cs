using System.Text.Json.Serialization;

namespace OpenBurnBar.App.Configuration;

public enum AppConfigurationSecurityStatus
{
    Clean,
    MigratedLegacySecrets,
    MigrationFailed,
}

public sealed record AppConfigurationSecurityState(
    AppConfigurationSecurityStatus Status,
    string? Detail = null);

public enum SecretMigrationBoundary
{
    AfterJournalWritten,
    AfterSecretWritten,
    AfterSecretVerified,
    AfterConfigReplaced,
}

internal sealed class SecretMigrationFaults
{
    public SecretMigrationBoundary? Boundary { get; init; }
    public string? SecretName { get; init; }

    public void ThrowIf(SecretMigrationBoundary boundary, string? secretName = null)
    {
        if (Boundary == boundary
            && (SecretName is null || string.Equals(SecretName, secretName, StringComparison.Ordinal)))
        {
            throw new SecretStoreException(
                SecretStoreFailureKind.MigrationFailed,
                $"Injected migration crash at {boundary}.",
                secretName);
        }
    }
}

internal sealed record SecretMigrationJournal
{
    [JsonPropertyName("version")]
    public int Version { get; init; } = 1;

    [JsonPropertyName("state")]
    public string State { get; init; } = "prepared";

    [JsonPropertyName("configPath")]
    public string ConfigPath { get; init; } = string.Empty;

    [JsonPropertyName("secretRefs")]
    public IReadOnlyList<string> SecretRefs { get; init; } = Array.Empty<string>();

    [JsonPropertyName("createdAt")]
    public DateTimeOffset CreatedAt { get; init; } = DateTimeOffset.UtcNow;
}
