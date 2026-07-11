using System;
using System.Globalization;
using System.Text.Json.Serialization;

namespace OpenBurnBar.Integrations.HomeAssistant;

// Non-secret recovery config for the OpenBurnBar Smart Display flow.
//
// Parity: AgentLens/Services/HomeAssistant/HomeAssistantConfig.swift
//   struct HomeAssistantConfig + enum SetupMode + webhookURL.
//
// The access token never lives here (it sits in the token store); this is the
// JSON-serializable metadata the config store persists.

public enum HomeAssistantSetupMode
{
    /// Phase A — REST automation provisioning.
    Rest,

    /// Blueprint fallback path.
    Blueprint,

    /// User pasted a webhook URL by hand.
    ManualWebhook,
}

public sealed class HomeAssistantConfig : IEquatable<HomeAssistantConfig>
{
    /// Normalized HA base URL (no trailing slash).
    public string BaseUrl { get; set; }

    public string MediaPlayerEntityId { get; set; }

    public string MediaPlayerFriendlyName { get; set; }

    /// Random URL-safe webhook trigger id (prefixed openburnbar_cast_recover_).
    public string WebhookId { get; set; }

    public string AutomationEntityId { get; set; }

    public bool AutomationInstalled { get; set; }

    public bool LastTestPassed { get; set; }

    /// ISO8601 timestamp of last successful verification, or null.
    public DateTimeOffset? LastVerifiedAt { get; set; }

    public HomeAssistantSetupMode SetupMode { get; set; }

    public HomeAssistantConfig(
        string baseUrl,
        string mediaPlayerEntityId = "",
        string mediaPlayerFriendlyName = "",
        string webhookId = "",
        string automationEntityId = "",
        bool automationInstalled = false,
        bool lastTestPassed = false,
        DateTimeOffset? lastVerifiedAt = null,
        HomeAssistantSetupMode setupMode = HomeAssistantSetupMode.Rest)
    {
        BaseUrl = baseUrl;
        MediaPlayerEntityId = mediaPlayerEntityId;
        MediaPlayerFriendlyName = mediaPlayerFriendlyName;
        WebhookId = webhookId;
        AutomationEntityId = automationEntityId;
        AutomationInstalled = automationInstalled;
        LastTestPassed = lastTestPassed;
        LastVerifiedAt = lastVerifiedAt;
        SetupMode = setupMode;
    }

    /// Webhook URL on the configured HA instance: `<baseURL>/api/webhook/<id>`.
    /// Parity: Swift `webhookURL` (nil when no id).
    [JsonIgnore]
    public string? WebhookUrl
    {
        get
        {
            if (string.IsNullOrEmpty(WebhookId))
            {
                return null;
            }
            var trimmed = BaseUrl.EndsWith("/", StringComparison.Ordinal)
                ? BaseUrl.Substring(0, BaseUrl.Length - 1)
                : BaseUrl;
            return $"{trimmed}/api/webhook/{WebhookId}";
        }
    }

    public bool Equals(HomeAssistantConfig? other) =>
        other is not null &&
        BaseUrl == other.BaseUrl &&
        MediaPlayerEntityId == other.MediaPlayerEntityId &&
        MediaPlayerFriendlyName == other.MediaPlayerFriendlyName &&
        WebhookId == other.WebhookId &&
        AutomationEntityId == other.AutomationEntityId &&
        AutomationInstalled == other.AutomationInstalled &&
        LastTestPassed == other.LastTestPassed &&
        Nullable.Equals(LastVerifiedAt, other.LastVerifiedAt) &&
        SetupMode == other.SetupMode;

    public override bool Equals(object? obj) => Equals(obj as HomeAssistantConfig);

    public override int GetHashCode()
    {
        var hash = new HashCode();
        hash.Add(BaseUrl);
        hash.Add(MediaPlayerEntityId);
        hash.Add(MediaPlayerFriendlyName);
        hash.Add(WebhookId);
        hash.Add(AutomationEntityId);
        hash.Add(AutomationInstalled);
        hash.Add(LastTestPassed);
        hash.Add(LastVerifiedAt);
        hash.Add(SetupMode);
        return hash.ToHashCode();
    }
}

/// Raw-value mapping for HomeAssistantSetupMode matching the Swift enum's
/// string raw values ("rest" / "blueprint" / "manualWebhook").
public static class HomeAssistantSetupModeExtensions
{
    public static string RawValue(this HomeAssistantSetupMode mode) => mode switch
    {
        HomeAssistantSetupMode.Rest => "rest",
        HomeAssistantSetupMode.Blueprint => "blueprint",
        HomeAssistantSetupMode.ManualWebhook => "manualWebhook",
        _ => "rest",
    };

    public static HomeAssistantSetupMode ParseSetupMode(string? rawValue) => rawValue switch
    {
        "blueprint" => HomeAssistantSetupMode.Blueprint,
        "manualWebhook" => HomeAssistantSetupMode.ManualWebhook,
        _ => HomeAssistantSetupMode.Rest,
    };
}
