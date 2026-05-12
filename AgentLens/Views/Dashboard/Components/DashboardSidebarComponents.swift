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
                    .fill(isSelected ? theme.primaryColor.opacity(0.08) : DesignSystem.Colors.surfaceElevated.opacity(0.35))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md)
                    .stroke(isSelected ? theme.primaryColor.opacity(0.3) : DesignSystem.Colors.border.opacity(0.35), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Model Sidebar Item

struct ModelSidebarItem: View {
    let summary: ModelSummary
    let isSelected: Bool
    let action: () -> Void

    @Environment(SettingsManager.self) private var settingsManager

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
                    .fill(isSelected ? theme.primaryColor.opacity(0.08) : DesignSystem.Colors.surfaceElevated.opacity(0.35))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md)
                    .stroke(isSelected ? theme.primaryColor.opacity(0.3) : DesignSystem.Colors.border.opacity(0.35), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Workspace nav (main pane)

struct DashboardWorkspaceNavButton: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let accent: Color
    let isSelected: Bool
    var trailingBadge: String? = nil
    var isCompact: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: DesignSystem.Spacing.sm) {
                ZStack {
                    Circle()
                        .fill(isSelected ? accent.opacity(0.18) : DesignSystem.Colors.surfaceElevated)
                        .frame(width: 30, height: 30)

                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isSelected ? accent : DesignSystem.Colors.textSecondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: DesignSystem.Spacing.xs) {
                        Text(title)
                            .font(DesignSystem.Typography.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(isSelected ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textSecondary)
                            .lineLimit(1)

                        if let trailingBadge {
                            Text(trailingBadge)
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.amber)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(DesignSystem.Colors.amber.opacity(0.15))
                                .clipShape(Capsule())
                            }
                    }

                    if !isCompact {
                        Text(subtitle)
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .multilineTextAlignment(.leading)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                            .allowsTightening(true)
                    }
                }
                .layoutPriority(1)
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.sm)
            .frame(
                minWidth: isCompact ? 106 : 150,
                idealWidth: isCompact ? 116 : 176,
                maxWidth: isCompact ? 132 : 220,
                alignment: .leading
            )
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(isSelected ? accent.opacity(0.08) : DesignSystem.Colors.surfaceElevated.opacity(0.35))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .stroke(isSelected ? accent.opacity(0.3) : DesignSystem.Colors.border.opacity(0.35), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Stat Card
