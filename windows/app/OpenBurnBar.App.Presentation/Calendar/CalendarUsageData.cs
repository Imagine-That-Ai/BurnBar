using System.Collections.Generic;
using OpenBurnBar.App.Presentation.Dashboard;

namespace OpenBurnBar.App.Presentation.Calendar;

/// <summary>
/// The Calendar surface's usage rows plus where they came from. Reuses
/// <see cref="DashboardUsageOrigin"/> — the shared "where did usage numbers come
/// from" vocabulary — so surfaces label live vs synced vs demo data consistently.
/// </summary>
public sealed record CalendarUsageData(
    IReadOnlyList<CalendarUsageRow> Rows,
    DashboardUsageOrigin Origin)
{
    public static CalendarUsageData Empty { get; } =
        new(System.Array.Empty<CalendarUsageRow>(), DashboardUsageOrigin.Empty);

    public bool HasData => Rows.Count > 0;
}
