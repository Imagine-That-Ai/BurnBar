using System;
using System.Collections.Generic;
using System.Linq;
using OpenBurnBar.App.CursorConnector;
using Xunit;

namespace OpenBurnBar.App.CursorConnector.Tests;

/// <summary>Round-trip + shape parity for the connector models.</summary>
public sealed class ConnectorModelsTests
{
    [Fact]
    public void DefaultConfig_HasAllProviderSlotsInOrder()
    {
        var config = CursorConnectorConfig.CreateDefault();

        Assert.Equal(
            new[] { ConnectorProvider.Zai, ConnectorProvider.Minimax, ConnectorProvider.Ollama },
            config.ProviderConfigs.Select(providerConfig => providerConfig.Id).ToArray());
        Assert.Equal(8742, config.PreferredPort);
        Assert.Equal("Ready to connect", config.StatusMessage);
        Assert.All(config.ProviderConfigs, providerConfig => Assert.False(providerConfig.Enabled));
    }

    [Fact]
    public void ProviderConfig_DefaultsDeriveFromCatalog()
    {
        var config = new ConnectorProviderConfig(ConnectorProvider.Zai);

        Assert.Equal("https://api.z.ai/api/coding/paas/v4", config.BaseURL);
        Assert.Equal(new[] { "glm-5", "glm-5-turbo" }, config.SelectedModels);
    }

    [Fact]
    public void ExposedModels_DedupesPreservingOrder()
    {
        var config = new ConnectorProviderConfig(ConnectorProvider.Zai, baseURL: "https://x")
        {
            SelectedModels = new List<string> { "a", "b" },
            CustomModels = new List<string> { "b", "c", "a" },
        };

        Assert.Equal(new[] { "a", "b", "c" }, config.ExposedModels.ToArray());
    }

    [Fact]
    public void EnabledExposedModels_FlattenEnabledProvidersOnly()
    {
        var config = CursorConnectorConfig.CreateDefault();
        config.ProviderConfigs[0].Enabled = true;
        config.ProviderConfigs[0].SelectedModels = new List<string> { "glm-5" };
        config.ProviderConfigs[0].CustomModels = new List<string>();
        config.ProviderConfigs[1].Enabled = false;

        Assert.Equal(new[] { "glm-5" }, config.ExposedModels.ToArray());
        Assert.Single(config.EnabledProviderConfigs);
    }

    [Fact]
    public void ProviderRawValues_MatchSwift()
    {
        Assert.Equal("zai", ConnectorProvider.Zai.Raw());
        Assert.Equal("minimax", ConnectorProvider.Minimax.Raw());
        Assert.Equal("ollama", ConnectorProvider.Ollama.Raw());
        Assert.Equal(ConnectorProvider.Ollama, ConnectorProviderRawValue.FromRaw("ollama"));
        Assert.Null(ConnectorProviderRawValue.FromRaw("openai"));
    }

    [Fact]
    public void Config_RoundTripsStablyThroughJson()
    {
        var original = CursorConnectorConfig.CreateDefault();
        original.IsEnabled = true;
        original.ProviderConfigs[2].Enabled = true;
        original.ProviderConfigs[2].CustomModels = new List<string> { "qwen3-cloud" };
        original.Tunnel.Mode = TunnelMode.Quick;
        original.Tunnel.PublicBaseURL = "https://calm-otter.trycloudflare.com/v1";
        original.Tunnel.TunnelRotationToken = "abc123";
        original.LastAppliedAt = new DateTimeOffset(2026, 7, 6, 12, 0, 0, TimeSpan.Zero);
        original.CursorSnapshot = new CursorSetupSnapshot
        {
            UseOpenAIKey = false,
            OpenAIBaseUrl = "https://old",
            UserAddedModels = new List<string> { "m1" },
            OpenAIKey = "old-key",
        };

        var json = ConnectorJson.Encode(original);
        var decoded = ConnectorJson.Decode(json);
        Assert.NotNull(decoded);

        // Stable re-encode is the round-trip contract (avoids List reference-equality).
        Assert.Equal(json, ConnectorJson.Encode(decoded!));
        Assert.True(decoded!.IsEnabled);
        Assert.Equal(ConnectorProvider.Ollama, decoded.ProviderConfigs[2].Id);
        Assert.True(decoded.ProviderConfigs[2].Enabled);
        Assert.Equal(new[] { "qwen3-cloud" }, decoded.ProviderConfigs[2].CustomModels);
        Assert.Equal("https://calm-otter.trycloudflare.com/v1", decoded.Tunnel.PublicBaseURL);
        Assert.Equal(original.LastAppliedAt, decoded.LastAppliedAt);
        Assert.Equal("old-key", decoded.CursorSnapshot!.OpenAIKey);
    }

    [Fact]
    public void Config_SerializesEnumRawValuesAndOmitsNulls()
    {
        var config = CursorConnectorConfig.CreateDefault();
        var json = ConnectorJson.Encode(config);

        Assert.Contains("\"id\": \"zai\"", json);
        Assert.Contains("\"mode\": \"quick\"", json);
        // publicBaseURL is null on a fresh config and must be omitted.
        Assert.DoesNotContain("publicBaseURL", json);
    }

    [Fact]
    public void RoutedClientGatewayConfig_EffectiveApiKeyFallsBack()
    {
        Assert.Equal(
            "openburnbar-local",
            new RoutedClientGatewayConfig("http://x", "   ", new List<string>()).EffectiveAPIKey);
        Assert.Equal(
            "tok",
            new RoutedClientGatewayConfig("http://x", " tok ", new List<string>()).EffectiveAPIKey);
    }

    [Fact]
    public void RoutedClientTarget_DisplayNamesMatchSwift()
    {
        Assert.Equal("Factory", RoutedClientTarget.Factory.DisplayName());
        Assert.Equal("OpenCode", RoutedClientTarget.Opencode.DisplayName());
    }
}
