import SwiftUI

struct ProjectRow: Identifiable {
    let id: String
    let projectName: String
    let totalCost: Double
    let totalTokens: Int
    let sessionCount: Int
    let providers: [AgentProvider]
}

struct ProjectsView: View {
    let dataStore: DataStore

    @Bindable private var settingsManager = SettingsManager.shared

    private var projectRows: [ProjectRow] {
        var byProject: [String: (cost: Double, tokens: Int, count: Int, providers: Set<AgentProvider>)] = [:]
        for usage in dataStore.usages {
            let key = usage.projectName
            let existing = byProject[key] ?? (0, 0, 0, [])
            byProject[key] = (
                existing.cost + usage.cost,
                existing.tokens + usage.totalTokens,
                existing.count + 1,
                existing.providers.union([usage.provider])
            )
        }
        return byProject.map { key, val in
            ProjectRow(
                id: key,
                projectName: key,
                totalCost: val.cost,
                totalTokens: val.tokens,
                sessionCount: val.count,
                providers: Array(val.providers).sorted { $0.rawValue < $1.rawValue }
            )
        }.sorted { $0.totalCost > $1.totalCost }
    }

    var body: some View {
        List(projectRows) { row in
            HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    Text(row.projectName)
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .lineLimit(2)
                    Text("\(row.sessionCount) session\(row.sessionCount == 1 ? "" : "s")")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: DesignSystem.Spacing.xs) {
                    Text(settingsManager.formatUsageMetric(cost: row.totalCost, tokens: row.totalTokens))
                        .font(DesignSystem.Typography.mono)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    HStack(spacing: DesignSystem.Spacing.xs) {
                        ForEach(row.providers, id: \.self) { p in
                            ProviderLogoView(provider: p, size: 16, useFallbackColor: false)
                        }
                    }
                }
            }
            .padding(.vertical, DesignSystem.Spacing.xs)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(DesignSystem.Colors.background)
    }
}
