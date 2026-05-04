import SwiftUI
import Charts
import OpenBurnBarCore

// MARK: - Project Detail View
//
// Drill-down for a single project: hero header with totals, daily chart,
// top models, and the underlying session list. All data sourced from
// `ProjectsStore` (no Firestore round-trip).

struct ProjectDetailView: View {
    let project: ProjectSummary
    let store: ProjectsStore

    @State private var selectedSession: TokenUsage?

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
                    if !project.dailyTokens.isEmpty {
                        chartCard
                    }
                    topModelsCard
                    sessionsCard
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

    // MARK: - Hero

    private var heroCard: some View {
        AuroraGlassCard(variant: .hero, cornerRadius: AuroraDesign.Shape.heroCorner) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(providerColor.opacity(0.18))
                            .frame(width: 56, height: 56)
                        Image(systemName: "folder.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(providerColor)
                            .symbolEffect(.bounce, options: .repeating)
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
                ProviderAvatar(provider: provider, mode: .tile, size: 28)
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
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(MobileTheme.Colors.border.opacity(0.4), lineWidth: 0.5)
                )
        )
    }
}
