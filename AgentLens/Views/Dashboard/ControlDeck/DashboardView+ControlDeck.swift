import SwiftUI

// MARK: - Control Deck route
//
// The `.controlDeck` arm of `DashboardView.detailView`, kept in its own file so
// the switch in `DashboardView.swift` stays one line and the whole feature
// reverts by deleting this directory plus one enum case.

extension DashboardView {

    @ViewBuilder
    var controlDeckRouteView: some View {
        ControlDeckView(
            settingsManager: settingsManager,
            operatingLayer: operatingLayer,
            dataStore: dataStore,
            daemonManager: operatingLayer.daemonManager,
            accountManager: accountManager,
            model: .shared,
            // Today's window, not the dashboard's selected range: a spend
            // threshold is a *daily* threshold, so showing it against a
            // 30-day total would be a lie with a number attached. The
            // summary is cached per window by `DashboardUsageViewModel`.
            todaySpend: dataStore.usageWindowSummary(for: .today).totalCost,
            onOpenSettings: { itemID in
                presentSettings(itemID: itemID)
            },
            onNavigate: { route in
                withAnimation(DesignSystem.Animation.standard) {
                    navigate(to: route)
                }
            },
            // The composer is already hosted on `DashboardView`; the tile only
            // asks for it. Casting stays behind the composer's own
            // commands / file-edits / approval switches, because a cast spends
            // provider credits and can edit files.
            onCastWand: { showMacWandComposer = true }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
