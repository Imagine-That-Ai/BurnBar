using System;
using System.Collections.Generic;
using System.Linq;
using OpenBurnBar.App.ManagedAgentRuntime.Gateway;
using Xunit;

namespace OpenBurnBar.App.ManagedAgentRuntime.Tests;

public sealed class ModelProxyRouterTests
{
    private static readonly DateTimeOffset Now = new(2026, 7, 13, 12, 0, 0, TimeSpan.Zero);

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

    [Fact]
    public void SelectForModel_DefaultsToFailClosedInsteadOfCrossModelDegradation()
    {
        var router = new ModelProxyRouter(new[]
        {
            new ModelRoute("fallback", "openai", "gpt", Priority: 2, Healthy: true),
            new ModelRoute("preferred", "anthropic", "claude", Priority: 1, Healthy: false),
        });

        ModelRouteDecision decision = router.SelectForModel("claude");

        Assert.True(decision.FailedClosed);
        Assert.False(decision.Degraded);
        Assert.Equal("preferred", decision.Route.Id);
    }

    [Fact]
    public void Scorecard_UsesMacOSFiveFactorWeightsAndClampsDimensions()
    {
        var route = new ModelRoute(
            "route",
            "openai",
            "gpt",
            0,
            true,
            Routing: new ModelRouteRoutingMetadata(
                CapabilityScore: 2,
                CostPerMillionTokens: 5,
                LatencyMilliseconds: 50,
                TrustStatus: ModelRouteTrustStatus.Ready,
                PreferredSlot: true));

        RankedModelRoute ranked = Assert.Single(ModelRouteScorecard.Rank(new[] { route }, now: Now));

        Assert.Equal(1, ranked.Breakdown.Score.Capability);
        Assert.Equal(1, ranked.Breakdown.Score.Cost);
        Assert.Equal(1, ranked.Breakdown.Score.Latency);
        Assert.Equal(1, ranked.Breakdown.Score.Trust);
        Assert.Equal(1, ranked.Breakdown.Score.PolicyFit);
        Assert.Equal(1, ranked.Breakdown.Score.Composite, precision: 10);
    }

    [Fact]
    public void Scorecard_RanksByCostLatencyTrustAndPreferredVendor()
    {
        var routes = new[]
        {
            Route("slow", "anthropic", cost: 30, latency: 200, ModelRouteTrustStatus.CoolingDown),
            Route("winner", "openai", cost: 5, latency: 50, ModelRouteTrustStatus.Ready),
        };

        IReadOnlyList<RankedModelRoute> ranked = ModelRouteScorecard.Rank(routes, "openai", Now);

        Assert.Equal("winner", ranked[0].Route.Id);
        Assert.True(ranked[0].Breakdown.Score.Composite > ranked[1].Breakdown.Score.Composite);
        Assert.True(ranked[0].Breakdown.RawPolicyFitPreferred);
    }

    [Fact]
    public void Scorecard_DrainsSoonestActiveQuotaWindowWithinOnePool()
    {
        var routes = new[]
        {
            Route("better-score", "openai", cost: 1, latency: 50, ModelRouteTrustStatus.Ready,
                slot: "a", reset: Now.AddHours(4), remaining: 90),
            Route("soonest-reset", "openai", cost: 50, latency: 200, ModelRouteTrustStatus.Ready,
                slot: "b", reset: Now.AddHours(1), remaining: 10),
        };

        IReadOnlyList<RankedModelRoute> ranked = ModelRouteScorecard.Rank(routes, now: Now);

        Assert.Equal("soonest-reset", ranked[0].Route.Id);
    }

