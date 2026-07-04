using System;
using OpenBurnBar.App.Presentation.MissionControl;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests.MissionControl;

/// <summary>Locks the hero editorial copy ported from <c>MissionConsoleHero</c>
/// (MissionConsoleHero.swift): headline priority, subtitle, and gauge burn-sweep.</summary>
public sealed class MissionHeroTextTests
{
    [Fact]
    public void Headline_ApprovalWinsFirst() =>
        Assert.Equal("Approval awaits the captain.",
            MissionHeroText.Headline(activeMissionCount: 3, approvalPendingCount: 1, blockedCount: 1, hasCompletedSinceLastOpen: true));

    [Fact]
    public void Headline_BlockedBeatsActive() =>
        Assert.Equal("A run is wedged. Look here.",
            MissionHeroText.Headline(activeMissionCount: 2, approvalPendingCount: 0, blockedCount: 1, hasCompletedSinceLastOpen: false));

    [Fact]
    public void Headline_SingleMissionIsSingular() =>
        Assert.Equal("1 mission in flight.",
            MissionHeroText.Headline(1, 0, 0, false));

    [Fact]
    public void Headline_MultipleMissionsArePlural() =>
        Assert.Equal("4 missions in flight.",
            MissionHeroText.Headline(4, 0, 0, false));

    [Fact]
    public void Headline_CompletedWhenIdleWithHistory() =>
        Assert.Equal("All clear. Pick the next one.",
            MissionHeroText.Headline(0, 0, 0, true));

    [Fact]
    public void Headline_EmptyStateComposePrompt() =>
        Assert.Equal("Compose a mission.",
            MissionHeroText.Headline(0, 0, 0, false));

    [Fact]
    public void Subtitle_WithRefreshSummarizesVitals()
    {
        var now = new DateTimeOffset(2026, 7, 3, 12, 0, 0, TimeSpan.Zero);
        var health = new MissionSystemHealth(
            DaemonState.Live, now.AddMinutes(-5), openMissions: 2, queuedMissions: 1,
            blockedMissions: 0, burnTodayUsd: 3.5, burnPerHourUsd: 1.2, onlineRuntimes: 4, totalRuntimes: 6);
        string subtitle = MissionHeroText.Subtitle(health, now);
        Assert.Contains("Today's burn $3.50", subtitle);
        Assert.Contains("4/6 runtimes awake", subtitle);
        Assert.Contains("5m ago", subtitle);
    }

    [Fact]
    public void Subtitle_WithoutRefreshShowsNudge()
    {
        var health = MissionSystemHealth.Empty; // LastRefresh == null
        Assert.Equal("Daemon snapshot not yet observed — refresh when you're ready.",
            MissionHeroText.Subtitle(health, DateTimeOffset.Now));
    }

    [Theory]
    [InlineData(0.0, 0.0)]
    [InlineData(1.5, 0.5)]    // 1.5/3 = 0.5
    [InlineData(3.0, 1.0)]    // full sweep at $3/hr
    [InlineData(9.0, 1.0)]    // clamps to 1
    public void BurnSweep_MapsRateToDial(double burnPerHour, double expected) =>
        Assert.Equal(expected, MissionHeroText.BurnSweep(burnPerHour), 5);
}
