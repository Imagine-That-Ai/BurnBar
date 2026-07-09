using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;

namespace OpenBurnBar.App.Shell;

/// <summary>
/// Portable key → logical page-type name map. Shared by
/// <see cref="SurfacePageResolver"/> (WinUI typeof wiring) and macOS-runnable shell
/// tests so IA-1 deferred routes cannot silently fall through the unknown catch-all
/// without an explicit registration row.
///
/// Product logical names are the single allowlist: WinUI binding must cover every
/// non-stub name (validated at <see cref="SurfacePageResolver"/> type load).
/// </summary>
public static class SurfaceRouteMap
{
    /// <summary>Logical name for the deferred-disclosure / unknown-key host page.</summary>
    public const string DeferredStubPage = "SurfaceStubPage";

    /// <summary>IA-1 macOS primary keys that intentionally host deferred disclosure only.</summary>
    public static readonly string[] Ia1DeferredDisclosureKeys = { "database", "projects" };

    /// <summary>
    /// Explicit product (non-stub) key → logical page name. Add new destinations here first;
    /// <see cref="SurfacePageResolver"/> must bind every distinct value or fail at load.
    /// </summary>
    private static readonly IReadOnlyDictionary<string, string> ProductKeyToLogical =
        new ReadOnlyDictionary<string, string>(new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["budget"] = "BudgetPage",
            ["quota"] = "QuotaWorkspacePage",
            ["insights"] = "InsightsPage",
            ["sessionLogs"] = "SessionLogsHostPage",
            ["dashboard"] = "DashboardPage",
            ["missionControl"] = "MissionControlPage",
            ["dataControlCenter"] = "DataControlCenterPage",
            ["chat"] = "ChatHostPage",
            ["switcher"] = "SwitcherHostPage",
            ["memory"] = "MemoryPage",
            ["elderWand"] = "ElderWandPage",
            ["onboarding"] = "OnboardingPage",
            ["settings"] = "SettingsPage",
        });

    /// <summary>Distinct non-stub logical page names that WinUI must bind.</summary>
    public static IReadOnlyList<string> ProductLogicalPageNames { get; } =
        ProductKeyToLogical.Values.Distinct(StringComparer.Ordinal).OrderBy(n => n, StringComparer.Ordinal).ToList();

    /// <summary>Whether <paramref name="key"/> is an intentional IA-1 deferred stub route.</summary>
    public static bool IsIa1DeferredDisclosure(string key) =>
        key is "database" or "projects";

    /// <summary>
    /// Logical page type name for a nav key. IA-1 deferred keys and unknown keys
    /// return <see cref="DeferredStubPage"/>.
    /// </summary>
    public static string LogicalPageType(string key)
    {
        if (ProductKeyToLogical.TryGetValue(key, out string? logical))
        {
            return logical;
        }

        // IA-1 explicit deferred disclosure + unknown keys.
        return DeferredStubPage;
    }

    /// <summary>
    /// Fail closed when a WinUI binder omits a product logical name (desync guard).
    /// Called from <see cref="SurfacePageResolver"/> static construction.
    /// </summary>
    public static void AssertWinUiBindingsCoverProductLogicalNames(IReadOnlyCollection<string> boundLogicalNames)
    {
        ArgumentNullException.ThrowIfNull(boundLogicalNames);
        var missing = ProductLogicalPageNames
            .Where(name => !boundLogicalNames.Contains(name, StringComparer.Ordinal))
            .ToList();
        if (missing.Count > 0)
        {
            throw new InvalidOperationException(
                "SurfacePageResolver is missing WinUI bindings for logical page name(s): " +
                string.Join(", ", missing) +
                ". Update SurfacePageResolver to match SurfaceRouteMap.ProductLogicalPageNames.");
        }
    }
}
