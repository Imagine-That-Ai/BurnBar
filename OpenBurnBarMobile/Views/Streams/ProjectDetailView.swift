import SwiftUI
import Charts
import OpenBurnBarCore

// MARK: - Project Detail View
//
// Drill-down for a single project: hero header with totals, daily chart,
// top models, and the underlying session list. All data sourced from
// `ProjectsStore` (no Firestore round-trip).

struct ProjectDetailView: View {
    enum ProjectDetailTab: String, CaseIterable, Identifiable {
        case wiki = "📖 Wiki Brief"
        case stats = "📊 Billing Stats"

        var id: String { rawValue }
    }

    let project: ProjectSummary
    let store: ProjectsStore

    @State private var selectedSession: TokenUsage?
    @State private var activeTab: ProjectDetailTab

    init(project: ProjectSummary, store: ProjectsStore, initialTab: ProjectDetailTab = .wiki) {
        self.project = project
        self.store = store
        self._selectedSession = State(initialValue: nil)
        self._activeTab = State(initialValue: initialTab)
    }

    private var providerColor: Color {
        project.dominantProvider.map { MobileTheme.Colors.primary(for: $0) } ?? MobileTheme.ember
    }

    var body: some View {
        ZStack {
            AuroraBackdrop(density: .subtle)
            ScrollView {
                VStack(spacing: MobileTheme.Spacing.lg) {
                    heroCard
                    statRow
                    tabSelector

                    if activeTab == .wiki {
                        MobileProjectMemoryWikiView(
                            project: project,
                            memory: projectMemorySnapshot,
                            store: store,
                            selectedSession: $selectedSession
                        )
                        .transition(AnyTransition.asymmetric(
                            insertion: AnyTransition.opacity.combined(with: AnyTransition.move(edge: .leading)),
                            removal: AnyTransition.opacity.combined(with: AnyTransition.move(edge: .trailing))
                        ))
                    } else {
                        VStack(spacing: MobileTheme.Spacing.lg) {
                            projectMemoryCard
                            if !project.dailyTokens.isEmpty {
                                chartCard
                            }
                            topModelsCard
                            sessionsCard
                        }
                        .transition(AnyTransition.asymmetric(
                            insertion: AnyTransition.opacity.combined(with: AnyTransition.move(edge: .trailing)),
                            removal: AnyTransition.opacity.combined(with: AnyTransition.move(edge: .leading))
                        ))
                    }
                }
                .padding(.horizontal, AuroraDesign.Layout.cardInset)
                .padding(.vertical, MobileTheme.Spacing.md)
                .padding(.bottom, MobileTheme.Spacing.xxl)
            }
        }
        .navigationTitle(project.projectName)
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationDestination(item: $selectedSession) { session in
            SessionDetailView(usage: session)
        }
    }

