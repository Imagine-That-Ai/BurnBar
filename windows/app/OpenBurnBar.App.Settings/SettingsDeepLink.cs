// PORTED from AgentLens/Views/Settings/Search/SettingsRouter.swift (enum SettingsDeepLinkRouting).
//
// The Swift enum resolves a saved item id to a SettingsItem and, on route(to:),
// persists it to UserDefaults + posts a NotificationCenter message the settings
// window observes. Here the PURE resolver (Item / matching the manifest) is ported
// and unit-tested; the side effects (persist + broadcast) are surfaced as a plain
// event the WinUI shell subscribes to, keeping this type framework-free and testable.

namespace OpenBurnBar.App.Settings;

/// <summary>Resolves a persisted Settings item id and requests navigation (Swift <c>SettingsDeepLinkRouting</c>).</summary>
public static class SettingsDeepLink
{
    /// <summary>Notification/message name the settings window observes (parity with the Swift key).</summary>
    public const string OpenSettingsItemMessage = "openburnbar.openSettingsItem";

    /// <summary>Persistence key for the pending item id.</summary>
    public const string PendingItemKey = "settings.pendingItemID";

    /// <summary>Persistence key for the pending sidebar tab.</summary>
    public const string PendingTabKey = "settings.pendingTab";

    /// <summary>The quota-display deep link the menu-bar popover uses.</summary>
    public const string QuotaDisplayItemID = "agents.quotaDisplay";

    /// <summary>Raised when <see cref="Route"/> resolves an item; carries the resolved item id.</summary>
    public static event Action<string>? OpenSettingsItemRequested;

    /// <summary>
    /// Resolve a (possibly whitespace-padded) item id to its manifest row, or <c>null</c>
    /// when the id is empty or unknown (Swift <c>item(matching:)</c>).
    /// </summary>
    public static SettingsItem? Item(string? itemId)
    {
        var normalized = itemId?.Trim();
        if (string.IsNullOrEmpty(normalized)) return null;
        return SettingsManifest.All.FirstOrDefault(i => i.Id == normalized);
    }

    /// <summary>
    /// Resolve <paramref name="itemId"/> and, when valid, raise
    /// <see cref="OpenSettingsItemRequested"/> so the shell can select + scroll to it.
    /// Returns <c>true</c> when an item was resolved (Swift <c>route(to:)</c>).
    /// </summary>
    public static bool Route(string itemId)
    {
        var item = Item(itemId);
        if (item is null) return false;
        OpenSettingsItemRequested?.Invoke(item.Id);
        return true;
    }

    /// <summary>Convenience: route to the quota-display deep link (Swift <c>routeToQuotaDisplay</c>).</summary>
    public static void RouteToQuotaDisplay() => Route(QuotaDisplayItemID);
}
