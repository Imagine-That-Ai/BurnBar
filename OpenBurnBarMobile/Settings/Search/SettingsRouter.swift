import SwiftUI

// MARK: - Settings Router (iOS)

/// Drives programmatic navigation inside the iOS Settings hub when the
/// `.searchable` field is active.
///
/// Flow:
/// 1. User types into the Form's `.searchable` field — `query` updates.
/// 2. When `query` is non-empty, the hub renders `SettingsSearchResultsView`
///    in place of the Form (or above it depending on placement).
/// 3. User taps a row → `navigate(to:)` pushes the page route onto `path`
///    and stashes `pendingAnchor` / `pendingFocus`.
/// 4. The destination view consumes the pending anchor with a
///    `ScrollViewReader` proxy and focuses the bound `@FocusState` if a
///    focus id was supplied.
@Observable
@MainActor
final class SettingsRouter {

    /// Free-form search query.
    var query: String = ""

    /// `NavigationStack` path the hub binds to.
    var path: [SettingsPageRoute] = []

    /// Anchor id destinations should scroll to on appear. Cleared by
    /// `consumePendingAnchor(_:)`.
    var pendingAnchor: String?

    /// Focus id destinations should latch onto. Cleared by
    /// `consumePendingFocus(_:)`.
    var pendingFocus: String?

    /// Anchor id whose row should pulse-highlight while it animates into
    /// view. Cleared automatically after ~1.4s.
    var highlightedAnchor: String?

    var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func results(in items: [SettingsItem] = SettingsManifest.all) -> [SettingsItem] {
        SettingsSearchEngine.search(query, in: items)
    }

    /// Push the destination view and prime the anchor/focus for it.
    func navigate(to item: SettingsItem) {
        pendingAnchor = item.anchorID
        highlightedAnchor = item.anchorID
        pendingFocus = item.focusID

        switch item.pageRoute {
        case .hubRoot:
            // Row already lives on the root form — make sure no sub-page is
            // covering it.
            path.removeAll()
        case .cloud, .providerConnections, .hermes, .pi, .chatTiles, .media:
            path = [item.pageRoute]
        }

        // Clear the query so the hub shows the destination (not the
        // results list) once routing settles.
        query = ""

        scheduleHighlightClear(for: item.anchorID, after: 1.4)
    }

    /// Reset state without selecting anything (e.g. user dismissed search).
    func reset() {
        query = ""
        pendingAnchor = nil
        pendingFocus = nil
        highlightedAnchor = nil
        path.removeAll()
    }

    func consumePendingAnchor(_ anchor: String) {
        if pendingAnchor == anchor { pendingAnchor = nil }
    }

    func consumePendingFocus(_ focus: String) {
        if pendingFocus == focus { pendingFocus = nil }
    }

    private func scheduleHighlightClear(for anchor: String, after seconds: TimeInterval) {
        let target = anchor
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self else { return }
            if self.highlightedAnchor == target { self.highlightedAnchor = nil }
        }
    }
}
