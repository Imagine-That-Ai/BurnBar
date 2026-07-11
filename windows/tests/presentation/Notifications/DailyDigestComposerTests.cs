using System;
using System.Collections.Generic;
using OpenBurnBar.App.Presentation.Notifications;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests.Notifications;

public sealed class DailyDigestComposerTests
{
    [Fact]
    public void Compose_EmptyDay_IsHonestEmpty()
    {
        DailyDigest digest = DailyDigestComposer.Compose(Array.Empty<DailyDigestEvent>(), new DateOnly(2026, 7, 9));
        Assert.True(digest.IsEmpty);
        Assert.Equal(0, digest.Sessions);
    }

    [Fact]
    public void Compose_AggregatesSpendTokensSessions()
    {
        var day = new DateOnly(2026, 7, 9);
        var events = new List<DailyDigestEvent>
        {
            new(new DateTimeOffset(2026, 7, 9, 10, 0, 0, TimeSpan.Zero), "s1", "claude", 1.5, 100),
            new(new DateTimeOffset(2026, 7, 9, 11, 0, 0, TimeSpan.Zero), "s1", "claude", 0.5, 50),
            new(new DateTimeOffset(2026, 7, 9, 12, 0, 0, TimeSpan.Zero), "s2", "codex", 2.0, 200),
            new(new DateTimeOffset(2026, 7, 8, 12, 0, 0, TimeSpan.Zero), "s3", "claude", 9.0, 900), // other day
        };
        DailyDigest digest = DailyDigestComposer.Compose(events, day);
        Assert.False(digest.IsEmpty);
        Assert.Equal(4.0, digest.SpendUsd);
        Assert.Equal(350, digest.Tokens);
        Assert.Equal(2, digest.Sessions);
        Assert.NotEmpty(digest.Highlights);
    }
}
