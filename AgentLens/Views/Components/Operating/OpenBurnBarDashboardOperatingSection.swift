import SwiftUI

// MARK: - Dashboard Operating Section

struct OpenBurnBarDashboardOperatingSection: View {
    @Bindable var layer: OpenBurnBarOperatingLayer
    var onOpenProjectSummary: ((String, String) -> Void)? = nil
    var onOpenEvidenceEntry: ((OpenBurnBarEvidenceEntry) -> Void)? = nil

    var body: some View {
        let snapshot = layer.snapshot

        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            OpenBurnBarOperatingFreshnessStrip(summary: snapshot.freshness, compact: false)

            HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                OpenBurnBarMissionSummaryCard(summary: snapshot.mission, onOpenSummary: onOpenProjectSummary)
                OpenBurnBarDirectionSummaryCard(summary: snapshot.direction, onOpenSummary: onOpenProjectSummary)
                OpenBurnBarBurnSummaryCard(summary: snapshot.burn, onOpenSummary: onOpenProjectSummary)
            }

            OpenBurnBarEvidencePanel(summary: snapshot.evidence, onOpenEntry: onOpenEvidenceEntry)
            OpenBurnBarOperatingActionBar(layer: layer, compact: false)
            OpenBurnBarControllerWorkbenchPanel(layer: layer, condensed: false)
            OpenBurnBarOperatingHistoryPanel(entries: snapshot.recentHistory)
        }
    }
}
