import SwiftUI

// MARK: - Settings Router (macOS)

/// Drives programmatic navigation inside Settings when the search bar is used.
///
/// Flow:
/// 1. User types into the sidebar search field — `query` updates.
/// 2. The detail pane swaps to `SettingsSearchResultsView` while
///    `isSearching == true`.
/// 3. User taps a result → `navigate(to:)` selects the owning tab, pushes the
///    page route onto `path`, and primes `pendingAnchor` / `pendingFocus`.
/// 4. Destination view detects matching `pendingAnchor`, scrolls there,
///    highlights briefly, and focuses the bound `@FocusState` if a `focusID`
///    was supplied.
@Observable
final class SettingsRouter {

    /// Current search query. Empty string means "no search active".
    var query: String = ""

    /// Sidebar tab the detail pane is currently bound to. Driven by the
    /// `SettingsView` selection binding.
    var selectedTab: SettingsTab? = .general

    /// Navigation path inside the detail `NavigationStack`. We model
    /// destinations as `SettingsPageRoute` values so the same router can
    /// drive both the sidebar selection and the in-stack push.
    var path: [SettingsPageRoute] = []

    /// Anchor ID destination views should scroll to once on appear. Cleared
    /// after the destination consumes it via `consumePendingAnchor(_:)`.
    var pendingAnchor: String?

    /// Focus ID destination views should latch onto. Cleared by
    /// `consumePendingFocus(_:)`.
    var pendingFocus: String?

    /// Anchor that should pulse-highlight on arrival (same string as
    /// `pendingAnchor`, kept separately so the highlight can fade
    /// independently of the scroll target).
    var highlightedAnchor: String?

    /// `true` when the user is actively searching.
    var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Convenience used by the results view.
    func results(in items: [SettingsItem] = SettingsManifest.all) -> [SettingsItem] {
        SettingsSearchEngine.search(query, in: items)
    }

    /// Drive navigation to the chosen item. Safe to call repeatedly — the
    /// router will replace any pending navigation state.
    func navigate(to item: SettingsItem) {
        selectedTab = item.tab
        pendingAnchor = item.anchorID
        highlightedAnchor = item.anchorID
        pendingFocus = item.focusID

        path = pathForRoute(item.pageRoute)

        // Clear the query so the detail pane shows the destination, not the
        // results list, once routing settles.
        query = ""

        // Fade the highlight after 1.4s.
        scheduleHighlightClear(for: item.anchorID, after: 1.4)
    }

    /// Reset all pending navigation state. Used when the search field is
    /// dismissed without selecting anything.
    func reset() {
        query = ""
        pendingAnchor = nil
        pendingFocus = nil
        highlightedAnchor = nil
        path.removeAll()
    }

    /// Destination views call this once they've scrolled to the anchor.
    func consumePendingAnchor(_ anchor: String) {
        if pendingAnchor == anchor { pendingAnchor = nil }
    }

    /// Destination views call this once they've claimed the focus state.
    func consumePendingFocus(_ focus: String) {
        if pendingFocus == focus { pendingFocus = nil }
    }

    // MARK: - Internals

    /// Maps a page route into the navigation path that should be present on
    /// the detail stack. Many tabs land on their root view, which uses an
    /// empty path; deep routes append the route.
    private func pathForRoute(_ route: SettingsPageRoute) -> [SettingsPageRoute] {
        switch route {
        // General subpages drill from `GeneralSettingsView`.
        case .generalRoot:
            return []
        case .operatorModel, .appearance, .defaultView, .dataRefresh,
             .indexing, .sessionSummaries:
            return [route]

        // Daemon subpages.
        case .daemonRoot:
            return []
        case .daemonLifecycle, .httpGateway, .controllerRuntime:
            return [route]

        // Tabs whose root view *is* the destination.
        case .accountRoot,
             .providersRoot,
             .routingPoolsRoot,
             .alertsRoot,
             .notificationsRoot,
             .devicesAndSyncRoot,
             .switcherRoot,
             .hermesRoot:
            return []
        case .hermesChatEngines, .hermesGateway, .hermesPiAgent, .hermesRelay, .hermesPiRelay:
            return [route]
        }
    }

    private func scheduleHighlightClear(for anchor: String, after seconds: TimeInterval) {
        let target = anchor
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self else { return }
            if self.highlightedAnchor == target { self.highlightedAnchor = nil }
        }
    }
}
