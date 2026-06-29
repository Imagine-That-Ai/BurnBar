import OpenBurnBarCore
import SwiftUI

// MARK: - Shared concept building blocks
//
// Helpers reused by every named dashboard layout concept (Aurora, Nebula,
// Constellation, Cockpit, Atelier). Kept as `DashboardView` extension members
// so they can reach the view's data (`dashboardProviderSummaries`, the live
// cost curve, the lanes) without threading state through initializers.

extension DashboardView {

    /// The collapsed "more details" drawer every concept embeds beneath its
    /// curated hero — narrative banner + provider / model / activity lanes — so
    /// the curated layouts never *lose* information relative to Classic.
    var conceptMoreDrawer: some View {
        ConceptMoreDrawer {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xl) {
                NarrativeCardView(dataStore: dataStore)
                providerLane
                modelLane
                activityLane
            }
        }
    }

    /// The shared live cost curve wrapped in a glass card, for concepts that
    /// place the curve inside a framed tile (Aurora, Nebula, Cockpit).
    var conceptCurveCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                Text("Cumulative Cost")
                    .font(DesignSystem.Typography.tiny)
                    .textCase(.uppercase)
                    .tracking(1.1)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                liveCostCurveBand
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(DesignSystem.Spacing.lg)
        }
    }

    /// Provider drill-in used by the concept rails.
    func conceptOpenProvider(_ provider: AgentProvider, lane: String) {
        Analytics.shared.track(.dashboardLaneCardOpened, ["lane": .string(lane)])
        withAnimation(DesignSystem.Animation.standard) {
            navigate(to: .provider(provider))
        }
    }
}
