import SwiftUI

/// Cross-platform mini stat chip used in provider cards and dashboards.
public struct UnifiedMiniStat: View {
    public let label: String
    public let value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(UnifiedDesignSystem.Typography.tiny)
                .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
            Text(value)
                .font(UnifiedDesignSystem.Typography.monoSmall)
                .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, UnifiedDesignSystem.Spacing.md)
        .padding(.vertical, UnifiedDesignSystem.Spacing.sm)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.sm, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.sm, style: .continuous)
                    .fill(UnifiedDesignSystem.Colors.surfaceElevated.opacity(0.45))
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.sm, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.sm, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.12), UnifiedDesignSystem.Colors.border.opacity(0.35)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.5
                )
        )
    }
}
