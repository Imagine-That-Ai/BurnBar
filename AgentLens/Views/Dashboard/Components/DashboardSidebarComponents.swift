import AppKit
import SwiftUI
import WebKit
struct SidebarItem: View {
    let provider: AgentProvider?
    let isSelected: Bool
    let primaryMetric: String
    let totalCost: Double
    let sessionCount: Int
    let action: () -> Void

    @State private var hovering = false

    private var theme: ProviderTheme {
        provider.map { ProviderTheme.theme(for: $0) } ?? ProviderTheme.theme(for: .factory)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: DesignSystem.Spacing.md) {
                ZStack {
                    Circle()
                        .fill(isSelected ? theme.primaryColor.opacity(0.18) : DesignSystem.Colors.surfaceElevated)
                        .frame(width: 34, height: 34)

                    if let provider {
                        ProviderLogoView(provider: provider, size: 22, useFallbackColor: false)
                    } else {
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(isSelected ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textSecondary)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(provider?.displayName ?? "All Providers")
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(isSelected ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textSecondary)
                        .lineLimit(1)

                    Text("\(sessionCount) session\(sessionCount == 1 ? "" : "s")")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
                .layoutPriority(1)

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    if provider?.supportLevel == .unsupported && totalCost == 0 {
                        Text("Not tracked")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                    } else {
                        Text(primaryMetric)
                            .font(DesignSystem.Typography.monoSmall)
                            .foregroundStyle(isSelected ? theme.primaryColor : DesignSystem.Colors.textMuted)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .allowsTightening(true)
                    }

                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(isSelected ? theme.primaryColor.opacity(0.8) : DesignSystem.Colors.textMuted)
                }
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md)
                    .fill(isSelected ? theme.primaryColor.opacity(0.08) : DesignSystem.Colors.surfaceElevated.opacity(hovering && !isSelected ? 0.55 : 0.35))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md)
                    .stroke(isSelected ? theme.primaryColor.opacity(0.3) : DesignSystem.Colors.border.opacity(0.35), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(DesignSystem.Animation.hover, value: hovering)
    }
}

// MARK: - Model Sidebar Item

struct ModelSidebarItem: View {
    let summary: ModelSummary
    let isSelected: Bool
    let action: () -> Void

    @Environment(SettingsManager.self) private var settingsManager

    @State private var hovering = false

    private var theme: ProviderTheme { ProviderTheme.theme(forModel: summary.modelName) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: DesignSystem.Spacing.md) {
                ZStack {
                    Circle()
                        .fill(isSelected ? theme.primaryColor.opacity(0.18) : DesignSystem.Colors.surfaceElevated)
                        .frame(width: 34, height: 34)

                    ModelProviderLogoView(
                        modelKey: summary.modelName,
                        size: 22,
                        fallbackSymbolColor: isSelected ? theme.primaryColor : DesignSystem.Colors.textSecondary
                    )
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.displayName)
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(isSelected ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textSecondary)
                        .lineLimit(1)

                    Text("\(summary.sessionCount) session\(summary.sessionCount == 1 ? "" : "s")")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
                .layoutPriority(1)

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(settingsManager.formatUsageMetric(cost: summary.totalCost, tokens: summary.totalTokens))
                        .font(DesignSystem.Typography.monoSmall)
                        .foregroundStyle(isSelected ? theme.primaryColor : DesignSystem.Colors.textMuted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .allowsTightening(true)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(isSelected ? theme.primaryColor.opacity(0.8) : DesignSystem.Colors.textMuted)
                }
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md)
                    .fill(isSelected ? theme.primaryColor.opacity(0.08) : DesignSystem.Colors.surfaceElevated.opacity(hovering && !isSelected ? 0.55 : 0.35))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md)
                    .stroke(isSelected ? theme.primaryColor.opacity(0.3) : DesignSystem.Colors.border.opacity(0.35), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(DesignSystem.Animation.hover, value: hovering)
    }
}

// MARK: - Workspace nav (main pane)

// MARK: - Stat Card
