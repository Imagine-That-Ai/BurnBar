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
            dataStore: dataStore,
            daemonManager: operatingLayer.daemonManager,
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
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