    private var tabSelector: some View {
        HStack(spacing: 0) {
            ForEach(ProjectDetailTab.allCases) { tab in
                Button {
                    HapticBus.send()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        activeTab = tab
                    }
                } label: {
                    Text(tab.rawValue)
                        .font(MobileTheme.Typography.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(activeTab == tab ? MobileTheme.Colors.textPrimary : MobileTheme.Colors.textMuted)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(activeTab == tab ? AnyShapeStyle(MobileTheme.Colors.surfaceElevated) : AnyShapeStyle(Color.clear))
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(MobileTheme.Colors.surface.opacity(0.8))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(MobileTheme.Colors.border.opacity(0.32), lineWidth: 0.6)
                )
        )
    }

    // MARK: - Hero

    private var heroCard: some View {
        AuroraGlassCard(variant: .hero, cornerRadius: AuroraDesign.Shape.heroCorner) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(providerColor.opacity(0.18))
                            .frame(width: 56, height: 56)
                        if #available(iOS 18.0, *) {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(providerColor)
                                .symbolEffect(.bounce, options: .repeating)
                        } else {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(providerColor)
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(project.projectName)
                            .font(MobileTheme.Typography.title)
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                            .lineLimit(2)
                        Text("Last seen \(project.lastSeen, style: .relative) ago")
                            .font(MobileTheme.Typography.tiny)
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                    }
                    Spacer()
                }
                RollingMetric(
                    label: "Project burn",
                    value: project.totalCost.formatAsCost(),
                    subtitle: "\(project.totalTokens.formatAsTokenVolume()) tokens · \(project.sessions) sessions",
                    trend: nil,
                    sparkline: project.sortedDailyPoints.map(\.value),
                    valueFont: AuroraDesign.Typography.displayHero
                )
            }
        }
    }

    // MARK: - Stats Row

    private var statRow: some View {
        HStack(spacing: 10) {
            StatPill(label: "Sessions", value: "\(project.sessions)")
            if let provider = project.dominantProvider {
                StatPill(label: "Top provider", value: provider.displayName)
            }
            if let model = project.topModel {
                StatPill(label: "Top model", value: model)
            }
        }
    }

    // MARK: - Project Memory

    private var projectMemorySnapshot: MobileProjectMemorySnapshot {
        MobileProjectMemorySnapshot.build(project: project, sessions: store.sessions(for: project))
    }

    private var projectMemoryCard: some View {
        let memory = projectMemorySnapshot
        return Button {
            HapticBus.send()
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                activeTab = .wiki
            }
        } label: {
            AuroraGlassCard(variant: .standard, cornerRadius: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        AuroraSection("Project memory", subtitle: memory.freshnessLabel, accent: MobileTheme.hermesAureate)
                        Spacer()
                        HStack(spacing: 4) {
                            Text("Open Wiki")
                                .font(MobileTheme.Typography.tiny)
                                .fontWeight(.semibold)
                                .foregroundStyle(MobileTheme.hermesAureate)
                            Image(systemName: "chevron.right")
                                .font(MobileTheme.Typography.caption)
                                .fontWeight(.bold)
                                .foregroundStyle(MobileTheme.hermesAureate)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(MobileTheme.hermesAureate.opacity(0.12))
                        )
                    }

                    Text(memory.summary)
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)

                    ForEach(memory.sections.prefix(2), id: \.title) { section in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(section.title)
                                .font(MobileTheme.Typography.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(MobileTheme.Colors.textPrimary)
                            Text(section.body)
                                .font(MobileTheme.Typography.tiny)
                                .foregroundStyle(MobileTheme.Colors.textMuted)
                                .lineLimit(3)
                                .multilineTextAlignment(.leading)
                            Text("\(section.citationCount) citation\(section.citationCount == 1 ? "" : "s")")
                                .font(MobileTheme.Typography.tiny)
                                .foregroundStyle(MobileTheme.hermesAureate)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        // Material, not glass: these rows sit inside the parent
                        // AuroraGlassCard's iOS 26 glass, and glass cannot
                        // sample other glass.
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(MobileTheme.Colors.border.opacity(0.32), lineWidth: 0.6)
                        )
                    }

                    if memory.visuals.isEmpty == false {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(memory.visuals, id: \.id) { visual in
                                    MobileProjectMemoryVisualCard(visual: visual)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Chart

    private var chartCard: some View {
        AuroraGlassCard(variant: .standard, cornerRadius: 18) {
            VStack(alignment: .leading, spacing: 8) {
                AuroraSection("Daily tokens", subtitle: "Last 14 days", accent: providerColor)
                Chart {
                    ForEach(project.sortedDailyPoints, id: \.date) { day, value in
                        AreaMark(
                            x: .value("Date", day, unit: .day),
                            y: .value("Tokens", value)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [providerColor.opacity(0.45), providerColor.opacity(0.05)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .interpolationMethod(.catmullRom)
                        LineMark(
                            x: .value("Date", day, unit: .day),
                            y: .value("Tokens", value)
                        )
                        .foregroundStyle(providerColor)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(.catmullRom)
                    }
                }
                .frame(height: 180)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: 3)) { _ in
                        AxisValueLabel(format: .dateTime.month().day())
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                    }
                }
            }
        }
    }

    // MARK: - Top Models

    private var topModelsCard: some View {
        AuroraGlassCard(variant: .standard) {
            VStack(alignment: .leading, spacing: 10) {
                AuroraSection("Top models", accent: MobileTheme.amber)
                ForEach(topModels, id: \.0) { model, tokens in
                    HStack {
                        Image(systemName: "cpu")
                            .foregroundStyle(MobileTheme.Colors.colorForModel(model))
                            .frame(width: 24)
                        Text(model)
                            .font(MobileTheme.Typography.body)
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                            .lineLimit(1)
                        Spacer()
                        Text(tokens.formatAsTokens())
                            .font(MobileTheme.Typography.caption)
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                    }
                }
                if topModels.isEmpty {
                    Text("No model data yet.")
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }
            }
        }
    }

    private var topModels: [(String, Int)] {
        let sessions = store.sessions(for: project)
        var bucket: [String: Int] = [:]
        for s in sessions { bucket[s.model, default: 0] += s.totalTokens }
        return bucket.sorted { $0.value > $1.value }.prefix(5).map { ($0.key, $0.value) }
    }

    // MARK: - Sessions

    private var sessionsCard: some View {
        let sessions = store.sessions(for: project).prefix(20)
        return AuroraGlassCard(variant: .standard) {
            VStack(alignment: .leading, spacing: 10) {
                AuroraSection("Sessions", subtitle: "\(store.sessions(for: project).count) total", accent: providerColor)
                if sessions.isEmpty {
                    Text("No sessions cached locally.")
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }
                ForEach(Array(sessions)) { session in
                    Button {
                        HapticBus.sheetOpen()
                        selectedSession = session
                    } label: {
                        sessionRow(session)
                    }
                    .buttonStyle(.plain)
                    Divider().opacity(0.4)
                }
            }
        }
    }

    private func sessionRow(_ session: TokenUsage) -> some View {
        HStack(spacing: 10) {
            if let provider = AgentProvider.fromPersistedToken(session.provider.rawValue) {
                ProviderAvatar(provider: provider, mode: .tile, size: 36)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(session.model)
                    .font(MobileTheme.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                    .lineLimit(1)
                Text(session.startTime, style: .relative)
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }
            Spacer()
            Text(session.cost.formatAsCost())
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Stat Pill

private struct StatPill: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(MobileTheme.Typography.caption)
                .fontWeight(.semibold)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label.uppercased())
                .font(MobileTheme.Typography.tiny)
                .tracking(1.2)
                .foregroundStyle(MobileTheme.Colors.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .liquidGlassSurface(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(MobileTheme.Colors.border.opacity(0.4), lineWidth: 0.5)
        )
    }
}

private struct MobileProjectMemoryVisualCard: View {
    let visual: MobileProjectMemoryVisual

    private var maxValue: Double {
        max(visual.points.map(\.value).max() ?? 1, 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(visual.title)
                .font(MobileTheme.Typography.caption)
                .fontWeight(.semibold)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
            Text(visual.subtitle)
                .font(MobileTheme.Typography.tiny)
                .foregroundStyle(MobileTheme.Colors.textMuted)

            ForEach(Array(visual.points.prefix(4).enumerated()), id: \.offset) { _, point in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(point.label)
                            .font(MobileTheme.Typography.tiny)
                            .foregroundStyle(MobileTheme.Colors.textSecondary)
                            .lineLimit(1)
                        Spacer()
                        Text(point.display)
                            .font(MobileTheme.Typography.monoTiny)
                            .foregroundStyle(MobileTheme.hermesAureate)
                    }
                    Capsule()
                        .fill(MobileTheme.hermesAureate.opacity(0.82))
                        .frame(width: CGFloat(max(0.12, point.value / maxValue)) * 116, height: 4)
                }
            }
        }
        .padding(10)
        .frame(width: 186, alignment: .leading)
        // Material, not glass: this card renders inside projectMemoryCard's
        // AuroraGlassCard iOS 26 glass, and glass cannot sample other glass.
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(MobileTheme.Colors.border.opacity(0.34), lineWidth: 0.6)
        )
    }
}
