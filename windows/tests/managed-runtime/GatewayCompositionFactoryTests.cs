using System;
using System.Collections.Generic;
using System.Linq;
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

        IReadOnlyList<ModelRoute> oversized = GatewayCompositionFactory.ParseRoutes(
            new string(' ', GatewayCompositionFactory.MaximumRouteManifestCharacters + 1));
        Assert.Equal("openburnbar-local", Assert.Single(oversized).Id);
    }

    [Fact]
    public void Create_ResolvesBearerFromProtectedStoreAndNeverMetadata()
    {
        var configuration = new GatewayRouteConfiguration(
            "anthropic-primary",
            "anthropic",
            "claude-sonnet-4-5",
            "https://api.anthropic.com/v1/messages",
            0,
            true,
            GatewayRouteAuthentication.Bearer);

        using GatewayComposition composition = GatewayCompositionFactory.Create(
            new[] { configuration },
            routeId => routeId == "anthropic-primary" ? "protected-canary" : null);

        ModelRoute route = Assert.Single(composition.Router.Routes);
        Assert.True(route.IsExecutable);
        Assert.Equal("protected-canary", route.BearerToken);
        Assert.DoesNotContain("protected-canary", configuration.ToString(), StringComparison.Ordinal);
    }

    [Fact]
    public void Create_MissingBearerKeepsAdvertisedRouteUnavailable()
    {
        var configuration = new GatewayRouteConfiguration(
            "openai-primary",
            "openai",
            "gpt-5.4",
            "https://api.openai.com/v1/chat/completions",
            0,
            true,
            GatewayRouteAuthentication.Bearer);

        using GatewayComposition composition = GatewayCompositionFactory.Create(
            new[] { configuration },
            _ => null);

        ModelRoute route = Assert.Single(composition.Router.Routes);
        Assert.False(route.Healthy);
        Assert.False(route.IsExecutable);
        Assert.Null(route.BearerToken);
    }

    [Fact]
    public void Create_RejectsDuplicateRouteIds()
    {
        GatewayRouteConfiguration Route(string model) => new(
            "duplicate",
            "openai",
            model,
            "https://provider.example/v1/chat/completions",
            0,
            true,
            GatewayRouteAuthentication.None);

        Assert.Throws<ArgumentException>(() => GatewayCompositionFactory.Create(
            new[] { Route("one"), Route("two") },
            _ => null));
    }

    [Fact]
    public void Create_RejectsOversizedCredentialAndRouteCatalog()
    {
        var configuration = new GatewayRouteConfiguration(
            "bounded",
            "openai",
            "model",
            "https://provider.example/v1/chat/completions",
            0,
            true,
            GatewayRouteAuthentication.Bearer);

        Assert.Throws<ArgumentException>(() => GatewayCompositionFactory.Create(
            new[] { configuration },
            _ => new string('x', GatewayRouteConfiguration.MaximumCredentialLength + 1)));
        Assert.Throws<ArgumentException>(() => GatewayCompositionFactory.Create(
            Enumerable.Range(0, GatewayCompositionFactory.MaximumRouteCount + 1)
                .Select(index => configuration with { Id = "route-" + index })
                .ToArray(),
            _ => "credential"));
    }

    [Theory]
    [InlineData("http://provider.example/v1/chat/completions")]
    [InlineData("https://user:pass@provider.example/v1/chat/completions")]
    [InlineData("file:///tmp/provider")]
    public void Configuration_RejectsUnsafeEndpoint(string endpoint)
    {
        var configuration = new GatewayRouteConfiguration(
            "unsafe",
            "openai",
            "model",
            endpoint,
            0,
            true,
            GatewayRouteAuthentication.None);

        Assert.Throws<ArgumentException>(() => configuration.Resolve(null));
    }

    [Theory]
    [InlineData("http://127.0.0.1:11434/v1/chat/completions")]
    [InlineData("http://[::1]:11434/v1/chat/completions")]
    [InlineData("http://localhost:11434/v1/chat/completions")]
    public void Configuration_AllowsLoopbackHttp(string endpoint)
    {
        var configuration = new GatewayRouteConfiguration(
            "ollama-local",
            "ollama",
            "qwen3",
            endpoint,
            0,
            true,
            GatewayRouteAuthentication.None);

        Assert.True(configuration.Resolve(null).IsExecutable);
    }

    [Fact]
    public void Configuration_PreservesValidatedNonSecretRoutingMetadata()
    {
        var metadata = new ModelRouteRoutingMetadata(
            CredentialSlotId: "work",
            CanonicalModelId: "gpt-5.4",
            FormatFamily: "openai-compatible",
            EndpointProfileId: "openai.production",
            CapabilityScore: 0.9,
            CostPerMillionTokens: 12.5,
            LatencyMilliseconds: 80,
            TrustStatus: ModelRouteTrustStatus.Ready,
            QuotaRemainingPercent: 75);
        var configuration = new GatewayRouteConfiguration(
            "scored",
            "openai",
            "gpt-5.4",
            "https://api.openai.com/v1/chat/completions",
            0,
            true,
            GatewayRouteAuthentication.None,
            metadata);

        ModelRoute route = configuration.Resolve(null);

        Assert.Equal(metadata, route.Routing);
        Assert.DoesNotContain("BearerToken", configuration.ToString(), StringComparison.Ordinal);
    }

    [Theory]
    [InlineData(double.NaN, 1)]
    [InlineData(1, -1)]
    public void Configuration_RejectsInvalidRoutingMetadata(double capability, double cost)
    {
        var configuration = new GatewayRouteConfiguration(
            "invalid-score",
            "openai",
            "gpt",
            "https://api.openai.com/v1/chat/completions",
            0,
            true,
            GatewayRouteAuthentication.None,
            new ModelRouteRoutingMetadata(CapabilityScore: capability, CostPerMillionTokens: cost));

        Assert.ThrowsAny<ArgumentException>(() => configuration.Validate());
    }

    [Fact]
    public void Configuration_RejectsUnknownRoutingTrustState()
    {
        var configuration = new GatewayRouteConfiguration(
            "invalid-trust",
            "openai",
            "gpt",
            "https://api.openai.com/v1/chat/completions",
            0,
            true,
            GatewayRouteAuthentication.None,
            new ModelRouteRoutingMetadata(TrustStatus: (ModelRouteTrustStatus)999));

        Assert.Throws<ArgumentOutOfRangeException>(() => configuration.Validate());
    }
}
