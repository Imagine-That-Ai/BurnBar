import SwiftUI

// MARK: - Settings Anchor Helpers

/// Wraps a detail view so deep links from the search bar can scroll to and
/// highlight a specific control. Usage:
///
/// ```swift
/// SettingsDeepLinkScrollContainer(route: .appearance) { proxy in
///     VStack {
///         row.settingsAnchor(SettingsAnchor.appearanceTheme)
///         row.settingsAnchor(SettingsAnchor.appearanceMenuBar)
///     }
/// }
/// ```
///
/// On appear, the container reads `SettingsRouter.pendingAnchor`. If it
/// belongs to `route`, it scrolls there, paints a brief halo, and asks the
/// router to clear its pending state.
struct SettingsDeepLinkScrollContainer<Content: View>: View {
    @Environment(SettingsRouter.self) private var router
    let route: SettingsPageRoute
    @ViewBuilder var content: (ScrollViewProxy) -> Content

    var body: some View {
        ScrollViewReader { proxy in
            content(proxy)
                .onAppear { applyPendingNavigation(proxy: proxy) }
                .onChange(of: router.pendingAnchor) { _, _ in
                    applyPendingNavigation(proxy: proxy)
                }
        }
    }

    private func applyPendingNavigation(proxy: ScrollViewProxy) {
        guard let anchor = router.pendingAnchor else { return }
        guard SettingsManifest.anchorIndex[anchor] == route else { return }

        // Slight delay lets the destination finish its onAppear layout pass
        // before we drive the scroll.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(anchor, anchor: .center)
            }
            router.consumePendingAnchor(anchor)
        }
    }
}

// MARK: - Anchor + Highlight modifier

/// Tags a row with a stable id (so `ScrollViewReader` can find it) and
/// paints a soft halo when the search router asks for that anchor.
struct SettingsAnchorModifier: ViewModifier {
    @Environment(SettingsRouter.self) private var router
    let anchor: String

    func body(content: Content) -> some View {
        content
            .id(anchor)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(highlightFill)
                    .padding(-DesignSystem.Spacing.xs)
                    .animation(.easeInOut(duration: 0.35),
                               value: router.highlightedAnchor == anchor)
            )
    }

    private var highlightFill: Color {
        router.highlightedAnchor == anchor
            ? DesignSystem.Colors.amber.opacity(0.18)
            : Color.clear
    }
}

extension View {
    /// Attach to a row to make it discoverable by the Settings search router.
    func settingsAnchor(_ anchor: String) -> some View {
        modifier(SettingsAnchorModifier(anchor: anchor))
    }
}
