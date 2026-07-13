using OpenBurnBar.App.ManagedAgentRuntime.Gateway;
using Xunit;

namespace OpenBurnBar.App.ManagedAgentRuntime.Tests;

public sealed class GatewayCompositionFactoryTests
{
    [Fact]
    public void ParseRoutes_UsesNonSecretMetadataAndTokenEnvironmentReference()
    {
        const string json = "[{\"id\":\"claude\",\"vendor\":\"anthropic\",\"model\":\"claude-3\",\"endpoint\":\"https://provider.example/v1/chat/completions\",\"bearerTokenEnvironmentVariable\":\"OBB_TEST_TOKEN\"}]";
        var routes = GatewayCompositionFactory.ParseRoutes(json);
        Assert.Single(routes);
        Assert.Equal("claude", routes[0].Id);
        Assert.Equal("claude-3", routes[0].Model);
        Assert.Equal("https", routes[0].Endpoint?.Scheme);
        Assert.Null(routes[0].BearerToken);
    }

    [Fact]
    public void ParseRoutes_FallsBackToHonestUnconfiguredRoute()
    {
        var routes = GatewayCompositionFactory.ParseRoutes("not-json");
        Assert.Single(routes);
        Assert.Equal("openburnbar-local", routes[0].Id);
        Assert.Null(routes[0].Endpoint);
    }
}
