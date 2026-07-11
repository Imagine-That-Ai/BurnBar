namespace OpenBurnBar.App.Presentation.Insights;

/// <summary>
/// Production empty-widget factory for Insights. Prefer this over fabricated
/// demo series whenever sample mode is off.
/// </summary>
public static class InsightsProductionEmpty
{
    public static InsightWidgetData ForKind(InsightWidgetKind kind, int seed = 0, string? reason = null) =>
        InsightEmptyData.ForKind(kind, seed, reason);
}
