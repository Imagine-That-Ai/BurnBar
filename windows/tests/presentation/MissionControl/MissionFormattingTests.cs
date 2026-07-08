using System;
using OpenBurnBar.App.Presentation.MissionControl;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests.MissionControl;

/// <summary>Locks the mono readout strings ported from <c>MissionConsoleFormatting</c>
/// (MissionConsoleTypes.swift). These are byte-exact against the Swift C-format specifiers.</summary>
public sealed class MissionFormattingTests
{
    [Theory]
    [InlineData(0.0042, false, "$0.0042")]   // < $1 -> 4dp
    [InlineData(0.5, false, "$0.5000")]      // < $1 -> 4dp
    [InlineData(1.0, false, "$1.00")]        // >= $1 -> 2dp
    [InlineData(12.5, false, "$12.50")]      // 2dp
    [InlineData(150.0, false, "$150")]       // >= $100 -> whole dollars
    [InlineData(150.0, true, "$150.0000")]   // precise overrides the >= $100 rounding
    [InlineData(2.5, true, "$2.5000")]       // precise -> 4dp
    public void Cost_MatchesSwiftFormat(double usd, bool precise, string expected) =>
        Assert.Equal(expected, MissionFormatting.Cost(usd, precise));

    [Fact]
    public void CostRange_UsesEnDash() =>
        Assert.Equal("$1.00–$2.00", MissionFormatting.CostRange(1.0, 2.0));

    [Theory]
    [InlineData(500, "500")]
    [InlineData(1500, "1.5k")]
    [InlineData(12000, "12.0k")]
    [InlineData(2_500_000, "2.5M")]
    public void Tokens_KAndMSuffixes(int count, string expected) =>
        Assert.Equal(expected, MissionFormatting.Tokens(count));

    [Fact]
    public void TokenRange_UsesEnDash() =>
        Assert.Equal("8.4k–15.6k", MissionFormatting.TokenRange(8400, 15600));

    [Theory]
    [InlineData(0, "00:00")]
    [InlineData(65, "01:05")]
    [InlineData(3661, "1:01:01")]   // hour form
    [InlineData(599, "09:59")]
    public void Duration_HmsForms(double seconds, string expected) =>
        Assert.Equal(expected, MissionFormatting.Duration(seconds));

    [Fact]
    public void Duration_NegativeClampsToZero() =>
        Assert.Equal("00:00", MissionFormatting.Duration(-5));

    [Fact]
    public void DurationRange_UsesEnDash() =>
        Assert.Equal("01:00–02:00", MissionFormatting.DurationRange(60, 120));

    [Theory]
    [InlineData(2, "just now")]
    [InlineData(30, "30s ago")]
    [InlineData(300, "5m ago")]
    [InlineData(7200, "2h ago")]
    [InlineData(172800, "2d ago")]
    public void RelativeTime_Buckets(double secondsAgo, string expected)
    {
        var now = new DateTimeOffset(2026, 7, 3, 12, 0, 0, TimeSpan.Zero);
        Assert.Equal(expected, MissionFormatting.RelativeTime(now.AddSeconds(-secondsAgo), now));
    }
}
