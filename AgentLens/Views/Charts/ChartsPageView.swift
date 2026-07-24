import SwiftUI
import OpenBurnBarCore

// MARK: - Charts Page
//
// The full-page analytics gallery opened by tapping the command-deck burn
// chart. A hero band tells the story of the selected window; below it, a
// curated, re-arrangeable gallery of usage charts over the real token_usage
// data, with an opt-in AI insight strip driven by the user's
// already-connected LLM backends.
//
// Layout persistence: `ChartsPageLayout` JSON under its storage key.
// Appearance persistence: `ChartsAppearance` JSON under its storage key.
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

    @State private var service = ChartsDataService()
    @State private var insightEngine = ChartInsightEngine()
    @State private var layout: ChartsPageLayout = .default
    @State private var appearance: ChartsAppearance = .default
    @State private var isCustomizing = false
    @AppStorage(ChartsPageView.aiToggleKey) private var aiInsightsEnabled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let aiToggleKey = "chartsPage.llmInsightsEnabled"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                if let snapshot = service.snapshot,
                   snapshot.timeRange == selectedTimeRange {
                    if snapshot.isEmpty {
                        controlsRow
                        emptyState
                    } else {
                        ChartsHeroView(snapshot: snapshot, appearance: appearance) {
                            controlsRow
                        }

                        if aiInsightsEnabled {
                            ChartAIInsightCard(state: insightEngine.state) { kind in
                                withAnimation(reduceMotion ? nil : DesignSystem.Animation.gentle) {
                                    layout.setVisible(kind, true)
                                }
                            }
                        }

                        ChartsReorderableGrid(
                            layout: layout,
                            snapshot: snapshot,
                            appearance: appearance,
                            onMove: { dragged, target in
                                layout.move(dragged, toPositionOf: target)
                            },
                            onHide: { kind in
                                layout.setVisible(kind, false)
                            },
                            onToggleSpan: { kind in
                                let current = layout.configs.first { $0.kind == kind }?.span ?? 1
                                layout.setSpan(kind, current == appearance.columns ? 1 : appearance.columns)
                            }
                        )
                    }
                } else {
                    controlsRow
                    loadingState
                }
            }
            .padding(DesignSystem.Spacing.xl)
            .frame(maxWidth: appearance.columns >= 3 ? 1440 : 1180, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $isCustomizing) {
            ChartsCustomizeSheet(layout: $layout, appearance: $appearance)
        }
        .onAppear { restoreLayout() }
        .onChange(of: layout) { _, _ in persistLayout() }
        .onChange(of: appearance) { _, _ in persistAppearance() }
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

    // MARK: Controls

    /// Time range · AI insights · Customize. Floats on the hero's trailing
    /// edge when the gallery has data; stands alone above the loading and
    /// empty states.
    private var controlsRow: some View {
        HStack(alignment: .center, spacing: DesignSystem.Spacing.sm) {
            Spacer(minLength: 0)
            timeRangePicker
            aiToggle
            customizeButton
        }
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
                                Capsule().fill(appearance.paletteMood.color(for: .burn).opacity(0.2))
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
                Image(systemName: "sparkles")
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

    private var customizeButton: some View {
        Button {
            isCustomizing = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "paintpalette")
                    .font(.system(size: 11, weight: .semibold))
                Text("Customize")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(DesignSystem.Colors.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .liquidGlassInteractive(in: Capsule())
        .help("Palette mood, density, columns, metric, and per-chart visibility, width, and accent")
        .accessibilityLabel("Customize the gallery")
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
        VStack(spacing: DesignSystem.Spacing.lg) {
            ZStack {
                Circle()
                    .fill(appearance.paletteMood.color(for: .burn).opacity(0.12))
                    .frame(width: 110, height: 110)
                    .blur(radius: 30)
                Image(systemName: "chart.xyaxis.line")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(appearance.paletteMood.color(for: .burn).opacity(0.7))
            }
            VStack(spacing: 6) {
                Text("No usage in this window")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("Run an agent — or widen the lens — and the gallery draws itself from every request you make.")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            if let wider = widerRange {
                Button {
                    withAnimation(reduceMotion ? nil : DesignSystem.Animation.standard) {
                        selectedTimeRange = wider
                    }
                } label: {
                    Label("Widen to \(wider.displayName)", systemImage: "arrow.left.and.right")
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(appearance.paletteMood.color(for: .burn))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .liquidGlassInteractive(in: Capsule())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 100)
    }

    /// The next wider time range, for the empty state's one-tap escape.
    private var widerRange: TimeRange? {
        switch selectedTimeRange {
        case .today: return .last7Days
        case .last7Days: return .last30Days
        case .last30Days: return .thisMonth
        case .thisMonth: return .allTime
        case .allTime: return nil
        }
    }

    // MARK: Persistence

    private func restoreLayout() {
        if let data = UserDefaults.standard.data(forKey: ChartsPageLayout.storageKey) {
            layout = ChartsPageLayout.decode(from: data)
        }
        if let data = UserDefaults.standard.data(forKey: ChartsAppearance.storageKey) {
            appearance = ChartsAppearance.decode(from: data)
        }
    }

    private func persistLayout() {
        if let data = layout.encoded() {
            UserDefaults.standard.set(data, forKey: ChartsPageLayout.storageKey)
        }
    }

    private func persistAppearance() {
        if let data = appearance.encoded() {
            UserDefaults.standard.set(data, forKey: ChartsAppearance.storageKey)
        }
    }
}
