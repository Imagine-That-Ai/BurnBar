namespace OpenBurnBar.App.Shell;

/// <summary>
/// Portable key → logical page-type name map. Shared by
/// <see cref="SurfacePageResolver"/> (WinUI typeof wiring) and macOS-runnable shell
/// tests so IA-1 deferred routes cannot silently fall through the unknown catch-all
/// without an explicit registration row.
/// </summary>
public static class SurfaceRouteMap
{
    /// <summary>Logical name for the deferred-disclosure / unknown-key host page.</summary>
    public const string DeferredStubPage = "SurfaceStubPage";

    /// <summary>IA-1 macOS primary keys that intentionally host deferred disclosure only.</summary>
    public static readonly string[] Ia1DeferredDisclosureKeys = { "database", "projects" };

    /// <summary>Whether <paramref name="key"/> is an intentional IA-1 deferred stub route.</summary>
    public static bool IsIa1DeferredDisclosure(string key) =>
        key is "database" or "projects";

    /// <summary>
    /// Logical page type name for a nav key. Mirrors
    /// <see cref="SurfacePageResolver.Resolve"/>; keep both in lockstep.
    /// </summary>
    public static string LogicalPageType(string key) => key switch
    {
        "budget" => "BudgetPage",
        "quota" => "QuotaWorkspacePage",
        "insights" => "InsightsPage",
        "sessionLogs" => "SessionLogsHostPage",
        "dashboard" => "DashboardPage",
        "missionControl" => "MissionControlPage",
        "dataControlCenter" => "DataControlCenterPage",
        "chat" => "ChatHostPage",
        "switcher" => "SwitcherHostPage",
        "memory" => "MemoryPage",
        "elderWand" => "ElderWandPage",
        "onboarding" => "OnboardingPage",
        "settings" => "SettingsPage",
        // IA-1: explicit deferred disclosure (not unknown-key accidental stub).
        "database" => DeferredStubPage,
        "projects" => DeferredStubPage,
        _ => DeferredStubPage,
    };
}
