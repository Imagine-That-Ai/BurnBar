import SwiftUI

// MARK: - AI Inbox as a first-class tab
//
// The standalone host for the inbox when the user adds it to the navigation
// tray (or opens it from the iPad sidebar). It provides the navigation chrome
// that `AIInboxView` deliberately does not carry — title, search field, detail
// destination — the same responsibilities `StreamsView` provides when the
// inbox renders as a Streams segment. Both hosts share the SAME hoisted
// `AIInboxStore`, so read/archive/snooze state, the Firestore listeners, and
// deep-link focus stay consistent no matter which surface the user reads from.

struct AIInboxTabScreen: View {
    @Bindable var store: AIInboxStore

    @State private var searchText = ""
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private static let iPhoneNavigationTrayClearance: CGFloat = 112

    var body: some View {
        ZStack {
            AuroraBackdrop()
            AIInboxSplitLayout(store: store)
                .padding(.bottom, listBottomPadding)
        }
        .navigationTitle("AI Inbox")
        .accessibilityIdentifier("screen.inbox")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(.hidden, for: .navigationBar)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search the inbox"
        )
        .onChange(of: searchText, initial: true) { _, query in
            store.searchQuery = query
        }
        .navigationDestination(for: AIInboxDetailRoute.self) { route in
            AIInboxDetailScreen(store: store, itemID: route.itemID)
        }
        .task { store.loadIfNeeded() }
        .refreshable {
            // Listener-backed: a snapshot is already the newest state, so
            // pull-to-refresh re-arms the listener rather than pretending to
            // fetch (same rationale as the Streams segment).
            HapticBus.refreshStarted()
            store.loadIfNeeded()
            HapticBus.refreshFinished()
        }
    }

    private var listBottomPadding: CGFloat {
        horizontalSizeClass == .compact
            ? Self.iPhoneNavigationTrayClearance
            : MobileTheme.Spacing.xxl
    }
}
