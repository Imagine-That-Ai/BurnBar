import SwiftUI
import OpenBurnBarCore

// MARK: - Project Spend Lane

/// "Spend by Project" lane that slices `token_usage` by `projectName`.
///
/// Answers "where did the money go on this project?" — the dimension the existing Provider
/// and Model lanes collapse. Spend is grouped on the free-text `projectName` column already
/// populated by every log parser; this view surfaces those rollups as a ranked ledger so
/// enterprise teams can attribute spend to deliverables.
struct DashboardProjectSpendLaneView: View {
    var summaries: [ProjectSpendSummary]
    var overviewAppeared: Bool = true
    var onNavigateToProject: (ProjectSpendSummary) -> Void = { _ in }

    var body: some View {
        UnifiedGlassCard {
            VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.lg) {
                header

                if summaries.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: UnifiedDesignSystem.Spacing.sm) {
                        ForEach(Array(summaries.prefix(8).enumerated()), id: \.element.id) { index, summary in
                            ProjectSpendCard(summary: summary, rank: index + 1) {
                                withAnimation(UnifiedDesignSystem.Animation.standard) {
                                    onNavigateToProject(summary)
                                }
                            }
                            .opacity(overviewAppeared ? 1 : 0)
                            .offset(y: overviewAppeared ? 0 : 8)
                            .animation(
                                UnifiedDesignSystem.Animation.standard.delay(Double(index) * 0.06),
                                value: overviewAppeared
                            )
                        }
                    }
                }
            }
            .padding(UnifiedDesignSystem.Spacing.lg)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .opacity(overviewAppeared ? 1 : 0)
        .offset(y: overviewAppeared ? 0 : 8)
        .animation(UnifiedDesignSystem.Animation.standard.delay(0.32), value: overviewAppeared)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.xs) {
                Text("Project Ranking")
                    .font(UnifiedDesignSystem.Typography.headline)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)

                Text("Spend grouped by project. Cap a project's burn with a budget rule.")
                    .font(UnifiedDesignSystem.Typography.caption)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
            }

            Spacer()
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.sm) {
            Text("No project spend recorded yet.")
                .font(UnifiedDesignSystem.Typography.body)
                .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)

            Text("Project names come from parsed agent session logs — once any agent runs in a project folder, the project will appear here ranked by spend.")
                .font(UnifiedDesignSystem.Typography.caption)
                .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
        }
        .padding(.vertical, UnifiedDesignSystem.Spacing.md)
    }
}

// MARK: - Project Spend Card

/// Per-project summary card. Provider + model chips show the contributing mix at a glance.
struct ProjectSpendCard: View {
    let summary: ProjectSpendSummary
    let rank: Int
    let onTap: () -> Void

    @Environment(SettingsManager.self) private var settingsManager
    @State private var isHovered: Bool = false

    var body: some View {
        UnifiedGlassCard(interactive: true) {
            HStack(alignment: .top, spacing: UnifiedDesignSystem.Spacing.lg) {
                identityColumn
                detailColumn
                Spacer(minLength: 0)
                metricColumn
            }
            .padding(.vertical, UnifiedDesignSystem.Spacing.sm)
            .padding(.horizontal, UnifiedDesignSystem.Spacing.sm)
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(perform: onTap)
    }

    // MARK: Identity column (rank + folder glyph)

    private var identityColumn: some View {
        VStack(spacing: UnifiedDesignSystem.Spacing.xs) {
            rankPill
            ZStack {
                Circle()
                    .fill(UnifiedDesignSystem.Colors.surfaceElevated.opacity(0.6))
                    .frame(width: 40, height: 40)
                Image(systemName: "folder.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(UnifiedDesignSystem.Colors.accent)
            }
        }
        .frame(width: 56)
    }

    private var rankPill: some View {
        Text(String(format: "%02d", rank))
            .font(.system(size: 10, weight: .heavy, design: .monospaced))
            .tracking(1.0)
            .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(UnifiedDesignSystem.Colors.surfaceElevated.opacity(0.55))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(UnifiedDesignSystem.Colors.border.opacity(0.32), lineWidth: 0.5)
            )
    }

    // MARK: Detail column (name, providers, top models)

    private var detailColumn: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.xs) {
            Text(summary.projectName)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: UnifiedDesignSystem.Spacing.sm) {
                ForEach(summary.providerBreakdown.prefix(3), id: \.id) { entry in
                    providerChip(for: entry)
                }
                sessionsChip
            }

            if !summary.modelBreakdown.isEmpty {
                Text(topModelsLine)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func providerChip(for entry: ProviderUsage) -> some View {
        HStack(spacing: 4) {
            UnifiedProviderLogoView(provider: entry.provider, size: 12, useFallbackColor: false)
            Text(entry.provider.displayName)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .lineLimit(1)
        }
        .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(UnifiedDesignSystem.Colors.surfaceElevated.opacity(0.45)))
        .overlay(Capsule().stroke(UnifiedDesignSystem.Colors.border.opacity(0.28), lineWidth: 0.5))
    }

    private var sessionsChip: some View {
        HStack(spacing: 4) {
            Image(systemName: "rectangle.stack.fill")
                .font(.system(size: 8, weight: .semibold))
            Text("\(summary.sessionCount)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
        }
        .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(UnifiedDesignSystem.Colors.surfaceElevated.opacity(0.45)))
        .overlay(Capsule().stroke(UnifiedDesignSystem.Colors.border.opacity(0.28), lineWidth: 0.5))
    }

    private var topModelsLine: String {
        let models = summary.modelBreakdown.prefix(3).map { model in
            "\(TokenExtractionUtility.displayNameForModel(model.modelName)) \(model.cost.formatAsCost())"
        }
        return models.joined(separator: " · ")
    }

    // MARK: Metric column

    private var metricColumn: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(primaryMetric)
                .font(.system(size: 22, weight: .bold, design: .monospaced))
                .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .allowsTightening(true)

            Text(secondaryMetric)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)

            if summary.hasEstimatedData {
                Text("ESTIMATED")
                    .font(.system(size: 8, weight: .heavy, design: .rounded))
                    .tracking(1.0)
                    .foregroundStyle(UnifiedDesignSystem.Colors.warning)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(UnifiedDesignSystem.Colors.warning.opacity(0.12)))
                    .overlay(Capsule().stroke(UnifiedDesignSystem.Colors.warning.opacity(0.32), lineWidth: 0.5))
            }
        }
        .frame(minWidth: 96, alignment: .trailing)
    }

    private var primaryMetric: String {
        settingsManager.formatUsageMetric(cost: summary.totalCost, tokens: summary.totalTokens)
    }

    private var secondaryMetric: String {
        switch settingsManager.usageDisplayMode {
        case .currency:
            return "\(ProjectSpendCard.formatTokens(summary.totalTokens)) tok"
        case .tokens:
            return summary.totalCost.formatAsCost()
        }
    }

    fileprivate static func formatTokens(_ tokens: Int) -> String {
        if tokens >= 1_000_000_000 {
            return String(format: "%.2fB", Double(tokens) / 1_000_000_000)
        } else if tokens >= 1_000_000 {
            return String(format: "%.1fM", Double(tokens) / 1_000_000)
        } else if tokens >= 1_000 {
            return String(format: "%.1fK", Double(tokens) / 1_000)
        }
        return "\(tokens)"
    }
}
