using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace OpenBurnBar.App.CursorConnector;

// ── Connector models ─────────────────────────────────────────────────────────
//
// Faithful Windows peer of AgentLens/Services/CursorConnector/
// CursorConnectorModels.swift. The Swift types are value types (struct/enum) that
// are Codable/Hashable/Identifiable; mirrored here as mutable `record` classes so
// the session state machine can mutate config in place (Swift `var config`) while
// still getting value equality for round-trip assertions. JSON keys mirror the
// Swift Codable property names verbatim (camelCase) so a persisted config blob has
// the same shape on both platforms; byte-level Swift `Date` encoding parity is out
// of scope (the blob is app-local, never cross-platform shared).

/// <summary>Swift <c>ConnectorProvider</c> — the three routed providers.</summary>
public enum ConnectorProvider
{
    /// <summary>Z.ai.</summary>
    Zai,

    /// <summary>MiniMax.</summary>
    Minimax,

    /// <summary>Ollama Cloud.</summary>
    Ollama,
}

/// <summary>Swift raw-value ↔ enum helpers for <see cref="ConnectorProvider"/>.</summary>
public static class ConnectorProviderRawValue
{
    /// <summary>The Swift <c>rawValue</c> string.</summary>
    public static string Raw(this ConnectorProvider provider) => provider switch
    {
        ConnectorProvider.Zai => "zai",
        ConnectorProvider.Minimax => "minimax",
        ConnectorProvider.Ollama => "ollama",
        _ => throw new ArgumentOutOfRangeException(nameof(provider)),
    };

    /// <summary>Parses a Swift <c>rawValue</c>, or <c>null</c> when unknown.</summary>
    public static ConnectorProvider? FromRaw(string? raw) => raw switch
    {
        "zai" => ConnectorProvider.Zai,
        "minimax" => ConnectorProvider.Minimax,
        "ollama" => ConnectorProvider.Ollama,
        _ => null,
    };

    /// <summary>Swift <c>ConnectorProvider.allCases</c> order.</summary>
    public static readonly IReadOnlyList<ConnectorProvider> AllCases = new[]
    {
        ConnectorProvider.Zai,
        ConnectorProvider.Minimax,
        ConnectorProvider.Ollama,
    };
}

/// <summary>Serializes <see cref="ConnectorProvider"/> as its Swift raw value.</summary>
public sealed class ConnectorProviderJsonConverter : JsonConverter<ConnectorProvider>
{
    /// <inheritdoc />
    public override ConnectorProvider Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        var raw = reader.GetString();
        return ConnectorProviderRawValue.FromRaw(raw)
            ?? throw new JsonException($"Unknown ConnectorProvider raw value '{raw}'.");
    }

    /// <inheritdoc />
    public override void Write(Utf8JsonWriter writer, ConnectorProvider value, JsonSerializerOptions options) =>
        writer.WriteStringValue(value.Raw());

    /// <inheritdoc />
    public override ConnectorProvider ReadAsPropertyName(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        var raw = reader.GetString();
        return ConnectorProviderRawValue.FromRaw(raw)
            ?? throw new JsonException($"Unknown ConnectorProvider raw value '{raw}'.");
    }

    /// <inheritdoc />
    public override void WriteAsPropertyName(Utf8JsonWriter writer, ConnectorProvider value, JsonSerializerOptions options) =>
        writer.WritePropertyName(value.Raw());
}

/// <summary>Swift <c>TunnelMode</c>.</summary>
public enum TunnelMode
{
    /// <summary>Named tunnel.</summary>
    Named,

    /// <summary>Quick (try-cloudflare) tunnel.</summary>
    Quick,
}

/// <summary>Swift raw-value ↔ enum helpers for <see cref="TunnelMode"/>.</summary>
public static class TunnelModeRawValue
{
    /// <summary>The Swift <c>rawValue</c> string.</summary>
    public static string Raw(this TunnelMode mode) => mode switch
    {
        TunnelMode.Named => "named",
        TunnelMode.Quick => "quick",
        _ => throw new ArgumentOutOfRangeException(nameof(mode)),
    };

    /// <summary>Parses a Swift <c>rawValue</c>, or <c>null</c> when unknown.</summary>
    public static TunnelMode? FromRaw(string? raw) => raw switch
    {
        "named" => TunnelMode.Named,
        "quick" => TunnelMode.Quick,
        _ => null,
    };
}

