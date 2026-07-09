namespace OpenBurnBar.App.Presentation.Dashboard;

/// <summary>
/// Deterministic Command-sidebar demo rows for <c>OPENBURNBAR_SAMPLE_MODE</c>.
/// Mirrors the shape of macOS <c>dashboardProviderSummaries</c> /
/// <c>dashboardModelSummaries</c> that fill <c>DashboardSidebarView</c>.
/// </summary>
public static class DashboardCommandSampleData
{
    public static DashboardCommandSnapshot Snapshot()
    {
        var providers = new DashboardProviderSidebarRow[]
        {
            new("openai", "OpenAI", 48.20, 1_620_000, 12, "$48.20"),
            new("anthropic", "Anthropic", 36.10, 1_180_000, 9, "$36.10"),
            new("cursor", "Cursor", 22.40, 980_000, 8, "$22.40"),
            new("grok", "Grok", 14.80, 640_000, 5, "$14.80"),
            new("gemini", "Gemini", 7.24, 400_000, 3, "$7.24"),
        };

        var models = new DashboardModelSidebarRow[]
        {
            new("gpt-4.1", "GPT-4.1", "openai", 28.40, 820_000, 6, "$28.40"),
            new("claude-sonnet-4", "Claude Sonnet 4", "anthropic", 24.10, 710_000, 5, "$24.10"),
            new("cursor-composer", "Composer", "cursor", 18.60, 540_000, 7, "$18.60"),
            new("grok-3", "Grok 3", "grok", 12.20, 410_000, 4, "$12.20"),
            new("gemini-2.5-pro", "Gemini 2.5 Pro", "gemini", 7.24, 400_000, 3, "$7.24"),
            new("o3-mini", "o3-mini", "openai", 19.80, 800_000, 6, "$19.80"),
            new("claude-opus-4", "Claude Opus 4", "anthropic", 12.00, 470_000, 4, "$12.00"),
        };

        return new DashboardCommandSnapshot(
            TotalCostUsd: 128.74,
            TotalTokens: 4_820_000,
            SessionCount: 37,
            OverviewMetricLabel: "$128.74",
            TimeRangeDisplayName: "This month",
            ActiveProviderCount: providers.Length,
            Providers: providers,
            Models: models,
            Origin: DashboardUsageOrigin.Sample);
    }
}
