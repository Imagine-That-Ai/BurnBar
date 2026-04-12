import SwiftUI

struct OnboardingProviderPill: View {
    let provider: AgentProvider
    let isSelected: Bool
    let isDetected: Bool
    let onTap: () -> Void

    @State private var isHovered = false

    private var providerColor: Color {
        DesignSystem.Colors.primary(for: provider)
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                providerLogo
                Text(provider.displayName)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(isSelected ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.sm)
            .background {
                Capsule(style: .continuous)
                    .fill(isSelected ? providerColor.opacity(0.1) : DesignSystem.Colors.surface)
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(
                        isSelected ? providerColor.opacity(0.6) : DesignSystem.Colors.border,
                        lineWidth: isSelected ? 1.5 : 0.5
                    )
            }
            .overlay(alignment: .topTrailing) {
                if isDetected {
                    Circle()
                        .fill(DesignSystem.Colors.success)
                        .frame(width: 6, height: 6)
                        .offset(x: -2, y: 2)
                }
            }
            .scaleEffect(isSelected ? 1.03 : 1.0)
            .scaleEffect(isHovered ? 1.02 : 1.0)
            .animation(DesignSystem.Animation.snappy, value: isSelected)
            .animation(DesignSystem.Animation.hover, value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    @ViewBuilder
    private var providerLogo: some View {
        ProviderLogoView(provider: provider, size: 24, useFallbackColor: true)
    }
}
