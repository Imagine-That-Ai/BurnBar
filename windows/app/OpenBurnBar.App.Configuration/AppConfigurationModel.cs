using System.Text.Json.Serialization;

namespace OpenBurnBar.App.Configuration;

/// <summary>Serializable fields persisted to <c>app_config.json</c> (user + onboarding).</summary>
public sealed class AppConfigurationModel
{
    [JsonPropertyName("sqlCipherDbPath")]
    public string? SqlCipherDbPath { get; set; }

    [JsonPropertyName("sqlCipherPassphrase")]
    public string? SqlCipherPassphrase { get; set; }

    [JsonPropertyName("firebaseProjectId")]
    public string? FirebaseProjectId { get; set; }

    [JsonPropertyName("firebaseUid")]
    public string? FirebaseUid { get; set; }

    [JsonPropertyName("firebaseIdToken")]
    public string? FirebaseIdToken { get; set; }

    [JsonPropertyName("appCheckToken")]
    public string? AppCheckToken { get; set; }

    [JsonPropertyName("vaultKeyB64")]
    public string? VaultKeyB64 { get; set; }
}