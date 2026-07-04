using System.Linq;
using OpenBurnBar.App.Presentation.MissionControl;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests.MissionControl;

/// <summary>Locks the FAB-gauge decision logic ported from <c>MissionFABGauge</c>
/// (MissionFABGauge.swift): arc color priority, glyph, tick colors + geometry, sweep clamp.</summary>
public sealed class MissionFabGaugeStateTests
{
    private static MissionGaugeConfiguration Config(
        int active = 0, int approval = 0, int blocked = 0,
        bool completed = false, double sweep = 0, double burnPerHour = 0, bool online = true) =>
        new(MissionGaugeSize.Standard, active, approval, blocked, completed, sweep, burnPerHour, online);

    [Fact]
    public void ArcColor_OfflineWinsOverEverything() =>
        Assert.Equal(
            MissionGaugeColorRole.Muted,
            MissionFabGaugeState.PrimaryArcColor(Config(active: 4, approval: 2, blocked: 1, online: false)));

    [Fact]
    public void ArcColor_BlockedBeatsApprovalAndActive() =>
        Assert.Equal(
            MissionGaugeColorRole.Ember,
            MissionFabGaugeState.PrimaryArcColor(Config(active: 3, approval: 2, blocked: 1)));

    [Fact]
    public void ArcColor_ApprovalBeatsActive() =>
        Assert.Equal(
            MissionGaugeColorRole.Aureate,
            MissionFabGaugeState.PrimaryArcColor(Config(active: 3, approval: 1)));

    [Fact]
    public void ArcColor_ActiveIsAmber() =>
        Assert.Equal(MissionGaugeColorRole.Amber, MissionFabGaugeState.PrimaryArcColor(Config(active: 2)));

    [Fact]
    public void ArcColor_CompletedIsSuccess() =>
        Assert.Equal(
            MissionGaugeColorRole.Success,
            MissionFabGaugeState.PrimaryArcColor(Config(completed: true)));

    [Fact]
    public void ArcColor_IdleIsMuted() =>
        Assert.Equal(MissionGaugeColorRole.Muted, MissionFabGaugeState.PrimaryArcColor(Config()));

    [Fact]
    public void Glyph_ChangesByDominantState()
    {
        string idle = MissionFabGaugeState.GlyphName(Config());
        string active = MissionFabGaugeState.GlyphName(Config(active: 2));
        string approval = MissionFabGaugeState.GlyphName(Config(active: 2, approval: 1));
        string blocked = MissionFabGaugeState.GlyphName(Config(active: 2, blocked: 1));
        string offline = MissionFabGaugeState.GlyphName(Config(online: false));
        // Each dominant state resolves a distinct, non-empty glyph.
        var all = new[] { idle, active, approval, blocked, offline };
        Assert.All(all, g => Assert.False(string.IsNullOrEmpty(g)));
        Assert.Equal(5, all.Distinct().Count());
    }

    [Fact]
    public void BurnSweep_ClampsToUnitRange()
    {
        Assert.Equal(1.0, Config(sweep: 4.2).BurnSweep);
        Assert.Equal(0.0, Config(sweep: -1).BurnSweep);
        Assert.Equal(0.42, Config(sweep: 0.42).BurnSweep, 5);
    }

    [Fact]
    public void TickCount_ClampsBetweenOneAndTwelve()
    {
        Assert.Equal(1, MissionFabGaugeState.TickCount(Config(active: 0)));
        Assert.Equal(5, MissionFabGaugeState.TickCount(Config(active: 5)));
        Assert.Equal(12, MissionFabGaugeState.TickCount(Config(active: 40)));
    }

    [Fact]
    public void TicksVisible_OnlyWhenActive()
    {
        Assert.False(MissionFabGaugeState.TicksVisible(Config(active: 0)));
        Assert.True(MissionFabGaugeState.TicksVisible(Config(active: 1)));
    }

    [Fact]
    public void TickColor_ApprovalTicksThenBlockedThenArc()
    {
        // 2 approvals + 1 blocked + remainder on a 5-active gauge.
        var c = Config(active: 5, approval: 2, blocked: 1);
        Assert.Equal(MissionGaugeColorRole.Aureate, MissionFabGaugeState.TickColor(c, 0));
        Assert.Equal(MissionGaugeColorRole.Aureate, MissionFabGaugeState.TickColor(c, 1));
        Assert.Equal(MissionGaugeColorRole.Ember, MissionFabGaugeState.TickColor(c, 2));
        // Index 3 is past approvals+blocked -> the arc tint (ember here, since blocked>0).
        Assert.Equal(MissionFabGaugeState.PrimaryArcColor(c), MissionFabGaugeState.TickColor(c, 3));
    }

    [Fact]
    public void TickAngles_AreEvenlyDistributed()
    {
        var angles = MissionFabGaugeState.TickAngles(Config(active: 4));
        Assert.Equal(new[] { 0.0, 90.0, 180.0, 270.0 }, angles);
    }

    [Fact]
    public void GaugeSizeInfo_HeroIsLargest()
    {
        Assert.True(MissionGaugeSizeInfo.Diameter(MissionGaugeSize.Hero)
            > MissionGaugeSizeInfo.Diameter(MissionGaugeSize.Standard));
        Assert.True(MissionGaugeSizeInfo.Diameter(MissionGaugeSize.Standard)
            > MissionGaugeSizeInfo.Diameter(MissionGaugeSize.Compact));
    }

    [Fact]
    public void AccessibilityLabel_ReflectsDominantState()
    {
        Assert.Contains("Mac offline", MissionFabGaugeState.AccessibilityLabel(Config(online: false)));
        Assert.Contains("approval pending", MissionFabGaugeState.AccessibilityLabel(Config(active: 2, approval: 1)));
        Assert.Contains("in flight", MissionFabGaugeState.AccessibilityLabel(Config(active: 3)));
        Assert.Contains("Idle", MissionFabGaugeState.AccessibilityLabel(Config()));
    }
}
