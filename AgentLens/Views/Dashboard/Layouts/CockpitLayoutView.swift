import OpenBurnBarCore
import SwiftUI

// MARK: - Cockpit (storage id `cockpit`)
//
// For the operator — the person who is not asking "how much" but "is anything
// wrong, and where."
//
// Thesis: instruments, not numbers. A ratio drawn as a gauge answers "is this
// normal?" in one glance, which a formatted figure never does. Under the gauges
// sits an alarm panel that is *quiet when nothing is wrong*, then the live
// routing stage, then the dense ranked ladder.
//
// Primary axis: horizontal bands, top to bottom by urgency: instruments →
// alarms → routing → detail. Dominant element: the gauge cluster.
// Density: the highest of the eight.
//
// Enforced rule: **Cockpit is the only layout with gauges.** `CockpitGauge` and
// `CockpitAlarmRow` belong to the Cockpit idiom — this layout and the matching
// `HomeCockpitShell` — and appear nowhere else. The reason is in that file's
// header: an arc gauge is an operator idiom, so it belongs to the operator
// surfaces. Any other layout that wants one should render a number.

extension DashboardView {
    var cockpitLayout: some View {
        conceptCanvas(spacing: DesignSystem.Spacing.md) {
            conceptUpdateBanner
            cockpitInstruments
            cockpitAlarmPanel
            cockpitRoutingBand
            cockpitLadder
            conceptDetailsDrawer(includesLiveCurve: false, includesCastle: false)
        }
    }

    // MARK: Instruments

