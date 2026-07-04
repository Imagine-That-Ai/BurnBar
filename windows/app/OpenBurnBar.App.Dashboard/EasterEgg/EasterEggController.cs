using System;
using System.Collections.Generic;

namespace OpenBurnBar.App.Dashboard.EasterEgg;

/// <summary>
/// Owns scroll-reversal tracking, cooldown gating, the boundary throttle, and the
/// single active event — a faithful C# port of the <c>EasterEggController</c> in
/// <c>EasterEggOverlay.swift</c>. Pure state (no timers): the Windows DashboardPage
/// feeds it the scroll viewer's offset each frame and mounts the Win2D easter-egg
/// canvas whenever <see cref="ActiveEvent"/> becomes non-null. The clock is injected
/// so the unit tests can drive the reversal window / cooldown / boundary throttle
/// deterministically (Swift used <c>Date()</c> directly).
/// </summary>
public sealed class EasterEggController
{
    private readonly Func<double> _nowSeconds;

    // Rapid-scroll reversal tracking.
    private double? _lastOffset;
    private int _lastDirection; // -1 up, +1 down, 0 unknown
    private readonly List<double> _reversalTimestamps = new();

    private const double ReversalWindow = 1.5;
    private const int ReversalsToSummon = 5;
    private const double SummonCooldown = 9.0; // matches the website's 9000ms
    private const double MinReversalDelta = 6;

    private double? _lastSummonAt;

    // Boundary throttle.
    private double? _lastBoundaryAt;
    private const double BoundaryCooldown = 1.2;
    private const double BoundaryOverscroll = 14;

    /// <summary>
    /// Construct the controller. <paramref name="nowSeconds"/> supplies a monotonic
    /// clock in seconds; defaults to wall-clock stopwatch time in production.
    /// </summary>
    public EasterEggController(Func<double>? nowSeconds = null)
    {
        _nowSeconds = nowSeconds ?? DefaultClock;
    }

    /// <summary>The currently playing event, or <c>null</c> when idle.</summary>
    public EasterEggEvent? ActiveEvent { get; private set; }

    /// <summary>Whether rapid-scroll storms are enabled at all.</summary>
    public bool IsEnabled { get; set; } = true;

    /// <summary>Raised when a new event is presented (host mounts the canvas).</summary>
    public event EventHandler<EasterEggEvent>? EventPresented;

    /// <summary>
    /// Feed the overview scroll geometry once per frame. Handles both the rapid
    /// up/down reversal summon and the top/bottom boundary tap. <paramref name="offset"/>
    /// follows the SwiftUI convention: <c>0</c> at the very top, growing negative as
    /// the user scrolls down.
    /// </summary>
    public void RegisterScrollMetrics(
        double offset,
        double contentHeight,
        double viewportHeight,
        bool isDark,
        bool reduceMotion)
    {
        if (!IsEnabled)
        {
            return;
        }

        DetectReversal(offset, isDark, reduceMotion);
        DetectBoundary(offset, contentHeight, viewportHeight, reduceMotion);
    }

    private void DetectReversal(double offset, bool isDark, bool reduceMotion)
    {
        double? previous = _lastOffset;
        _lastOffset = offset;
        if (previous is null)
        {
            return;
        }

        double delta = offset - previous.Value;
        if (Math.Abs(delta) < MinReversalDelta)
        {
            return;
        }

        int direction = delta < 0 ? 1 : -1;
        int priorDirection = _lastDirection;
        _lastDirection = direction;
        if (priorDirection == 0 || direction == priorDirection)
        {
            return;
        }

        // A genuine reversal: record it and prune anything older than the window.
        double now = _nowSeconds();
        _reversalTimestamps.Add(now);
        _reversalTimestamps.RemoveAll(t => now - t > ReversalWindow);

        if (_reversalTimestamps.Count >= ReversalsToSummon)
        {
            // Threshold reached: clear the window (so the gesture is consumed even
            // under Reduce Motion), then summon only when motion is allowed.
            _reversalTimestamps.Clear();
            SummonStorm(isDark, reduceMotion);
        }
    }

    private void DetectBoundary(double offset, double contentHeight, double viewportHeight, bool reduceMotion)
    {
        if (reduceMotion)
        {
            return;
        }

        double scrollable = contentHeight - viewportHeight;
        if (offset > BoundaryOverscroll)
        {
            FireBoundary(EasterEggEdge.Top);
        }
        else if (scrollable > 1 && offset < -(scrollable + BoundaryOverscroll))
        {
            FireBoundary(EasterEggEdge.Bottom);
        }
    }

    private void FireBoundary(EasterEggEdge edge)
    {
        double now = _nowSeconds();
        if (_lastBoundaryAt is double last && now - last < BoundaryCooldown)
        {
            return;
        }

        // A storm already in flight owns the screen; don't stack a boundary tap.
        if (ActiveEvent is not null)
        {
            return;
        }

        _lastBoundaryAt = now;
        Present(new EasterEggEvent(EasterEggKind.Boundary, now, edge));
    }

    private void SummonStorm(bool isDark, bool reduceMotion)
    {
        double now = _nowSeconds();
        if (_lastSummonAt is double last && now - last < SummonCooldown)
        {
            return;
        }

        if (ActiveEvent is not null)
        {
            return;
        }

        _lastSummonAt = now;

        // Reduce Motion: the gesture is consumed (cooldown armed above) but no
        // takeover is presented, matching the website's reduced-motion abort.
        if (reduceMotion)
        {
            return;
        }

        EasterEggKind kind = isDark ? EasterEggKind.LogoStorm : EasterEggKind.CloudTokenRain;
        Present(new EasterEggEvent(kind, now));
    }

    private void Present(EasterEggEvent e)
    {
        ActiveEvent = e;
        EventPresented?.Invoke(this, e);
    }

    /// <summary>The host calls this once an event has played out so the controller idles.</summary>
    public void EventDidFinish(Guid id)
    {
        if (ActiveEvent?.Id == id)
        {
            ActiveEvent = null;
        }
    }

    private static double DefaultClock() =>
        System.Diagnostics.Stopwatch.GetTimestamp() / (double)System.Diagnostics.Stopwatch.Frequency;
}
