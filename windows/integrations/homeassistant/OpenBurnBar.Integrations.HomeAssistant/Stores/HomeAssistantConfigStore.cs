using System;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace OpenBurnBar.Integrations.HomeAssistant.Stores;

// Non-secret HA config persistence.
//
// Parity: AgentLens/Services/HomeAssistant/HomeAssistantConfigStore.swift
//   protocol HomeAssistantConfigStoring + final class HomeAssistantConfigStore.
//
// Persists the JSON-encoded HomeAssistantConfig under a settings key, mirrors
// the derived webhook URL to a legacy raw-URL key so existing call sites keep
// working, and exposes the legacy manual-webhook path. The token/webhook secret
// live in the token store, never here.

/// String key/value settings backing (the app settings store on Windows).
public interface IHomeAssistantKeyValueStore
{
    string GetString(string key, string defaultValue);
    void SetString(string key, string value);
    void Flush();
}

/// Injectable encoder seam so tests can drive the encode-failure path
/// deterministically (parity with the Swift HomeAssistantConfigEncoding).
public interface IHomeAssistantConfigEncoder
{
    /// Returns the JSON string, or null when encoding failed (the store then
    /// skips the write rather than persisting a corrupt/empty config).
    string? Encode(HomeAssistantConfig config);
}

public interface IHomeAssistantConfigStore
{
    HomeAssistantConfig? LoadConfig();
    void SaveConfig(HomeAssistantConfig config);
    void Clear();
    string LegacyWebhookUrlString { get; }
    void ClearLegacyWebhookUrl();
}

public sealed class HomeAssistantConfigStore : IHomeAssistantConfigStore
{
    public const string ConfigKey = "smartHubHomeAssistantConfigJSON";
    public const string LegacyWebhookUrlKey = "smartHubHomeAssistantRecoveryWebhookURL";

    private readonly IHomeAssistantKeyValueStore _settings;
    private readonly IHomeAssistantConfigEncoder _encoder;

    public HomeAssistantConfigStore(
        IHomeAssistantKeyValueStore settings,
        IHomeAssistantConfigEncoder? encoder = null)
    {
        _settings = settings ?? throw new ArgumentNullException(nameof(settings));
        _encoder = encoder ?? new JsonConfigEncoder();
    }

    public HomeAssistantConfig? LoadConfig()
    {
        var raw = _settings.GetString(ConfigKey, string.Empty);
        if (string.IsNullOrEmpty(raw))
        {
            return null;
        }
        try
        {
            var dto = JsonSerializer.Deserialize<ConfigDto>(raw);
            return dto?.ToConfig();
        }
        catch (JsonException)
        {
            // Parity: Swift `try?` — a corrupt persisted blob decodes to nil.
            return null;
        }
    }

    public void SaveConfig(HomeAssistantConfig config)
    {
        var json = _encoder.Encode(config);
        if (json is null)
        {
            // Parity: a failed encode is a skipped write (the Swift path logs and
            // returns without persisting). We do not clobber the prior config.
            return;
        }
        _settings.SetString(ConfigKey, json);

        // Mirror the webhook URL to the legacy raw-URL field so existing call
        // sites keep working without lookups.
        var webhookUrl = config.WebhookUrl;
        if (webhookUrl is not null)
        {
            _settings.SetString(LegacyWebhookUrlKey, webhookUrl);
        }
        _settings.Flush();
    }

    public void Clear()
    {
        _settings.SetString(ConfigKey, string.Empty);
        _settings.SetString(LegacyWebhookUrlKey, string.Empty);
        _settings.Flush();
    }

    public string LegacyWebhookUrlString => _settings.GetString(LegacyWebhookUrlKey, string.Empty);

    public void ClearLegacyWebhookUrl() => _settings.SetString(LegacyWebhookUrlKey, string.Empty);

    /// Production JSON encoder mirroring the Swift ISO8601 encoder.
    private sealed class JsonConfigEncoder : IHomeAssistantConfigEncoder
    {
        public string? Encode(HomeAssistantConfig config) =>
            JsonSerializer.Serialize(ConfigDto.FromConfig(config));
    }

    /// Serialization DTO whose JSON keys match the Swift Codable field names, so
    /// the persisted schema is stable and self-describing.
    private sealed record ConfigDto
    {
        [JsonPropertyName("baseURL")] public string BaseUrl { get; init; } = "";
        [JsonPropertyName("mediaPlayerEntityID")] public string MediaPlayerEntityId { get; init; } = "";
        [JsonPropertyName("mediaPlayerFriendlyName")] public string MediaPlayerFriendlyName { get; init; } = "";
        [JsonPropertyName("webhookID")] public string WebhookId { get; init; } = "";
        [JsonPropertyName("automationEntityID")] public string AutomationEntityId { get; init; } = "";
        [JsonPropertyName("automationInstalled")] public bool AutomationInstalled { get; init; }
        [JsonPropertyName("lastTestPassed")] public bool LastTestPassed { get; init; }
        [JsonPropertyName("lastVerifiedAt")] public DateTimeOffset? LastVerifiedAt { get; init; }
        [JsonPropertyName("setupMode")] public string SetupMode { get; init; } = "rest";

        public static ConfigDto FromConfig(HomeAssistantConfig config) => new()
        {
            BaseUrl = config.BaseUrl,
            MediaPlayerEntityId = config.MediaPlayerEntityId,
            MediaPlayerFriendlyName = config.MediaPlayerFriendlyName,
            WebhookId = config.WebhookId,
            AutomationEntityId = config.AutomationEntityId,
            AutomationInstalled = config.AutomationInstalled,
            LastTestPassed = config.LastTestPassed,
            LastVerifiedAt = config.LastVerifiedAt,
            SetupMode = config.SetupMode.RawValue(),
        };

        public HomeAssistantConfig ToConfig() => new(
            baseUrl: BaseUrl,
            mediaPlayerEntityId: MediaPlayerEntityId,
            mediaPlayerFriendlyName: MediaPlayerFriendlyName,
            webhookId: WebhookId,
            automationEntityId: AutomationEntityId,
            automationInstalled: AutomationInstalled,
            lastTestPassed: LastTestPassed,
            lastVerifiedAt: LastVerifiedAt,
            setupMode: HomeAssistantSetupModeExtensions.ParseSetupMode(SetupMode));
    }
}
