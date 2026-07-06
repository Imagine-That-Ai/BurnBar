using OpenBurnBar.App.CursorConnector;
using Xunit;

namespace OpenBurnBar.App.CursorConnector.Tests;

/// <summary>Provider metadata + model-support heuristic parity.</summary>
public sealed class ProviderCatalogTests
{
    [Theory]
    [InlineData(ConnectorProvider.Zai, "Z.ai", "https://api.z.ai/api/coding/paas/v4")]
    [InlineData(ConnectorProvider.Minimax, "MiniMax", "https://api.minimax.io/v1")]
    [InlineData(ConnectorProvider.Ollama, "Ollama Cloud", "https://ollama.com/api")]
    public void Metadata_MatchesSwiftFallback(ConnectorProvider provider, string displayName, string baseUrl)
    {
        Assert.Equal(displayName, ConnectorProviderCatalog.DisplayName(provider));
        Assert.Equal(baseUrl, ConnectorProviderCatalog.DefaultBaseURL(provider));
    }

    [Theory]
    [InlineData("glm-5", ConnectorProvider.Zai, true)]
    [InlineData("GLM-4.6", ConnectorProvider.Zai, true)]
    [InlineData("gpt-4", ConnectorProvider.Zai, false)]
    [InlineData("MiniMax-M2.7-highspeed", ConnectorProvider.Minimax, true)]
    [InlineData("glm-5", ConnectorProvider.Minimax, false)]
    [InlineData("gpt-oss:120b", ConnectorProvider.Ollama, true)]
    [InlineData("deepseek-v4-flash", ConnectorProvider.Ollama, true)]
    [InlineData("qwen3-cloud", ConnectorProvider.Ollama, true)]
    [InlineData("mistral", ConnectorProvider.Ollama, false)]
    public void SupportedModel_HeuristicsMatchSwift(string model, ConnectorProvider provider, bool expected)
    {
        Assert.Equal(expected, ConnectorProviderCatalog.SupportedModel(model, provider));
    }

    [Fact]
    public void SupportedModel_AnyProviderAndEmptyGuard()
    {
        Assert.True(ConnectorProviderCatalog.SupportedModel("gpt-oss:20b"));
        Assert.False(ConnectorProviderCatalog.SupportedModel("   "));
        Assert.False(ConnectorProviderCatalog.SupportedModel("totally-unknown"));
    }

    [Theory]
    [InlineData("https://api.z.ai/api/coding/paas/v4", ConnectorProvider.Zai)]
    [InlineData("https://api.minimax.io/v1", ConnectorProvider.Minimax)]
    [InlineData("https://ollama.com/api", ConnectorProvider.Ollama)]
    [InlineData("http://localhost:11434", ConnectorProvider.Ollama)]
    public void ProviderForBaseUrl_MapsKnownHosts(string baseUrl, ConnectorProvider expected)
    {
        Assert.Equal(expected, ConnectorProviderCatalog.ProviderForBaseURL(baseUrl));
    }

    [Fact]
    public void ProviderForBaseUrl_ReturnsNullForUnknown()
    {
        Assert.Null(ConnectorProviderCatalog.ProviderForBaseURL("https://api.openai.com/v1"));
    }
}