/// <summary>Serializes <see cref="TunnelMode"/> as its Swift raw value.</summary>
public sealed class TunnelModeJsonConverter : JsonConverter<TunnelMode>
{
    /// <inheritdoc />
    public override TunnelMode Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        var raw = reader.GetString();
        return TunnelModeRawValue.FromRaw(raw)
            ?? throw new JsonException($"Unknown TunnelMode raw value '{raw}'.");
    }

    /// <inheritdoc />
    public override void Write(Utf8JsonWriter writer, TunnelMode value, JsonSerializerOptions options) =>
        writer.WriteStringValue(value.Raw());
}

/// <summary>Swift <c>RoutedClientTarget</c>.</summary>
public enum RoutedClientTarget
{
    /// <summary>Factory client.</summary>
    Factory,

    /// <summary>OpenCode client.</summary>
    Opencode,
}

/// <summary>Display + raw-value helpers for <see cref="RoutedClientTarget"/>.</summary>
public static class RoutedClientTargetRawValue
{
    /// <summary>The Swift <c>rawValue</c> string.</summary>
    public static string Raw(this RoutedClientTarget target) => target switch
    {
        RoutedClientTarget.Factory => "factory",
        RoutedClientTarget.Opencode => "opencode",
        _ => throw new ArgumentOutOfRangeException(nameof(target)),
    };

    /// <summary>Swift <c>displayName</c>.</summary>
    public static string DisplayName(this RoutedClientTarget target) => target switch
    {
        RoutedClientTarget.Factory => "Factory",
        RoutedClientTarget.Opencode => "OpenCode",
        _ => throw new ArgumentOutOfRangeException(nameof(target)),
    };
}

/// <summary>Swift <c>ConnectorProviderConfig</c>.</summary>
public sealed record ConnectorProviderConfig
{
    /// <summary>The provider identity.</summary>
    [JsonPropertyName("id")]
    public ConnectorProvider Id { get; set; }

    /// <summary>Whether the provider is routed.</summary>
    [JsonPropertyName("enabled")]
    public bool Enabled { get; set; }

    /// <summary>Upstream base URL.</summary>
    [JsonPropertyName("baseURL")]
    public string BaseURL { get; set; } = string.Empty;

    /// <summary>User-selected catalogue models.</summary>
    [JsonPropertyName("selectedModels")]
    public List<string> SelectedModels { get; set; } = new();

    /// <summary>User-typed custom models.</summary>
    [JsonPropertyName("customModels")]
    public List<string> CustomModels { get; set; } = new();

    /// <summary>Whether the config was imported from Factory settings.</summary>
    [JsonPropertyName("importedFromFactory")]
    public bool ImportedFromFactory { get; set; }

    /// <summary>Parameterless ctor for the serializer.</summary>
    public ConnectorProviderConfig()
    {
    }

    /// <summary>Swift designated init: defaults derive from the provider catalog.</summary>
    public ConnectorProviderConfig(
        ConnectorProvider id,
        bool enabled = false,
        string? baseURL = null,
        IEnumerable<string>? selectedModels = null,
        IEnumerable<string>? customModels = null,
        bool importedFromFactory = false)
    {
        Id = id;
        Enabled = enabled;
        BaseURL = baseURL ?? ConnectorProviderCatalog.DefaultBaseURL(id);
        SelectedModels = (selectedModels ?? ConnectorProviderCatalog.SuggestedModels(id)).ToList();
        CustomModels = (customModels ?? Enumerable.Empty<string>()).ToList();
        ImportedFromFactory = importedFromFactory;
    }

    /// <summary>Swift <c>exposedModels</c> — order-preserving dedup of selected + custom.</summary>
    [JsonIgnore]
    public IReadOnlyList<string> ExposedModels =>
        ConnectorCollections.OrderedDistinct(SelectedModels.Concat(CustomModels));
}

/// <summary>Swift <c>TunnelState</c>.</summary>
public sealed record TunnelState
{
    /// <summary>Tunnel mode.</summary>
    [JsonPropertyName("mode")]
    public TunnelMode Mode { get; set; } = TunnelMode.Quick;

