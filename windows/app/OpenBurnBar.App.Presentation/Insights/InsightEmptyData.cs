namespace OpenBurnBar.App.Presentation.Insights;

/// <summary>
/// Honest no-data widgets for production mode. Prefer this over
/// fabricated demo series whenever demo mode is off — production
/// surfaces must never paint fabricated rankings/series as live usage.
///
/// KPI empties use <see cref="EmptyData"/> (not <see cref="KpiData"/> Value:0) so the
/// tile cannot be misread as live zero spend; reserve numeric 0 for real summaries
/// with <c>HasData == true</c>.
/// </summary>
public static class InsightEmptyData
{
    /// <summary>Default reason shown on empty tiles when no richer source label is supplied.</summary>
    public const string DefaultReason =
        "No live data yet. Connect the SQLCipher usage database (or Insights engine) in Settings → Data Sources, or launch with OPENBURNBAR_SAMPLE_MODE=1 for a labeled demo.";

    /// <summary>
    /// Produce an empty-state payload for any widget kind. Every kind uses
    /// <see cref="EmptyData"/> (or <see cref="ErrorData"/> for Error) so the
    /// renderer shows the skeleton/message path rather than a numeric zero KPI
    /// or demo series.
    /// </summary>
    public static InsightWidgetData ForKind(InsightWidgetKind kind, int seed = 0, string? reason = null)
    {
        string label = reason ?? DefaultReason;
        return kind switch
        {
            InsightWidgetKind.Error => new ErrorData(label),
            // KPI seed is accepted for API symmetry with demo generators; empty
            // chrome does not depend on seed (no fabricated metric label).
            _ => new EmptyData(label),
        };
    }
}
