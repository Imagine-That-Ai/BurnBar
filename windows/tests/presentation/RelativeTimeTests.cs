using System;
using OpenBurnBar.App.Presentation.SessionLogs;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests;

/// <summary>Tests for the relative-timestamp helper ported from
/// <c>extension Date { var relativeLabel }</c> in SessionLogDetailPane.swift.</summary>
public sealed class RelativeTimeTests
{
    private static readonly DateTimeOffset Now = new(2026, 7, 22, 12, 0, 0, TimeSpan.Zero);

    [Fact]
    public void JustNow_UnderOneMinute() =>
        Assert.Equal("Just now", RelativeTime.Label(Now.AddSeconds(-30), Now));

    [Fact]
    public void Minutes() =>
        Assert.Equal("5m ago", RelativeTime.Label(Now.AddMinutes(-5), Now));

    [Fact]
    public void Hours() =>
        Assert.Equal("3h ago", RelativeTime.Label(Now.AddHours(-3), Now));

    [Fact]
    public void Days() =>
        Assert.Equal("2d ago", RelativeTime.Label(Now.AddDays(-2), Now));

    [Fact]
    public void OlderThanAWeek_UsesMediumDate()
    {
        string label = RelativeTime.Label(Now.AddDays(-30), Now);
        Assert.DoesNotContain("ago", label);
        Assert.Contains("2026", label);
    }
}
