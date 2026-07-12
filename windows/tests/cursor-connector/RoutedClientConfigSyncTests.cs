using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json.Nodes;
using OpenBurnBar.App.CursorConnector;
using Xunit;

namespace OpenBurnBar.App.CursorConnector.Tests;

/// <summary>Factory/OpenCode gateway-config sync parity.</summary>
public sealed class RoutedClientConfigSyncTests
{
    private const string Home = "/home/alberto";
    private static readonly DateTimeOffset Stamp = new(2026, 7, 6, 12, 0, 0, TimeSpan.Zero);

    private static (RoutedClientConfigSyncService Service, InMemoryFileSystem Fs) NewService()
    {
        var fs = new InMemoryFileSystem();
        var service = new RoutedClientConfigSyncService(fs, Home, new FixedClock(Stamp));
        return (service, fs);
    }

    private static RoutedClientGatewayConfig GatewayConfig() => new(
        "http://127.0.0.1:8317/v1",
        string.Empty,
        new List<string> { "glm-5", " glm-5 ", "GLM-5", "MiniMax-M2.7" });

    [Fact]
    public void ApplyFactory_WritesNormalizedCustomModels()
    {
        var (service, fs) = NewService();

        var paths = service.ApplyFactoryGatewayConfig(GatewayConfig());

        var settingsPath = paths[0];
        Assert.EndsWith(".factory/settings.json", settingsPath);
        var models = JsonNode.Parse(fs.Peek(settingsPath))!["customModels"]!.AsArray();
        Assert.Equal(2, models.Count);

        var first = models[0]!.AsObject();
        Assert.Equal("glm-5", (string)first["model"]!);
        Assert.Equal("custom:OpenBurnBar-glm-5-0", (string)first["id"]!);
        Assert.Equal("OpenBurnBar glm-5", (string)first["displayName"]!);
        Assert.Equal("generic-chat-completion-api", (string)first["provider"]!);
        Assert.Equal("http://127.0.0.1:8317/v1", (string)first["baseUrl"]!);
        Assert.Equal("openburnbar-local", (string)first["apiKey"]!);
    }

    [Fact]
    public void ApplyFactory_IsIdempotent()
    {
        var (service, fs) = NewService();

        service.ApplyFactoryGatewayConfig(GatewayConfig());
        service.ApplyFactoryGatewayConfig(GatewayConfig());

        var (settingsPath, _) = service.FactoryGatewayConfigPaths();
        var models = JsonNode.Parse(fs.Peek(settingsPath))!["customModels"]!.AsArray();
        Assert.Equal(2, models.Count);
    }

    [Fact]
    public void ApplyFactory_PreservesForeignEntries()
    {
        var (service, fs) = NewService();
        var (settingsPath, _) = service.FactoryGatewayConfigPaths();
        fs.Seed(settingsPath, "{\"customModels\":[{\"provider\":\"anthropic\",\"model\":\"claude\",\"baseUrl\":\"https://api.anthropic.com\"}]}");

        service.ApplyFactoryGatewayConfig(GatewayConfig());

        var models = JsonNode.Parse(fs.Peek(settingsPath))!["customModels"]!.AsArray();
        Assert.Equal(3, models.Count);
        Assert.True(service.IsFactoryGatewayConfigPresent());
    }

    [Fact]
    public void ApplyFactory_BacksUpExistingFile()
    {
        var (service, fs) = NewService();
        var (settingsPath, _) = service.FactoryGatewayConfigPaths();
        fs.Seed(settingsPath, "{\"customModels\":[]}");

        service.ApplyFactoryGatewayConfig(GatewayConfig());

        Assert.True(fs.Has(settingsPath + ".openburnbar-backup-20260706120000"));
    }

    [Fact]
    public void IsFactoryGatewayConfigPresent_FalseBeforeApply()
    {
        var (service, _) = NewService();
        Assert.False(service.IsFactoryGatewayConfigPresent());
    }

    [Fact]
    public void ApplyOpenCode_WritesProviderBlock()
    {
        var (service, fs) = NewService();

        var path = service.ApplyOpenCodeGatewayConfig(GatewayConfig());

        Assert.EndsWith(".config/opencode/opencode.json", path);
        var root = JsonNode.Parse(fs.Peek(path))!.AsObject();
        var provider = root["provider"]!["openburnbar"]!.AsObject();
        Assert.Equal("@ai-sdk/openai-compatible", (string)provider["npm"]!);
        Assert.Equal("openburnbar/glm-5", (string)root["model"]!);
        Assert.Equal("http://127.0.0.1:8317/v1", (string)provider["options"]!["baseURL"]!);
    }

    [Fact]
    public void ApplyFactory_EmptyModels_Throws()
    {
        var (service, _) = NewService();
        var config = new RoutedClientGatewayConfig("http://x", "k", new List<string> { "   " });
        Assert.Throws<ConnectorConfigException>(() => service.ApplyFactoryGatewayConfig(config));
    }

    [Theory]
    [InlineData("http://127.0.0.1:8317/v1", true)]
    [InlineData("http://localhost:8317", true)]
    [InlineData("http://127.0.0.1:9999", false)]
    [InlineData("https://api.z.ai/v1", false)]
    public void IsLocalGatewayUrl_MatchesLoopbackOn8317(string url, bool expected)
    {
        Assert.Equal(expected, RoutedClientConfigSyncService.IsLocalGatewayUrl(url));
    }

    [Fact]
    public void FactoryCustomModelId_SanitizesSlug()
    {
        Assert.Equal(
            "custom:OpenBurnBar-gpt-oss-120b-2",
            RoutedClientConfigSyncService.FactoryCustomModelId("gpt-oss:120b", 2));
    }

    [Fact]
    public void StripJsonComments_RemovesCommentsButKeepsStringSlashes()
    {
        const string source = "{\n  \"a\": 1, // trailing\n  /* block */ \"b\": \"http://x//y\"\n}";
        var stripped = RoutedClientConfigSyncService.StripJsonComments(source);
        var parsed = JsonNode.Parse(stripped)!.AsObject();

        Assert.Equal(1, (int)parsed["a"]!);
        Assert.Equal("http://x//y", (string)parsed["b"]!);
    }

    [Fact]
    public void NormalizedModels_TrimsAndDedupes()
    {
        var models = RoutedClientConfigSyncService.NormalizedModels(new[] { " a ", "A", "b", "", "b" });
        Assert.Equal(new[] { "a", "b" }, models.ToArray());
    }
}
