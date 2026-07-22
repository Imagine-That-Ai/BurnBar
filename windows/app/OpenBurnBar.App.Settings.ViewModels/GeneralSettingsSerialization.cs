namespace OpenBurnBar.App.Settings.ViewModels;

/// <summary>Stable persisted identifiers and legacy aliases for General settings.</summary>
public static class GeneralSettingsSerialization
{
    public static GeneralTimeRange ParseTimeRange(string? raw) => (raw ?? string.Empty)
        .Trim()
        .ToLowerInvariant() switch
        {
            "week" or "last7days" or "last 7 days" => GeneralTimeRange.Last7Days,
            "month" or "last30days" or "last 30 days" => GeneralTimeRange.Last30Days,
            "thismonth" or "this month" => GeneralTimeRange.ThisMonth,
            "alltime" or "all time" => GeneralTimeRange.AllTime,
            _ => GeneralTimeRange.Today,
        };

    public static string TimeRangeKey(GeneralTimeRange range) => range switch
    {
        GeneralTimeRange.Today => "today",
        GeneralTimeRange.Last7Days => "last7days",
        GeneralTimeRange.Last30Days => "last30days",
        GeneralTimeRange.ThisMonth => "thismonth",
        GeneralTimeRange.AllTime => "alltime",
        _ => "today",
    };
}
