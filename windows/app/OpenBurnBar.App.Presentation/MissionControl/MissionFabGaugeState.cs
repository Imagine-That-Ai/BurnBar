using System;
using System.Collections.Generic;

namespace OpenBurnBar.App.Presentation.MissionControl;

// PORTED (faithful) from MissionFABGauge in
// OpenBurnBarCore/.../Views/MissionControl/MissionFABGauge.swift. The gauge's DECISION
// logic — arc color, center glyph, per-mission tick colors, tick geometry, sweep clamp,
// and the accessibility sentence — is pure and lives here so it is fully unit-testable on
// macOS. The WinUI MissionFabGaugeView renders it (XAML shapes or Win2D); it owns no state.

/// <summary>Semantic color role a gauge element resolves to. The WinUI layer maps each
/// role to a Pensieve brush; keeping it a role (not a Windows color) keeps this testable.</summary>
public enum MissionGaugeColorRole
{
    /// <summary>Amber — the default in-flight burn tint.</summary>
    Amber,
    /// <summary>Ember/accent — blocked runs.</summary>
    Ember,
    /// <summary>Aureate/brass — approval pending.</summary>
    Aureate,
    /// <summary>Success/green — only completed missions remain.</summary>
    Success,
    /// <summary>Muted — idle or Mac offline.</summary>
    Muted,
}

/// <summary>Gauge size presets. Mirrors <c>MissionFABGauge.Size</c>.</summary>
public enum MissionGaugeSize
{
    Compact,
    Standard,
    Hero,
}

/// <summary>Geometry for the gauge presets. Mirrors the Swift <c>Size</c> computed
/// properties (in device-independent points).</summary>
public static class MissionGaugeSizeInfo
{
    public static double Diameter(MissionGaugeSize size) => size switch
    {
        MissionGaugeSize.Compact => 44,
        MissionGaugeSize.Standard => 56,
        MissionGaugeSize.Hero => 84,
        _ => 56,
    };

    public static double RingThickness(MissionGaugeSize size) => size switch
    {
        MissionGaugeSize.Compact => 3.5,
        MissionGaugeSize.Standard => 4.5,
        MissionGaugeSize.Hero => 6.5,
        _ => 4.5,
    };

    public static double TickLength(MissionGaugeSize size) => size switch
    {
        MissionGaugeSize.Compact => 5,
        MissionGaugeSize.Standard => 6,
        MissionGaugeSize.Hero => 9,
        _ => 6,
    };

    public static double GlyphSize(MissionGaugeSize size) => size switch
    {
        MissionGaugeSize.Compact => 16,
        MissionGaugeSize.Standard => 21,
        MissionGaugeSize.Hero => 30,
        _ => 21,
    };
}

/// <summary>Immutable input to the gauge. Mirrors <c>MissionFABGauge.Configuration</c>
/// (burn sweep clamped to 0..1 on construction).</summary>
public sealed class MissionGaugeConfiguration
{
    public MissionGaugeConfiguration(
        MissionGaugeSize size,
        int activeMissionCount,
        int approvalPendingCount,
        int blockedCount,
        bool hasCompletedSinceLastOpen,
        double burnSweep,
        double burnPerHourUsd,
        bool macOnline)
    {
        Size = size;
        ActiveMissionCount = activeMissionCount;
        ApprovalPendingCount = approvalPendingCount;
        BlockedCount = blockedCount;
        HasCompletedSinceLastOpen = hasCompletedSinceLastOpen;
        BurnSweep = Math.Min(Math.Max(burnSweep, 0), 1);
        BurnPerHourUsd = burnPerHourUsd;
        MacOnline = macOnline;
    }

    public MissionGaugeSize Size { get; }
    public int ActiveMissionCount { get; }
    public int ApprovalPendingCount { get; }
    public int BlockedCount { get; }
    public bool HasCompletedSinceLastOpen { get; }

    /// <summary>Fraction of the day's burn budget (0..1, clamped).</summary>
    public double BurnSweep { get; }
    public double BurnPerHourUsd { get; }
    public bool MacOnline { get; }

    public static MissionGaugeConfiguration Idle { get; } = new(
        MissionGaugeSize.Standard, 0, 0, 0, false, 0, 0, true);
}

