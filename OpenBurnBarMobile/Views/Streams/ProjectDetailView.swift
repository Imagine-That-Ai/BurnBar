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
                    projectMemoryCard
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

    // MARK: - Project Memory

    private var projectMemorySnapshot: MobileProjectMemorySnapshot {
        MobileProjectMemorySnapshot.build(project: project, sessions: store.sessions(for: project))
    }

    private var projectMemoryCard: some View {
        let memory = projectMemorySnapshot
        return AuroraGlassCard(variant: .standard, cornerRadius: 18) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    AuroraSection("Project memory", subtitle: memory.freshnessLabel, accent: MobileTheme.hermesAureate)
                    Spacer()
                    Text(memory.generatedAt, style: .relative)
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }

                Text(memory.summary)
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

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
                        Text("\(section.citationCount) citation\(section.citationCount == 1 ? "" : "s")")
                            .font(MobileTheme.Typography.tiny)
                            .foregroundStyle(MobileTheme.hermesAureate)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(.ultraThinMaterial)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(MobileTheme.Colors.border.opacity(0.32), lineWidth: 0.6)
                            )
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

private struct MobileProjectMemorySnapshot {
    let summary: String
    let sections: [MobileProjectMemorySection]
    let visuals: [MobileProjectMemoryVisual]
    let freshnessLabel: String
    let generatedAt: Date

    static func build(project: ProjectSummary, sessions: [TokenUsage], now: Date = Date()) -> MobileProjectMemorySnapshot {
        let summary = "\(project.sessions) sessions · \(project.totalTokens.formatAsTokenVolume()) tokens · \(project.totalCost.formatAsCost())"

        let recentLines = sessions.prefix(5).map {
            "\($0.model) · \($0.cost.formatAsCost()) · \($0.startTime.formatted(date: .abbreviated, time: .shortened))"
        }
        let recentBody = recentLines.isEmpty ? "No sessions cached locally." : recentLines.joined(separator: "\n")

        var modelTokenBuckets: [String: Int] = [:]
        sessions.forEach { modelTokenBuckets[$0.model, default: 0] += $0.totalTokens }
        let topModels = modelTokenBuckets.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.key < rhs.key
        }
        let modelBody = topModels.prefix(5).enumerated().map { idx, entry in
            "\(idx + 1). \(entry.key) · \(entry.value.formatAsTokenVolume())"
        }.joined(separator: "\n")

        let avgCost = sessions.isEmpty ? 0 : sessions.reduce(0) { $0 + $1.cost } / Double(max(sessions.count, 1))
        let highCost = sessions.filter { $0.cost > max(avgCost * 1.8, 0.01) }.prefix(4)
        let riskBody: String
        if highCost.isEmpty {
            riskBody = "No unusual cost spikes detected in cached sessions."
        } else {
            riskBody = highCost.map { "\($0.model) spiked to \($0.cost.formatAsCost()) on \($0.startTime.formatted(date: .abbreviated, time: .shortened))." }
                .joined(separator: "\n")
        }

        var providerCostBuckets: [String: Double] = [:]
        sessions.forEach { providerCostBuckets[$0.provider.displayName, default: 0] += $0.cost }
        let providerVisual = MobileProjectMemoryVisual(
            id: "provider-mix",
            title: "Provider mix",
            subtitle: "Spend by provider",
            points: providerCostBuckets
                .sorted { lhs, rhs in
                    if lhs.value != rhs.value { return lhs.value > rhs.value }
                    return lhs.key < rhs.key
                }
                .prefix(5)
                .map { MobileProjectMemoryPoint(label: $0.key, value: $0.value, display: $0.value.formatAsCost()) }
        )

        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "MMM d"
        let timelineVisual = MobileProjectMemoryVisual(
            id: "timeline",
            title: "Timeline",
            subtitle: "Recent daily tokens",
            points: project.sortedDailyPoints.suffix(8).map {
                MobileProjectMemoryPoint(
                    label: dayFormatter.string(from: $0.date),
                    value: $0.value,
                    display: Int($0.value).formatAsTokenVolume()
                )
            }
        )

        let modelVisual = MobileProjectMemoryVisual(
            id: "model-hotspots",
            title: "Model hotspots",
            subtitle: "Top token models",
            points: topModels.prefix(5).map {
                MobileProjectMemoryPoint(label: $0.key, value: Double($0.value), display: $0.value.formatAsTokenVolume())
            }
        )

        let freshnessLabel: String
        let age = now.timeIntervalSince(project.lastSeen)
        if age <= 6 * 3600 {
            freshnessLabel = "Fresh"
        } else if age <= 48 * 3600 {
            freshnessLabel = "Needs refresh"
        } else {
            freshnessLabel = "Stale"
        }

        return MobileProjectMemorySnapshot(
            summary: summary,
            sections: [
                MobileProjectMemorySection(title: "Recent agent work", body: recentBody, citationCount: min(recentLines.count, 5)),
                MobileProjectMemorySection(title: "Model decisions", body: modelBody.isEmpty ? "No model evidence yet." : modelBody, citationCount: min(topModels.count, 5)),
                MobileProjectMemorySection(title: "Open risks", body: riskBody, citationCount: Int(highCost.count))
            ],
            visuals: [providerVisual, timelineVisual, modelVisual].filter { $0.points.isEmpty == false },
            freshnessLabel: freshnessLabel,
            generatedAt: now
        )
    }
}

private struct MobileProjectMemorySection {
    let title: String
    let body: String
    let citationCount: Int
}

private struct MobileProjectMemoryVisual: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let points: [MobileProjectMemoryPoint]
}

private struct MobileProjectMemoryPoint {
    let label: String
    let value: Double
    let display: String
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
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(MobileTheme.Colors.border.opacity(0.34), lineWidth: 0.6)
                )
        )
    }
}
