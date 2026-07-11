using System.Text.Json.Serialization;

namespace OpenBurnBar.App.Configuration;

/// <summary>Serializable fields persisted to <c>app_config.json</c> (user + onboarding).</summary>
public sealed class AppConfigurationModel
{
    [JsonPropertyName("sqlCipherDbPath")]
    public string? SqlCipherDbPath { get; set; }

    [JsonIgnore]
    public string? SqlCipherPassphrase { get; set; }

    [JsonPropertyName("sqlCipherPassphraseProtected")]
    public string? SqlCipherPassphraseProtected { get; set; }

    [JsonPropertyName("firebaseProjectId")]
    public string? FirebaseProjectId { get; set; }

    [JsonPropertyName("firebaseUid")]
    public string? FirebaseUid { get; set; }

    [JsonIgnore]
    public string? FirebaseIdToken { get; set; }

    [JsonPropertyName("firebaseIdTokenProtected")]
    public string? FirebaseIdTokenProtected { get; set; }

    [JsonIgnore]
    public string? AppCheckToken { get; set; }

    [JsonPropertyName("appCheckTokenProtected")]
    public string? AppCheckTokenProtected { get; set; }

    [JsonIgnore]
    public string? VaultKeyB64 { get; set; }

    [JsonPropertyName("vaultKeyB64Protected")]
    public string? VaultKeyB64Protected { get; set; }
}
