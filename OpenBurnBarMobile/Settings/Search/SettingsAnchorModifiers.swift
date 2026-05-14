import SwiftUI

// MARK: - Settings Anchor Helpers (iOS)

/// Wraps a settings sub-page so deep links from the search bar can scroll
/// to and highlight a specific control.
///
/// ```swift
/// SettingsDeepLinkScrollContainer(route: .hermes) { _ in
///     Form { ... }
/// }
/// ```
struct SettingsDeepLinkScrollContainer<Content: View>: View {
    @Environment(SettingsRouter.self) private var router: SettingsRouter?
    let route: SettingsPageRoute
    @ViewBuilder var content: (ScrollViewProxy) -> Content

    var body: some View {
        ScrollViewReader { proxy in
            content(proxy)
                .onAppear { applyPendingNavigation(proxy: proxy) }
                .onChange(of: router?.pendingAnchor) { _, _ in
                    applyPendingNavigation(proxy: proxy)
                }
        }
    }

    private func applyPendingNavigation(proxy: ScrollViewProxy) {
        guard let router else { return }
        guard let anchor = router.pendingAnchor else { return }
        guard SettingsManifest.anchorIndex[anchor] == route else { return }

        // Give the destination a tick to finish layout before scrolling.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(anchor, anchor: .center)
            }
            router.consumePendingAnchor(anchor)
        }
    }
}

// MARK: - Anchor + Highlight modifier

/// Tags a row with a stable id (so the `ScrollViewReader` can find it) and
/// paints a brief halo when the router asks for that anchor.
struct SettingsAnchorModifier: ViewModifier {
    @Environment(SettingsRouter.self) private var router: SettingsRouter?
    let anchor: String

    func body(content: Content) -> some View {
        content
            .id(anchor)
            .listRowBackground(highlightBackground)
    }

    @ViewBuilder
    private var highlightBackground: some View {
        if router?.highlightedAnchor == anchor {
            MobileTheme.amber.opacity(0.18)
                .animation(.easeInOut(duration: 0.35),
                           value: router?.highlightedAnchor)
        } else {
            Color.clear
        }
    }
}

extension View {
    /// Attach to a settings row so the iOS search router can deep-link to it.
    func settingsAnchor(_ anchor: String) -> some View {
        modifier(SettingsAnchorModifier(anchor: anchor))
    }
}
