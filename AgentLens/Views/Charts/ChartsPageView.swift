import SwiftUI
import OpenBurnBarCore

// MARK: - Charts Page
//
// The full-page analytics atelier opened by tapping the command-deck burn
// chart. A curated, re-arrangeable gallery of usage charts over the real
// token_usage data, with an opt-in AI insight strip driven by the user's
// already-connected LLM backends.
//
// Layout persistence: `ChartsPageLayout` JSON under its storage key.
// AI assist: `chartsPage.llmInsightsEnabled` — aggregate numbers only,
// local-first (Hermes gateway before any cloud CLI).

/// Host for the parallel `DashboardDetailView` surface, which passes the time
/// range by value. Keeps the page's binding-based API intact.
struct ChartsPageDetailHost: View {
    let context: DashboardContext
    let selectedTimeRange: TimeRange

    @State private var timeRange: TimeRange = .today

    var body: some View {
        ChartsPageView(
            dataStore: context.dataStore,
            settingsManager: context.settingsManager,
            chatController: context.chatController,
            selectedTimeRange: $timeRange
        )
        .onAppear { timeRange = selectedTimeRange }
    }
}

struct ChartsPageView: View {
    @Bindable var dataStore: DataStore
    @Bindable var settingsManager: SettingsManager
    let chatController: ChatSessionController
    @Binding var selectedTimeRange: TimeRange
    /// Threaded from the dashboard so receipt rows can open session logs.
    var onOpenSessionLog: ((String) -> Void)?

    @State private var service = ChartsDataService()
    @State private var insightEngine = ChartInsightEngine()
    @State private var layout: ChartsPageLayout = .default
    @AppStorage(ChartsPageView.aiToggleKey) private var aiInsightsEnabled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let aiToggleKey = "chartsPage.llmInsightsEnabled"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                header