/// <summary>Pure derivation of what the gauge should draw for a given configuration.</summary>
public static class MissionFabGaugeState
{
    /// <summary>Primary arc/burn-rate color. Mirrors <c>primaryArcColor</c>: the priority
    /// order is offline &gt; blocked &gt; approval &gt; active &gt; completed &gt; idle.</summary>
    public static MissionGaugeColorRole PrimaryArcColor(MissionGaugeConfiguration c)
    {
        if (!c.MacOnline)
        {
            return MissionGaugeColorRole.Muted;
        }

        if (c.BlockedCount > 0)
        {
            return MissionGaugeColorRole.Ember;
        }

        if (c.ApprovalPendingCount > 0)
        {
            return MissionGaugeColorRole.Aureate;
        }

        if (c.ActiveMissionCount > 0)
        {
            return MissionGaugeColorRole.Amber;
        }

        if (c.HasCompletedSinceLastOpen)
        {
            return MissionGaugeColorRole.Success;
        }

        return MissionGaugeColorRole.Muted;
    }

    /// <summary>Segoe MDL2 center glyph (code point). Mirrors <c>glyphName</c>
    /// (SF Symbol -> MDL2). Each dominant state resolves a distinct existing glyph.</summary>
    public static string GlyphName(MissionGaugeConfiguration c)
    {
        if (!c.MacOnline)
        {
            return "\uEB5E";  // wifi.exclamationmark -> WifiWarning
        }

        if (c.ApprovalPendingCount > 0)
        {
            return "\uE769";  // hand.raised.fill -> Pause (paused for approval)
        }

        if (c.BlockedCount > 0)
        {
            return "\uE7BA";  // exclamationmark.triangle.fill -> Warning
        }

        if (c.ActiveMissionCount > 0)
        {
            return "\uE945";  // sparkles -> Light
        }

        if (c.HasCompletedSinceLastOpen)
        {
            return "\uE930";  // checkmark.seal.fill -> Completed
        }

        return "\uE70F";      // compass.drawing -> Edit (compose)
    }

    /// <summary>Number of perimeter ticks drawn (one per in-flight mission, capped 1..12).
    /// Mirrors <c>tickGeometry</c>'s <c>count</c>.</summary>
    public static int TickCount(MissionGaugeConfiguration c) =>
        Math.Max(1, Math.Min(c.ActiveMissionCount, 12));

    /// <summary>Color role for tick <paramref name="index"/>. Mirrors <c>tickColor(for:)</c>:
    /// the first N approval ticks glow aureate, the next M blocked ticks ember, remainder
    /// take the burn-arc tint.</summary>
    public static MissionGaugeColorRole TickColor(MissionGaugeConfiguration c, int index)
    {
        if (index < c.ApprovalPendingCount)
        {
            return MissionGaugeColorRole.Aureate;
        }

        if (index < c.ApprovalPendingCount + c.BlockedCount)
        {
            return MissionGaugeColorRole.Ember;
        }

        return PrimaryArcColor(c);
    }

    /// <summary>The tick angles (degrees, 0 at top, clockwise) for the current config.
    /// Mirrors the SwiftUI <c>rotationEffect(.degrees(idx * 360/count))</c> distribution.</summary>
    public static IReadOnlyList<double> TickAngles(MissionGaugeConfiguration c)
    {
        int count = TickCount(c);
        var angles = new double[count];
        for (int i = 0; i < count; i++)
        {
            angles[i] = i * (360.0 / count);
        }

        return angles;
    }

    /// <summary>Whether any tick is drawn at all. Mirrors the <c>opacity(count==0 ? 0 : 1)</c>
    /// gate — no active missions means the ticks are invisible.</summary>
    public static bool TicksVisible(MissionGaugeConfiguration c) => c.ActiveMissionCount > 0;

    /// <summary>The burn-per-hour readout shown on the hero gauge. Mirrors the Swift
    /// <c>MissionConsoleFormatting.cost(...)</c> readout.</summary>
    public static string BurnReadout(MissionGaugeConfiguration c) =>
        MissionFormatting.Cost(c.BurnPerHourUsd, c.BurnPerHourUsd < 1);

    /// <summary>The accessibility sentence. Mirrors <c>accessibilityLabel</c>.</summary>
    public static string AccessibilityLabel(MissionGaugeConfiguration c)
    {
        if (!c.MacOnline)
        {
            return "Mission Control. Mac offline.";
        }

        if (c.ApprovalPendingCount > 0)
        {
            return $"Mission Control. {c.ApprovalPendingCount} approval pending. {c.ActiveMissionCount} active.";
        }

        if (c.BlockedCount > 0)
        {
            return $"Mission Control. {c.BlockedCount} blocked. {c.ActiveMissionCount} active.";
        }

        if (c.ActiveMissionCount > 0)
        {
            return $"Mission Control. {c.ActiveMissionCount} missions in flight.";
        }

        if (c.HasCompletedSinceLastOpen)
        {
            return "Mission Control. Recent missions completed.";
        }

        return "Mission Control. Idle. Tap to compose.";
    }
}