    /// <summary>Public base URL, once the tunnel is live.</summary>
    [JsonPropertyName("publicBaseURL")]
    public string? PublicBaseURL { get; set; }

    /// <summary>Named-tunnel hostname.</summary>
    [JsonPropertyName("hostname")]
    public string Hostname { get; set; } = string.Empty;

    /// <summary>Named-tunnel name.</summary>
    [JsonPropertyName("tunnelName")]
    public string TunnelName { get; set; } = "openburnbar-cursor";

    /// <summary>Human-readable status.</summary>
    [JsonPropertyName("statusMessage")]
    public string StatusMessage { get; set; } = "Not connected";

    /// <summary>Last successful verification instant.</summary>
    [JsonPropertyName("lastVerifiedAt")]
    public DateTimeOffset? LastVerifiedAt { get; set; }

    /// <summary>Rotatable bearer token — regenerated on each connect.</summary>
    [JsonPropertyName("tunnelRotationToken")]
    public string? TunnelRotationToken { get; set; }

    /// <summary>Max requests per client per rate-limit window (Swift default 100).</summary>
    [JsonPropertyName("tunnelRateLimitRequests")]
    public int TunnelRateLimitRequests { get; set; } = 100;

    /// <summary>Rate-limit window in seconds (Swift default 60).</summary>
    [JsonPropertyName("tunnelRateLimitWindow")]
    public int TunnelRateLimitWindow { get; set; } = 60;

    /// <summary>Max failed auth attempts per window (Swift default surfaced as 20 at use).</summary>
    [JsonPropertyName("tunnelAuthFailLimit")]
    public int? TunnelAuthFailLimit { get; set; }
}

/// <summary>Swift <c>CursorSetupSnapshot</c> — the pre-connect Cursor editor state.</summary>
public sealed record CursorSetupSnapshot
{
    /// <summary>Prior <c>useOpenAIKey</c>.</summary>
    [JsonPropertyName("useOpenAIKey")]
    public bool? UseOpenAIKey { get; set; }

    /// <summary>Prior <c>openAIBaseUrl</c>.</summary>
    [JsonPropertyName("openAIBaseUrl")]
    public string? OpenAIBaseUrl { get; set; }

    /// <summary>Prior user-added models.</summary>
    [JsonPropertyName("userAddedModels")]
    public List<string> UserAddedModels { get; set; } = new();

    /// <summary>Prior <c>cursorAuth/openAIKey</c>.</summary>
    [JsonPropertyName("openAIKey")]
    public string? OpenAIKey { get; set; }
}

/// <summary>Swift <c>CursorConnectorConfig</c>.</summary>
public sealed record CursorConnectorConfig
{
    /// <summary>The persisted-config <c>UserDefaults</c> key.</summary>
    public const string DefaultsKey = "cursorConnectorConfig";

    /// <summary>Whether the connector is currently applied.</summary>
    [JsonPropertyName("isEnabled")]
    public bool IsEnabled { get; set; }

    /// <summary>Per-provider config.</summary>
    [JsonPropertyName("providerConfigs")]
    public List<ConnectorProviderConfig> ProviderConfigs { get; set; } = new();

    /// <summary>Tunnel state.</summary>
    [JsonPropertyName("tunnel")]
    public TunnelState Tunnel { get; set; } = new();

    /// <summary>Preferred local proxy port (Swift default 8742).</summary>
    [JsonPropertyName("preferredPort")]
    public int PreferredPort { get; set; } = 8742;

    /// <summary>Human-readable status.</summary>
    [JsonPropertyName("statusMessage")]
    public string StatusMessage { get; set; } = "Ready to connect";

    /// <summary>Last apply instant.</summary>
    [JsonPropertyName("lastAppliedAt")]
    public DateTimeOffset? LastAppliedAt { get; set; }

    /// <summary>Snapshot of Cursor's pre-connect editor settings.</summary>
    [JsonPropertyName("cursorSnapshot")]
    public CursorSetupSnapshot? CursorSnapshot { get; set; }

    /// <summary>Swift default init — a fresh config with all provider slots.</summary>
    public static CursorConnectorConfig CreateDefault()
    {
        return new CursorConnectorConfig
        {
            ProviderConfigs = ConnectorProviderRawValue.AllCases
                .Select(provider => new ConnectorProviderConfig(provider))
                .ToList(),
        };
    }

