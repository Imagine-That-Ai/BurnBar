using OpenBurnBar.App.Dashboard.EasterEgg;
using Xunit;

namespace OpenBurnBar.App.Dashboard.Tests;

/// <summary>
/// Locks the scroll-reversal summon state machine (<see cref="EasterEggController"/>):
/// the 5-reversal-in-1.5s threshold, the 9s summon cooldown, the boundary throttle,
/// theme selection, and the reduce-motion abort — all driven off an injected clock.
/// </summary>
public sealed class EasterEggControllerTests
{
    private sealed class TestClock
    {
        public double Value { get; set; }

        public double Now() => Value;
    }

    // Small, sub-overscroll offsets (|delta| = 10 >= 6) so a reversal fires without
    // ever crossing the 14pt boundary-overscroll threshold.
    private static readonly double[] Toggle = { 0, 10 };

    private static void FeedReversalBurst(EasterEggController c, bool isDark, bool reduceMotion = false, int alternations = 14)
    {
        for (int i = 0; i < alternations; i++)
        {
            c.RegisterScrollMetrics(Toggle[i % 2], contentHeight: 0, viewportHeight: 0, isDark, reduceMotion);
        }
    }

    // MARK: - Reversal summon

    [Fact]
    public void FiveReversals_Dark_SummonsLogoStorm()
    {
        var clock = new TestClock();
        var c = new EasterEggController(clock.Now);

        FeedReversalBurst(c, isDark: true);

        Assert.NotNull(c.ActiveEvent);
        Assert.Equal(EasterEggKind.LogoStorm, c.ActiveEvent!.Kind);
    }

    [Fact]
    public void FiveReversals_Light_SummonsCloudTokenRain()
    {
        var clock = new TestClock();
        var c = new EasterEggController(clock.Now);

        FeedReversalBurst(c, isDark: false);

        Assert.NotNull(c.ActiveEvent);
        Assert.Equal(EasterEggKind.CloudTokenRain, c.ActiveEvent!.Kind);
    }

    [Fact]
    public void FewReversals_DoNotSummon()
    {
        var clock = new TestClock();
        var c = new EasterEggController(clock.Now);

        // Only three direction changes — below the threshold of five.
        c.RegisterScrollMetrics(0, 0, 0, true, false);
        c.RegisterScrollMetrics(10, 0, 0, true, false);
        c.RegisterScrollMetrics(0, 0, 0, true, false);
        c.RegisterScrollMetrics(10, 0, 0, true, false);

        Assert.Null(c.ActiveEvent);
    }

    [Fact]
    public void Reversals_SpreadBeyondWindow_DoNotAccumulate()
    {
        var clock = new TestClock();
        var c = new EasterEggController(clock.Now);

        // One reversal every 0.4s: by the 5th the oldest has aged out of the 1.5s
        // window, so the in-window count never reaches five.
        c.RegisterScrollMetrics(0, 0, 0, true, false);   // init
        c.RegisterScrollMetrics(10, 0, 0, true, false);  // direction set
        double[] steps = { 0.4, 0.8, 1.2, 1.6, 2.0 };
        double[] toggle = { 0, 10 };
        for (int i = 0; i < steps.Length; i++)
        {
            clock.Value = steps[i];
            c.RegisterScrollMetrics(toggle[i % 2], 0, 0, true, false);
        }

        Assert.Null(c.ActiveEvent);
    }

    [Fact]
    public void ReduceMotion_ConsumesGesture_ButPresentsNothing()
    {
        var clock = new TestClock();
        var c = new EasterEggController(clock.Now);

        FeedReversalBurst(c, isDark: true, reduceMotion: true);

        Assert.Null(c.ActiveEvent);
    }

    [Fact]
    public void Disabled_IgnoresAllInput()
    {
        var clock = new TestClock();
        var c = new EasterEggController(clock.Now) { IsEnabled = false };

        FeedReversalBurst(c, isDark: true);
        c.RegisterScrollMetrics(50, 1000, 500, true, false); // would-be top boundary

        Assert.Null(c.ActiveEvent);
    }

    // MARK: - Cooldown

    [Fact]
    public void SecondSummon_WithinCooldown_IsSuppressed_ThenAllowedAfter9s()
    {
        var clock = new TestClock();
        var c = new EasterEggController(clock.Now);

        FeedReversalBurst(c, isDark: true);
        Assert.NotNull(c.ActiveEvent);
        System.Guid firstId = c.ActiveEvent!.Id;
        c.EventDidFinish(firstId);
        Assert.Null(c.ActiveEvent);

        // 5s later (< 9s cooldown): another burst must not summon.
        clock.Value = 5;
        FeedReversalBurst(c, isDark: true);
        Assert.Null(c.ActiveEvent);

        // 10s from the first summon (> 9s): now it may summon again.
        clock.Value = 10;
        FeedReversalBurst(c, isDark: true);
        Assert.NotNull(c.ActiveEvent);
        Assert.NotEqual(firstId, c.ActiveEvent!.Id);
    }

