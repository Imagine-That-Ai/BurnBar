import SwiftUI

// MARK: - Account Destination Picker Sheet

struct AccountDestinationPickerSheet: View {
    let profileName: String
    let destinations: [AccountChangeDestination]
    let onSelect: (AccountChangeDestination) -> Void
    let onCancel: () -> Void

    @State private var hoveredDestination: AccountChangeDestination?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: DesignSystem.Spacing.xs) {
                ZStack {
                    Circle()
                        .fill(DesignSystem.Colors.amber.opacity(0.12))
                        .frame(width: 40, height: 40)
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(DesignSystem.Colors.amber)
                }

                Text("Switch Account")
                    .font(DesignSystem.Typography.title)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                Text("Choose where to log in for \(profileName)")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .padding(.top, DesignSystem.Spacing.xl)
            .padding(.bottom, DesignSystem.Spacing.lg)

            // Destination cards
            VStack(spacing: DesignSystem.Spacing.sm) {
                ForEach(destinations, id: \.self) { destination in
                    destinationCard(destination)
                }
            }
            .padding(.horizontal, DesignSystem.Spacing.lg)

            Spacer()

            // Cancel
            Button("Cancel") {
                onCancel()
            }
            .buttonStyle(.plain)
            .font(DesignSystem.Typography.caption)
            .foregroundStyle(DesignSystem.Colors.textMuted)
            .padding(.bottom, DesignSystem.Spacing.lg)
        }
        .frame(width: 340, height: destinationSheetHeight)
        .background(DesignSystem.Colors.background)
    }

    private var destinationSheetHeight: CGFloat {
        let headerHeight: CGFloat = 120
        let cardHeight: CGFloat = 72
        let cardSpacing: CGFloat = 8
        let bottomPadding: CGFloat = 50
        return headerHeight + CGFloat(destinations.count) * cardHeight + CGFloat(max(0, destinations.count - 1)) * cardSpacing + bottomPadding
    }

    @ViewBuilder
    private func destinationCard(_ destination: AccountChangeDestination) -> some View {
        let isHovered = hoveredDestination == destination

        Button {
            onSelect(destination)
        } label: {
            HStack(spacing: DesignSystem.Spacing.md) {
                // Provider logo
                destinationLogo(for: destination)
                    .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(destination.label)
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)

                    Text(destination.subtitle)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isHovered ? destination.accentColor : DesignSystem.Colors.textMuted)
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(isHovered ? DesignSystem.Colors.surfaceElevated : DesignSystem.Colors.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .strokeBorder(
                        isHovered ? destination.accentColor.opacity(0.35) : DesignSystem.Colors.borderSubtle,
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(DesignSystem.Animation.hover) {
                hoveredDestination = hovering ? destination : nil
            }
        }
    }

    @ViewBuilder
    private func destinationLogo(for destination: AccountChangeDestination) -> some View {
        switch destination {
        case .openAI:
            ProviderLogoView(provider: .codex, size: 32, useFallbackColor: true)
        case .claude:
            ProviderLogoView(provider: .claudeCode, size: 32, useFallbackColor: true)
        case .googleAccount:
            ZStack {
                Circle()
                    .fill(Color.white)
                Image("GeminiCLILogo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 20, height: 20)
            }
        case .appleID:
            ZStack {
                Circle()
                    .fill(Color(hex: "0071E3").opacity(0.12))
                Image(systemName: "apple.logo")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color(hex: "0071E3"))
            }
        }
    }
}
