using OpenBurnBar.App.ManagedAgentRuntime.Gateway;
using Xunit;

namespace OpenBurnBar.App.ManagedAgentRuntime.Tests;

public sealed class ModelProxyRouterTests
{
    [Fact]
    public void Select_PrefersHealthyPreferredVendor()
    {
        var router = new ModelProxyRouter(new[]
        {
            new ModelRoute("a", "anthropic", "claude", Priority: 1, Healthy: true),
            new ModelRoute("b", "openai", "gpt", Priority: 2, Healthy: true),
        });
        ModelRouteDecision d = router.Select("openai");
        Assert.Equal("b", d.Route.Id);
        Assert.False(d.Degraded);
        Assert.False(d.FailedClosed);
    }

    [Fact]
    public void Select_DegradesWhenPreferredUnhealthy()
    {
        var router = new ModelProxyRouter(new[]
        {
            new ModelRoute("a", "anthropic", "claude", Priority: 1, Healthy: true),
            new ModelRoute("b", "openai", "gpt", Priority: 2, Healthy: false),
        });
        ModelRouteDecision d = router.Select("openai");
        Assert.Equal("a", d.Route.Id);
        Assert.True(d.Degraded);
    }

    [Fact]
    public void Select_FailsClosedWhenNoneHealthy()
    {
        var router = new ModelProxyRouter(new[]
        {
            new ModelRoute("a", "anthropic", "claude", Priority: 1, Healthy: false),
        });
        ModelRouteDecision d = router.Select();
        Assert.True(d.FailedClosed);
        Assert.Equal(1, router.SnapshotMetrics()["a"].Attempts);
    }
}