    // MARK: - Boundary

    [Fact]
    public void TopOverscroll_FiresTopBoundary()
    {
        var clock = new TestClock();
        var c = new EasterEggController(clock.Now);

        c.RegisterScrollMetrics(offset: 50, contentHeight: 1000, viewportHeight: 500, isDark: true, reduceMotion: false);

        Assert.NotNull(c.ActiveEvent);
        Assert.Equal(EasterEggKind.Boundary, c.ActiveEvent!.Kind);
        Assert.Equal(EasterEggEdge.Top, c.ActiveEvent.Edge);
    }

    [Fact]
    public void BottomOverscroll_FiresBottomBoundary()
    {
        var clock = new TestClock();
        var c = new EasterEggController(clock.Now);

        // scrollable = 500; offset below -(500 + 14) triggers the bottom edge.
        c.RegisterScrollMetrics(offset: -600, contentHeight: 1000, viewportHeight: 500, isDark: false, reduceMotion: false);

        Assert.NotNull(c.ActiveEvent);
        Assert.Equal(EasterEggKind.Boundary, c.ActiveEvent!.Kind);
        Assert.Equal(EasterEggEdge.Bottom, c.ActiveEvent.Edge);
    }

    [Fact]
    public void Boundary_IsThrottled_ThenAllowedAfterCooldown()
    {
        var clock = new TestClock();
        var c = new EasterEggController(clock.Now);

        c.RegisterScrollMetrics(50, 1000, 500, true, false);
        Assert.NotNull(c.ActiveEvent);
        c.EventDidFinish(c.ActiveEvent!.Id);
        Assert.Null(c.ActiveEvent);

        // 0.5s later (< 1.2s throttle): suppressed.
        clock.Value = 0.5;
        c.RegisterScrollMetrics(50, 1000, 500, true, false);
        Assert.Null(c.ActiveEvent);

        // 2.0s later (> 1.2s): fires again.
        clock.Value = 2.0;
        c.RegisterScrollMetrics(50, 1000, 500, true, false);
        Assert.NotNull(c.ActiveEvent);
    }

    [Fact]
    public void StormInFlight_SuppressesBoundary()
    {
        var clock = new TestClock();
        var c = new EasterEggController(clock.Now);

        FeedReversalBurst(c, isDark: true);
        Assert.NotNull(c.ActiveEvent);
        Assert.Equal(EasterEggKind.LogoStorm, c.ActiveEvent!.Kind);

        // An overscroll while a takeover owns the screen must not stack a boundary.
        c.RegisterScrollMetrics(50, 1000, 500, true, false);

        Assert.Equal(EasterEggKind.LogoStorm, c.ActiveEvent!.Kind);
    }

    [Fact]
    public void ReduceMotion_SuppressesBoundary()
    {
        var clock = new TestClock();
        var c = new EasterEggController(clock.Now);

        c.RegisterScrollMetrics(50, 1000, 500, isDark: true, reduceMotion: true);

        Assert.Null(c.ActiveEvent);
    }

    // MARK: - Teardown

    [Fact]
    public void EventDidFinish_ClearsActiveEvent()
    {
        var clock = new TestClock();
        var c = new EasterEggController(clock.Now);

        c.RegisterScrollMetrics(50, 1000, 500, true, false);
        Assert.NotNull(c.ActiveEvent);

        c.EventDidFinish(c.ActiveEvent!.Id);
        Assert.Null(c.ActiveEvent);
    }

    [Fact]
    public void EventDidFinish_WrongId_IsIgnored()
    {
        var clock = new TestClock();
        var c = new EasterEggController(clock.Now);

        c.RegisterScrollMetrics(50, 1000, 500, true, false);
        Assert.NotNull(c.ActiveEvent);

        c.EventDidFinish(System.Guid.NewGuid());
        Assert.NotNull(c.ActiveEvent);
    }

    [Fact]
    public void EventPresented_Fires_OnSummon()
    {
        var clock = new TestClock();
        var c = new EasterEggController(clock.Now);
        EasterEggEvent? presented = null;
        c.EventPresented += (_, e) => presented = e;

        FeedReversalBurst(c, isDark: true);

        Assert.NotNull(presented);
        Assert.Same(c.ActiveEvent, presented);
    }
}