    [Fact]
    public void Scorecard_UsesRemainingQuotaWhenResetOrderingTies()
    {
        var reset = Now.AddHours(1);
        var routes = new[]
        {
            Route("low-headroom", "openai", 1, 50, ModelRouteTrustStatus.Ready,
                slot: "a", reset: reset, remaining: 10),
            Route("high-headroom", "openai", 50, 200, ModelRouteTrustStatus.Ready,
                slot: "b", reset: reset, remaining: 80),
        };

        Assert.Equal("high-headroom", ModelRouteScorecard.Rank(routes, now: Now)[0].Route.Id);
    }

    [Fact]
    public void Scorecard_DoesNotApplyQuotaDrainAcrossProviderPools()
    {
        var routes = new[]
        {
            Route("healthy", "openai", 1, 50, ModelRouteTrustStatus.Ready,
                slot: "a", reset: Now.AddHours(4), remaining: 90),
            Route("other-provider", "anthropic", 50, 200, ModelRouteTrustStatus.CoolingDown,
                slot: "b", reset: Now.AddMinutes(5), remaining: 99),
        };

        Assert.Equal("healthy", ModelRouteScorecard.Rank(routes, now: Now)[0].Route.Id);
    }

    [Fact]
    public void Scorecard_SkipsExhaustedMissingAndDisabledRoutes()
    {
        var routes = new[]
        {
            Route("exhausted", "openai", 1, 50, ModelRouteTrustStatus.Exhausted),
            Route("missing", "openai", 1, 50, ModelRouteTrustStatus.MissingSecret),
            Route("disabled", "openai", 1, 50, ModelRouteTrustStatus.Disabled),
            Route("ready", "openai", 1, 50, ModelRouteTrustStatus.Ready),
        };

        RankedModelRoute route = Assert.Single(ModelRouteScorecard.Rank(routes, now: Now));
        Assert.Equal("ready", route.Route.Id);
    }

    [Fact]
    public void Scorecard_UsesDeterministicLeastRecentlySelectedSlotTieBreak()
    {
        var routes = new[]
        {
            Route("newer", "openai", 1, 100, ModelRouteTrustStatus.Ready,
                slot: "z", lastSelected: Now.AddMinutes(-1)),
            Route("older", "openai", 1, 100, ModelRouteTrustStatus.Ready,
                slot: "a", lastSelected: Now.AddHours(-1)),
        };

        IReadOnlyList<RankedModelRoute> first = ModelRouteScorecard.Rank(routes, now: Now);
        IReadOnlyList<RankedModelRoute> second = ModelRouteScorecard.Rank(routes.Reverse(), now: Now);

        Assert.Equal(new[] { "older", "newer" }, first.Select(entry => entry.Route.Id));
        Assert.Equal(first.Select(entry => entry.Route.Id), second.Select(entry => entry.Route.Id));
    }

    [Fact]
    public void Select_ExposesScoreBreakdownForTheProductionDecision()
    {
        var router = new ModelProxyRouter(new[]
        {
            Route("route", "openai", 1, 50, ModelRouteTrustStatus.Ready),
        });

        ModelRouteDecision decision = router.Select("openai");

        Assert.NotNull(decision.Score);
        Assert.Equal("route", decision.Score.RouteId);
        Assert.Equal(ModelRouteTrustStatus.Ready, decision.Score.RawTrustStatus);
    }

    private static ModelRoute Route(
        string id,
        string vendor,
        double cost,
        double latency,
        ModelRouteTrustStatus trust,
        string? slot = null,
        DateTimeOffset? reset = null,
        double? remaining = null,
        DateTimeOffset? lastSelected = null) => new(
            id,
            vendor,
            "shared-model",
            Priority: 0,
            Healthy: true,
            Routing: new ModelRouteRoutingMetadata(
                CredentialSlotId: slot,
                CanonicalModelId: "shared-model",
                FormatFamily: "openai-compatible",
                CapabilityScore: 0.7,
                CostPerMillionTokens: cost,
                LatencyMilliseconds: latency,
                TrustStatus: trust,
                LastSelectedAt: lastSelected,
                QuotaResetsAt: reset,
                QuotaRemainingPercent: remaining));
}