    /// <summary>Swift <c>enabledProviderConfigs</c>.</summary>
    [JsonIgnore]
    public IReadOnlyList<ConnectorProviderConfig> EnabledProviderConfigs =>
        ProviderConfigs.Where(config => config.Enabled).ToList();

    /// <summary>Swift <c>exposedModels</c> — all models exposed by enabled providers.</summary>
    [JsonIgnore]
    public IReadOnlyList<string> ExposedModels =>
        EnabledProviderConfigs.SelectMany(config => config.ExposedModels).ToList();
}

/// <summary>Swift <c>RoutedUsageEvent</c> — one recent routed request for the UI ticker.</summary>
public sealed record RoutedUsageEvent(
    ConnectorProvider Provider,
    string Model,
    int PromptTokens,
    int CompletionTokens,
    int CacheCreationTokens,
    int CacheReadTokens,
    int TotalTokens,
    double Cost,
    DateTimeOffset Timestamp);

/// <summary>Swift <c>ConnectorHealthSnapshot</c>.</summary>
public sealed record ConnectorHealthSnapshot
{
    /// <summary>Whether the local router is listening.</summary>
    public bool RouterListening { get; set; }

    /// <summary>Whether cloudflared is installed.</summary>
    public bool CloudflaredInstalled { get; set; }

    /// <summary>Whether a package manager (Homebrew on Mac) is present.</summary>
    public bool HomebrewInstalled { get; set; }

    /// <summary>Whether the public tunnel URL is reachable.</summary>
    public bool PublicBaseURLReachable { get; set; }
}

/// <summary>Swift <c>RoutedClientGatewayConfig</c>.</summary>
public sealed record RoutedClientGatewayConfig(string BaseURL, string BearerToken, IReadOnlyList<string> Models)
{
    /// <summary>Swift <c>effectiveAPIKey</c> — falls back to a placeholder when blank.</summary>
    [JsonIgnore]
    public string EffectiveAPIKey
    {
        get
        {
            var trimmed = BearerToken.Trim();
            return trimmed.Length == 0 ? "openburnbar-local" : trimmed;
        }
    }
}

/// <summary>Swift <c>RoutedClientSyncStatus</c>.</summary>
public sealed record RoutedClientSyncStatus(RoutedClientTarget Target, DateTimeOffset AppliedAt, string Summary);

/// <summary>Order-preserving collection helpers shared by the connector models.</summary>
public static class ConnectorCollections
{
    /// <summary>
    /// Swift <c>NSOrderedSet(array:)</c> semantics — keep the first occurrence of
    /// each element (by ordinal equality), preserving input order.
    /// </summary>
    public static IReadOnlyList<string> OrderedDistinct(IEnumerable<string> values)
    {
        if (values is null)
        {
            throw new ArgumentNullException(nameof(values));
        }

        var seen = new HashSet<string>(StringComparer.Ordinal);
        var result = new List<string>();
        foreach (var value in values)
        {
            if (seen.Add(value))
            {
                result.Add(value);
            }
        }

        return result;
    }
}

/// <summary>Canonical <see cref="JsonSerializerOptions"/> for connector-config round-trips.</summary>
public static class ConnectorJson
{
    /// <summary>
    /// Shared options: the Swift converters for the two raw-value enums, indented
    /// output (Swift <c>.prettyPrinted</c>), and null omission so absent optionals
    /// don't materialise as <c>null</c> keys the Swift decoder wouldn't emit.
    /// </summary>
    public static readonly JsonSerializerOptions Options = BuildOptions();

    private static JsonSerializerOptions BuildOptions()
    {
        var options = new JsonSerializerOptions
        {
            WriteIndented = true,
            DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        };
        options.Converters.Add(new ConnectorProviderJsonConverter());
        options.Converters.Add(new TunnelModeJsonConverter());
        return options;
    }

    /// <summary>Serializes a connector config with the canonical options.</summary>
    public static string Encode(CursorConnectorConfig config) =>
        JsonSerializer.Serialize(config, Options);

    /// <summary>Decodes a connector config with the canonical options.</summary>
    public static CursorConnectorConfig? Decode(string json) =>
        JsonSerializer.Deserialize<CursorConnectorConfig>(json, Options);
}
