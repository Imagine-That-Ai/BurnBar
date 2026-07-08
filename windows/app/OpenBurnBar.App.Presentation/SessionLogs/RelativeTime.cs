using System;
using System.Globalization;

namespace OpenBurnBar.App.Presentation.SessionLogs;

// PORTED (faithful) from AgentLens/Views/SessionLogs/SessionLogDetailPane.swift
// `extension Date { var relativeLabel: String }`. Pure, `now`-injectable so the row
// timestamp is unit-testable.

/// <summary>Human-friendly relative timestamp used by session-log rows + detail header.</summary>
public static class RelativeTime
{
    public static string Label(DateTimeOffset value, DateTimeOffset now)
    {
        double interval = (now - value).TotalSeconds;
        if (interval < 60)
        {
            return "Just now";
        }

        if (interval < 3_600)
        {
            return $"{(int)(interval / 60)}m ago";
        }

        if (interval < 86_400)
        {
            return $"{(int)(interval / 3_600)}h ago";
        }

        if (interval < 604_800)
        {
            return $"{(int)(interval / 86_400)}d ago";
        }

        // Medium date style (locale-aware), matching DateFormatter.dateStyle = .medium.
        return value.ToString("MMM d, yyyy", CultureInfo.CurrentCulture);
    }
}
