import SwiftUI
import OpenBurnBarCore

// MARK: - Trend Atlas Card
//
// Replaces `TrendSparkCard`. Three rotating scenes: Spend (provider stream
// graph + hour-of-day heat strip), Models (lane racer), Cache (constellation
// scatter). Tap anywhere → opens Chart Studio. Long press → context menu.
// Drag horizontally → swipes between scenes.

struct TrendAtlasCard: View {

    let dailyPoints: [RollupDailyPoint]
    let displayMode: UsageDisplayMode
    let windowTotals: [RollupWindowKey: RollupTotals]
    let providerSummaries: [RollupProviderSummary]
    let modelSummaries: [RollupModelSummary]
    let deviceSummaries: [RollupDeviceSummary]
    let recentUsages: [TokenUsage]
    let hermesService: HermesService

    @State private var scene: AtlasScene = .spend
    @State private var showingStudio: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.chartStudioPresenter) private var presenter

    enum AtlasScene: String, Hashable, CaseIterable, Identifiable {
        case spend, models, cache
        var id: String { rawValue }
        var label: String {
            switch self {
            case .spend:  return "Spend"
            case .models: return "Models"
            case .cache:  return "Cache"
            }
        }
        var icon: String {
            switch self {
            case .spend:  return "flame.fill"
            case .models: return "cpu"
            case .cache:  return "internaldrive.fill"
            }
        }
    }

    // MARK: - Digest

    private var digest: TrendDataDigest {
        TrendDataDigest.build(
            windowTotals: windowTotals,
            providerSummaries: providerSummaries,
            modelSummaries: modelSummaries,
            deviceSummaries: deviceSummaries,
            dailyPoints: dailyPoints,
            recentUsages: recentUsages,
            displayMode: displayMode
        )
    }

    private var insights: [TrendInsight] {
        TrendInsightEngine.insights(from: digest)
    }

    // MARK: - Body

    var body: some View {
        AuroraGlassCard(variant: .hero, cornerRadius: AuroraDesign.Shape.heroCorner, interactive: true) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
                header
                sceneSelector
                sceneContent
                    .frame(minHeight: 200)
                    .id(scene)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    .animation(reduceMotion ? nil : AuroraDesign.Motion.auroraSnap, value: scene)
                InsightAutoRotator(insights: insights, isPaused: showingStudio)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: AuroraDesign.Shape.heroCorner, style: .continuous))
        .onTapGesture { openStudio() }
        .gesture(
            DragGesture(minimumDistance: 32)
                .onEnded { value in
                    let dx = value.translation.width
                    if abs(dx) < 28 { return }
                    cycleScene(forward: dx < 0)
                }
        )
        .contextMenu {
            Button {
                openStudio()
            } label: {
                Label("Open Chart Studio", systemImage: "wand.and.stars")
            }
            ForEach(AtlasScene.allCases) { s in
                Button {
                    withAnimation(AuroraDesign.Motion.auroraSnap) { scene = s }
                } label: {
                    Label(s.label, systemImage: s.icon)
                }
            }
        }
        .fullScreenCover(isPresented: $showingStudio) {
            // Fallback presentation when no global presenter is wired (e.g.
            // previews / standalone snapshots). Production paths route
            // through `RootTabView`'s presenter so Studio can be minimized.
            ChartStudioView(
                digest: digest,
                hermesService: hermesService,
                onClose: { showingStudio = false }
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityHint("Double-tap to open Chart Studio.")
    }

    // MARK: - Header

    private var header: some View {
        AuroraSection(
            "Trend Atlas",
            subtitle: subtitleText,
            accent: MobileTheme.amber
        ) {
            Button {
                openStudio()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 11, weight: .bold))
                    Text("Studio")
                        .font(MobileTheme.Typography.tiny)
                        .fontWeight(.semibold)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .bold))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .foregroundStyle(MobileTheme.hermesAureate)
                .background(
                    Capsule()
                        .fill(MobileTheme.hermesAureate.opacity(0.14))
                )
                .overlay(
                    Capsule()
                        .stroke(MobileTheme.hermesAureate.opacity(0.4), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var subtitleText: String {
        switch scene {
        case .spend:
            return displayMode == .currency
                ? "Daily spend · stacked by provider"
                : "Daily token volume · stacked by provider"
        case .models:
            return "Top models · share, velocity, rank"
        case .cache:
            return "Sessions · duration vs cache hit rate"
        }
    }

    // MARK: - Scene Selector

    private var sceneSelector: some View {
        HStack(spacing: 4) {
            ForEach(AtlasScene.allCases) { s in
                Button {
                    HapticBus.chipChange()
                    withAnimation(AuroraDesign.Motion.auroraSnap) { scene = s }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: s.icon)
                            .font(.system(size: 10, weight: .bold))
                        Text(s.label)
                            .font(MobileTheme.Typography.tiny)
                            .fontWeight(.semibold)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .foregroundStyle(scene == s ? .white : MobileTheme.Colors.textMuted)
                    .background(
                        Capsule()
                            .fill(scene == s
                                  ? AnyShapeStyle(MobileTheme.primaryGradient)
                                  : AnyShapeStyle(.clear))
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(s.label) scene")
            }
        }
        .padding(3)
        .background(
            Capsule().fill(MobileTheme.Colors.surface.opacity(0.55))
        )
        .overlay(
            Capsule().stroke(MobileTheme.Colors.borderSubtle.opacity(0.6), lineWidth: 0.5)
        )
    }

    // MARK: - Scene Content

    @ViewBuilder
    private var sceneContent: some View {
        switch scene {
        case .spend:
            StreamGraphScene(digest: digest, displayMode: displayMode)
        case .models:
            ModelLaneScene(digest: digest, displayMode: displayMode)
        case .cache:
            CacheConstellationScene(digest: digest)
        }
    }

    // MARK: - Actions

    private func cycleScene(forward: Bool) {
        let all = AtlasScene.allCases
        guard let i = all.firstIndex(of: scene) else { return }
        let next = forward ? (i + 1) % all.count : (i - 1 + all.count) % all.count
        HapticBus.chipChange()
        withAnimation(AuroraDesign.Motion.auroraSnap) {
            scene = all[next]
        }
    }

    private func openStudio() {
        HapticBus.sheetOpen()
        if let presenter {
            presenter.present(digest: digest)
        } else {
            showingStudio = true
        }
    }
}
