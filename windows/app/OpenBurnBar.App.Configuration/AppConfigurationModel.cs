using System.Text.Json.Serialization;

namespace OpenBurnBar.App.Configuration;

/// <summary>Serializable fields persisted to <c>app_config.json</c> (user + onboarding).</summary>
public sealed class AppConfigurationModel
{
    [JsonPropertyName("sqlCipherDbPath")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? SqlCipherDbPath { get; set; }

    /// <summary>Legacy plaintext field. Accepted only for one-shot migration into protected storage.</summary>
    [JsonPropertyName("sqlCipherPassphrase")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? SqlCipherPassphrase { get; set; }

    [JsonPropertyName("sqlCipherPassphraseRef")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? SqlCipherPassphraseRef { get; set; }

    [JsonPropertyName("firebaseProjectId")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? FirebaseProjectId { get; set; }

    [JsonPropertyName("firebaseUid")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? FirebaseUid { get; set; }

    /// <summary>Legacy plaintext field. Accepted only for one-shot migration into protected storage.</summary>
    [JsonPropertyName("firebaseIdToken")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? FirebaseIdToken { get; set; }

    [JsonPropertyName("firebaseIdTokenRef")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? FirebaseIdTokenRef { get; set; }

    /// <summary>Legacy plaintext field. Accepted only for one-shot migration into protected storage.</summary>
    [JsonPropertyName("appCheckToken")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? AppCheckToken { get; set; }

    [JsonPropertyName("appCheckTokenRef")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? AppCheckTokenRef { get; set; }

    /// <summary>Legacy plaintext field. Accepted only for one-shot migration into protected storage.</summary>
    [JsonPropertyName("vaultKeyB64")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? VaultKeyB64 { get; set; }

    [JsonPropertyName("vaultKeyB64Ref")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? VaultKeyB64Ref { get; set; }
}