                if let snapshot = service.snapshot,
                   snapshot.timeRange == selectedTimeRange {
                    if snapshot.isEmpty {
                        emptyState
                    } else {
                        if aiInsightsEnabled {
                            ChartAIInsightCard(state: insightEngine.state) { kind in
                                withAnimation(reduceMotion ? nil : DesignSystem.Animation.gentle) {
                                    layout.setVisible(kind, true)
                                    persistLayout()
                                }
                            }
                        }

                        ChartsReorderableGrid(
                            layout: layout,
                            snapshot: snapshot,
                            onMove: { dragged, target in
                                layout.move(dragged, toPositionOf: target)
                                persistLayout()
                            },
                            onHide: { kind in
                                layout.setVisible(kind, false)
                                persistLayout()
                            },
                            onToggleSpan: { kind in
                                let current = layout.configs.first { $0.kind == kind }?.span ?? 1
                                layout.setSpan(kind, current == 2 ? 1 : 2)
                                persistLayout()
                            }
                        )

                        // The Receipt: conversations × usage join — problems
                        // solved more than once and what the repeats cost.
                        // Not a ChartKind (it draws no chart), so it sits as
                        // its own card section under the gallery.
                        ReceiptCardView(dataStore: dataStore, timeRange: selectedTimeRange, onOpenConversation: onOpenSessionLog)
                    }
                } else {
                    loadingState
                }
            }
            .padding(DesignSystem.Spacing.xl)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { restoreLayout() }
        .task(id: refreshKey) {
            service.refresh(dataStore: dataStore, timeRange: selectedTimeRange)
        }
        .task(id: insightKey) {
            guard aiInsightsEnabled,
                  let snapshot = service.snapshot,
                  snapshot.timeRange == selectedTimeRange,
                  !snapshot.isEmpty else { return }
            insightEngine.generateIfNeeded(
                snapshot: snapshot,
                bridge: chatController.cliBridge,
                enabledBackends: settingsManager.enabledChatBackends
            )
        }
        .accessibilityIdentifier(OBBAccessibilityID.chartsPage)
    }

    private var refreshKey: String {
        "\(selectedTimeRange.rawValue)|\(dataStore.usagesVersion)"
    }

    private var insightKey: String {
        let version = service.snapshot?.usagesVersion ?? -1
        let snapshotRange = service.snapshot?.timeRange.rawValue ?? "none"
        let backends = settingsManager.enabledChatBackends.map(\.rawValue).sorted().joined(separator: ",")
        return "\(aiInsightsEnabled)|\(version)|\(selectedTimeRange.rawValue)|\(snapshotRange)|\(backends)"
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: DesignSystem.Spacing.md) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Charts")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(headerSubtitle)
                    .font(.system(size: 11.5, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }

            Spacer()

            timeRangePicker
            aiToggle
            editMenu
        }
    }

    private var headerSubtitle: String {
        guard let snapshot = service.snapshot, !snapshot.isEmpty else {
            return "Your usage, drawn honestly."
        }
        return "\(snapshot.totalCost.formatAsCost()) · "
            + "\(snapshot.totalTokens.formatAsTokenVolume()) tokens · "
            + "\(snapshot.sessionCount) sessions"
    }

    private var timeRangePicker: some View {
        HStack(spacing: 2) {
            ForEach(TimeRange.allCases) { range in
                let selected = selectedTimeRange == range
                Button {
                    withAnimation(reduceMotion ? nil : DesignSystem.Animation.standard) {
                        selectedTimeRange = range
                    }
                    Analytics.shared.track(.dashboardTimeRangeChanged, ["time_range": .string(range.rawValue)])
                } label: {
                    Text(range.compactLabel)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .tracking(0.6)
                        .foregroundStyle(
                            selected ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textMuted
                        )
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background {
                            if selected {
                                Capsule().fill(DesignSystem.Colors.ember.opacity(0.2))
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .liquidGlassSurface(in: Capsule())
    }

    /// The obvious-but-elegant AI switch: a glass capsule that lights up when
    /// insights are flowing.
    private var aiToggle: some View {
        Button {
            withAnimation(reduceMotion ? nil : DesignSystem.Animation.standard) {
                aiInsightsEnabled.toggle()
            }
            if !aiInsightsEnabled { insightEngine.cancel() }
            Analytics.shared.track(.settingsChanged, [
                "setting_key": "charts_ai_insights",
                "new_value": .string(String(aiInsightsEnabled)),
                "source": "charts_page"
            ])
        } label: {
            HStack(spacing: 6) {
                Image(systemName: aiInsightsEnabled ? "sparkles" : "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .symbolEffect(.bounce, value: aiInsightsEnabled)
                Text("AI Insights")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                Circle()
                    .fill(aiInsightsEnabled ? DesignSystem.Colors.success : DesignSystem.Colors.textMuted.opacity(0.5))
                    .frame(width: 5, height: 5)
            }
            .foregroundStyle(
                aiInsightsEnabled ? DesignSystem.Colors.whimsy : DesignSystem.Colors.textSecondary
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .liquidGlassInteractive(
            tint: aiInsightsEnabled ? DesignSystem.Colors.whimsy.opacity(0.4) : nil,
            in: Capsule()
        )
        .help(
            aiInsightsEnabled
                ? "AI insights on — aggregate numbers only are shared with your connected LLM"
                : "Turn on AI insights: your connected LLM reads aggregate spend numbers (never conversation content) and surfaces what matters"
        )
        .accessibilityLabel("AI Insights")
        .accessibilityValue(aiInsightsEnabled ? "On" : "Off")
        .accessibilityIdentifier(OBBAccessibilityID.chartsAIToggle)
    }

    private var editMenu: some View {
        Menu {
            if !layout.hiddenConfigs.isEmpty {
                Section("Hidden Charts") {
                    ForEach(layout.hiddenConfigs) { config in
                        Button {
                            layout.setVisible(config.kind, true)
                            persistLayout()
                        } label: {
                            Label(config.kind.title, systemImage: config.kind.systemImage)
                        }
                    }
                }
            }
            Section {
                Button("Reset Layout") {
                    withAnimation(reduceMotion ? nil : DesignSystem.Animation.gentle) {
                        layout.reset()
                        persistLayout()
                    }
                }
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .liquidGlassInteractive(in: Circle())
        .help("Show hidden charts or reset the layout")
        .accessibilityLabel("Edit charts")
    }

    // MARK: States

    private var loadingState: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            ProgressView()
                .controlSize(.small)
            Text("Preparing your charts…")
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 120)
    }

    private var emptyState: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(DesignSystem.Colors.ember.opacity(0.6))
            Text("No usage in this window")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(DesignSystem.Colors.textPrimary)
            Text("Run an agent or widen the time range — the gallery draws itself from every request you make.")
                .font(.system(size: 11.5, design: .rounded))
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 100)
    }

    // MARK: Layout persistence

    private func restoreLayout() {
        if let data = UserDefaults.standard.data(forKey: ChartsPageLayout.storageKey) {
            layout = ChartsPageLayout.decode(from: data)
        }
    }

    private func persistLayout() {
        if let data = layout.encoded() {
            UserDefaults.standard.set(data, forKey: ChartsPageLayout.storageKey)
        }
    }
}