    private var cockpitInstruments: some View {
        DashboardSection(
            "Instruments",
            title: dataStore.moodLabel,
            accent: DesignSystem.Colors.ember,
            emphasis: .featured,
            accessory: {
                Text(selectedTimeRange.displayName.uppercased())
                    .font(DesignSystem.Typography.tiny)
                    .tracking(1.1)
                    .foregroundStyle(dashboardSectionInk.subtle)
            },
            content: {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: DesignSystem.Spacing.lg) {
                        cockpitGauges
                    }
                    VStack(spacing: DesignSystem.Spacing.lg) {
                        cockpitGauges
                    }
                }
            }
        )
    }

    @ViewBuilder
    private var cockpitGauges: some View {
        CockpitGauge(
            label: "Pace vs 7-day",
            readout: cockpitPaceReadout,
            // The arc runs 0…2× the rolling average, so "normal" sits at the
            // halfway mark and an operator reads deviation, not magnitude.
            value: cockpitPaceRatio / 2,
            redline: 0.6,
            accent: DesignSystem.Colors.whimsy,
            caption: "today"
        )
        CockpitGauge(
            label: "Cache hit",
            readout: dashboardUsageWindow.cacheEfficiency.formattedHitRate,
            value: dashboardUsageWindow.cacheEfficiency.hitRate ?? 0,
            // High is good here, so there is nothing to redline. The tier colour
            // carries the judgment instead.
            redline: nil,
            accent: CacheHitRateTier(cockpitCacheEfficiency).color,
            caption: cockpitCacheEfficiency.hasSignal ? "of prompt" : "no signal"
        )
        CockpitGauge(
            label: "Concentration",
            readout: "\(Int((cockpitConcentration * 100).rounded()))%",
            value: cockpitConcentration,
            redline: 0.8,
            accent: DesignSystem.Colors.amber,
            caption: topProviderSummary?.provider.displayName ?? "—"
        )
    }

    private var cockpitCacheEfficiency: CacheEfficiency {
        dashboardUsageWindow.cacheEfficiency
    }

    /// Today's spend against the rolling 7-day daily average.
    ///
    /// Returns `1` (dead centre) while the baseline is still being built rather
    /// than `0`, because an instrument reading zero means "nothing is happening"
    /// and that would be a lie on a fresh install.
    private var cockpitPaceRatio: Double {
        guard dataStore.rollingDailyAverage > 0 else { return 1 }
        return max(0, min(2, dataStore.totalCostToday / dataStore.rollingDailyAverage))
    }

    private var cockpitPaceReadout: String {
        guard dataStore.rollingDailyAverage > 0 else { return "—" }
        return String(format: "%.2f×", cockpitPaceRatio)
    }

    /// Share of window spend sitting on the single largest provider.
    private var cockpitConcentration: Double {
        guard totalCostForTimeRange > 0, let leader = topProviderSummary else { return 0 }
        return max(0, min(1, leader.totalCost / totalCostForTimeRange))
    }

    // MARK: Alarms

    /// Quiet when nothing is wrong. A panel that shows a red dot on a healthy
    /// system teaches the operator to ignore red dots.
    private var cockpitAlarmPanel: some View {
        DashboardSection("Alarms", density: .compact) {
            CockpitAlarmPanel(alarms: cockpitAlarms)
        }
    }

    private var cockpitAlarms: [(title: String, detail: String, state: CockpitAlarmRow.State)] {
        var rows: [(title: String, detail: String, state: CockpitAlarmRow.State)] = []

        let concentration = cockpitConcentration
        rows.append((
            title: "Provider concentration",
            detail: topProviderSummary.map {
                "\($0.provider.displayName) carries \(Int((concentration * 100).rounded()))% of spend"
            } ?? "No provider spend in this window",
            state: concentration >= 0.8 ? .caution : .nominal
        ))

        let efficiency = cockpitCacheEfficiency
        if let hitRate = efficiency.hitRate {
            rows.append((
                title: "Cache efficiency",
                detail: "\(efficiency.formattedHitRate) of prompt tokens served from cache",
                state: hitRate < 0.2 ? .caution : .nominal
            ))
        } else {
            rows.append((
                title: "Cache efficiency",
                detail: "No cache signal in this window",
                state: .nominal
            ))
        }

        let estimated = dashboardProviderSummaries.filter(\.hasEstimatedData)
        rows.append((
            title: "Cost provenance",
            detail: estimated.isEmpty
                ? "Every provider reports exact cost"
                : "\(estimated.count) provider\(estimated.count == 1 ? "" : "s") reporting estimated cost",
            state: estimated.isEmpty ? .nominal : .caution
        ))

        rows.append((
            title: "Ingestion",
            detail: dataStore.lastRefresh.map { "Last refresh \($0.formatted(date: .omitted, time: .shortened))" }
                ?? "Never refreshed on this machine",
            state: dataStore.lastRefresh == nil ? .alarm : .nominal
        ))

        return rows
    }

    // MARK: Routing

    private var cockpitRoutingBand: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                cockpitRoutingStage.frame(maxWidth: .infinity)
                cockpitCurve.frame(maxWidth: .infinity)
            }
            VStack(spacing: DesignSystem.Spacing.md) {
                cockpitRoutingStage
                cockpitCurve
            }
        }
    }

    private var cockpitRoutingStage: some View {
        DashboardSection(
            "Live routing",
            title: "\(activeProviderCount) provider\(activeProviderCount == 1 ? "" : "s")",
            accent: DesignSystem.Colors.ember,
            density: .flush
        ) {
            SwarmRevealWindow {
                VStack(alignment: .leading) {
                    HStack {
                        SwarmFormingChip(label: "forming · boids")
                        Spacer()
                    }
                    Spacer()
                }
            }
            .frame(height: 168)
        }
    }

    private var cockpitCurve: some View {
        DashboardSection("Cumulative cost", accent: DesignSystem.Colors.whimsy, density: .flush) {
            liveCostCurveBand
                .frame(height: 168)
        }
    }

    // MARK: Detail ladder

    private var cockpitLadder: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                cockpitProviderLadder.frame(maxWidth: .infinity)
                cockpitModelLadder.frame(maxWidth: .infinity)
            }
            VStack(spacing: DesignSystem.Spacing.md) {
                cockpitProviderLadder
                cockpitModelLadder
            }
        }
    }

    private var cockpitProviderLadder: some View {
        DashboardSection("Providers", accent: DesignSystem.Colors.ember, density: .compact) {
            DashboardRankedTable(
                items: conceptProviderRows,
                emptyMessage: "No provider activity yet.",
                onSelect: { item in
                    guard let provider = item.provider else { return }
                    conceptOpenProvider(provider, lane: "cockpit_provider")
                }
            )
        }
    }

    private var cockpitModelLadder: some View {
        DashboardSection("Models", accent: DesignSystem.Colors.blaze, density: .compact) {
            DashboardRankedTable(
                items: conceptModelRows,
                limit: 8,
                emptyMessage: "No model activity yet."
            )
        }
    }
}
