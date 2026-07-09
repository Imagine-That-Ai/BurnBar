namespace OpenBurnBar.App.Presentation.Insights;

/// <summary>
/// Honest no-data widgets for production mode. Prefer this over
/// <see cref="InsightSampleData"/> whenever sample mode is off — production
/// surfaces must never paint fabricated rankings/series as live usage.
/// </summary>
public static class InsightEmptyData
{
    /// <summary>Default reason shown on empty tiles when no richer source label is supplied.</summary>
    public const string DefaultReason =
        "No live data yet. Connect the SQLCipher usage database (or Insights engine) in Settings → Data Sources, or launch with OPENBURNBAR_SAMPLE_MODE=1 for a labeled demo.";

    /// <summary>
    /// Produce an empty-state payload for any widget kind. KPI tiles keep a
    /// zeroed metric shell so the tile layout stays stable; every other kind
    /// uses <see cref="EmptyData"/> so the renderer shows the skeleton/message
    /// path rather than demo series.
    /// </summary>
    public static InsightWidgetData ForKind(InsightWidgetKind kind, int seed = 0, string? reason = null)
    {
        string label = reason ?? DefaultReason;
        return kind switch
        {
            InsightWidgetKind.KpiTile => EmptyKpi(seed, label),
            InsightWidgetKind.Error => new ErrorData(label),
            _ => new EmptyData(label),
        };
    }

    private static KpiData EmptyKpi(int seed, string reason) => seed switch
    {
        1 => new KpiData("Cost (this month)", 0, ValueFormat.Currency, ContextLabel: reason),
        2 => new KpiData("Sessions", 0, ValueFormat.Tokens, ContextLabel: reason),
        4 => new KpiData("Tokens", 0, ValueFormat.Tokens, ContextLabel: reason),
        _ => new KpiData("No data", 0, ValueFormat.Count, ContextLabel: reason),
    };
}
