using System;
using OpenBurnBar.App.Presentation.SessionLogs;

namespace OpenBurnBar.App.SessionLogs;

/// <summary>
/// Tiny x:Bind function-binding helpers for the session-log row + group header, so the
/// XAML can format a relative timestamp / message count without a converter. Pure
/// formatting over the portable record — the display parity of the Swift
/// <c>CompactSessionRow</c> (time label, "N msgs", section count).
/// </summary>
public static class SessionLogRowFormat
{
    public static string Time(DateTimeOffset value) => RelativeTime.Label(value, DateTimeOffset.Now);

    public static string Messages(int count) => $"{count} msg{(count == 1 ? string.Empty : "s")}";

    public static string Count(int count) => count.ToString();

    /// <summary>Section header glyph for a group (Segoe Fluent). Time buckets and
    /// project/provider modes share a small icon vocabulary.</summary>
    public static string GroupGlyph(string groupId) => groupId switch
    {
        "today" => "",       // sunny
        "yesterday" => "",   // quiet hours / moon
        "week" => "",        // calendar
        "month" => "",       // calendar
        "older" => "",       // archive
        _ when groupId.StartsWith("project-", StringComparison.Ordinal) => "", // folder
        _ when groupId.StartsWith("provider-", StringComparison.Ordinal) => "", // processor
        _ => "",
    };
}
