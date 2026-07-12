using System;

namespace OpenBurnBar.App.Presentation.MissionControl;

// PORTED (faithful) from MissionConsoleHero in
// OpenBurnBarCore/.../Views/MissionControl/MissionConsoleHero.swift. The hero's editorial
// copy (headline + subtitle + gauge burn-sweep) is derived, not rendered, here so the
// exact captain-facing sentences are unit-testable on macOS.

/// <summary>Derives the console hero's headline, subtitle, and gauge burn-sweep.</summary>
public static class MissionHeroText
{
    /// <summary>The one-line headline. Mirrors <c>headlineText</c>: priority order is
    /// approvals &gt; blocked &gt; in-flight &gt; recently-completed &gt; compose.</summary>
    public static string Headline(
        int activeMissionCount,
        int approvalPendingCount,
        int blockedCount,
        bool hasCompletedSinceLastOpen)
    {
        if (approvalPendingCount > 0)
        {
            return "Approval awaits the captain.";
        }

        if (blockedCount > 0)
        {
            return "A run is wedged. Look here.";
        }

        if (activeMissionCount > 0)
        {
            return activeMissionCount == 1
                ? "1 mission in flight."
                : $"{activeMissionCount} missions in flight.";
        }

        if (hasCompletedSinceLastOpen)
        {
            return "All clear. Pick the next one.";
        }

        return "Compose a mission.";
    }

    /// <summary>The subtitle. Mirrors <c>subtitleText</c>: the daemon-snapshot summary when
    /// a refresh timestamp exists, else the "not yet observed" nudge.</summary>
    public static string Subtitle(MissionSystemHealth health, DateTimeOffset reference)
    {
        if (health.LastRefresh is DateTimeOffset last)
        {
            string rel = MissionFormatting.RelativeTime(last, reference);
            string burn = MissionFormatting.Cost(health.BurnTodayUsd);
            return $"Today's burn {burn} · {health.OnlineRuntimes}/{health.TotalRuntimes} runtimes awake · runtime snapshot {rel}.";
        }

        return "Daemon snapshot not yet observed — refresh when you're ready.";
    }

    /// <summary>The gauge sweep for the hero. Mirrors <c>burnSweep</c>:
    /// $1/hr = a third of the dial, $3/hr = full sweep.</summary>
    public static double BurnSweep(double burnPerHourUsd) =>
        Math.Min(1.0, Math.Max(0.0, burnPerHourUsd / 3.0));
}
