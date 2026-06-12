import SwiftUI

struct OnboardingTourView: View {
    @Binding var currentPage: Int

    private static let pages: [TourPage] = [
        TourPage(
            icon: "chart.bar.fill",
            iconGradient: DesignSystem.Colors.primaryGradient,
            title: "Dashboard",
            description: "Your burn rate at a glance. Token spend, model breakdown, cost trends \u{2014} all from local logs, never phoning home."
        ),
        TourPage(
            icon: "text.bubble.fill",
            iconGradient: DesignSystem.Colors.accentGradient,
            title: "Session Logs",
            description: "Every conversation, searchable. Browse by provider, project, or time. Export markdown for your records."
        ),
        TourPage(
            icon: "target",
            iconGradient: LinearGradient(
                colors: [DesignSystem.Colors.amber, DesignSystem.Colors.blaze],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            title: "Projects",
            description: "Organize work by project, see spend and activity in one place, and keep context tied to what you’re building."
        ),
        TourPage(
            icon: "wind",
            iconGradient: DesignSystem.Colors.mercuryGradient,
            title: "Hermes Chat",
            description: "Your local AI companion. Ask questions about your usage, search conversations, or let Hermes analyze your workflow patterns."
        )
    ]

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.lg) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                Text("What OpenBurnBar does")
                    .font(DesignSystem.Typography.title)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                Text("A quick look at the surfaces you'll use every day.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()

            // Tour card
            let page = Self.pages[currentPage]
            GlassCard {
                VStack(spacing: DesignSystem.Spacing.lg) {
                    Image(systemName: page.icon)
                        .font(.system(size: 40, weight: .medium))
                        .foregroundStyle(page.iconGradient)

                    Text(page.title)
                        .font(DesignSystem.Typography.headline)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)

                    Text(page.description)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(DesignSystem.Spacing.xl)
                .frame(maxWidth: .infinity)
            }
            .id(currentPage) // force transition on page change

            Spacer()

            // Page dots + nav
            HStack(spacing: DesignSystem.Spacing.lg) {
                Button {
                    guard currentPage > 0 else { return }
                    withAnimation(DesignSystem.Animation.standard) {
                        currentPage -= 1
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(currentPage > 0 ? DesignSystem.Colors.textSecondary : DesignSystem.Colors.textMuted)
                }
                .buttonStyle(.plain)
                .disabled(currentPage == 0)

                HStack(spacing: DesignSystem.Spacing.sm) {
                    ForEach(0..<Self.pages.count, id: \.self) { index in
                        Circle()
                            .fill(index == currentPage ? DesignSystem.Colors.ember : DesignSystem.Colors.border)
                            .frame(width: index == currentPage ? 8 : 6, height: index == currentPage ? 8 : 6)
                            .animation(DesignSystem.Animation.snappy, value: currentPage)
                    }
                }

                Button {
                    guard currentPage < Self.pages.count - 1 else { return }
                    withAnimation(DesignSystem.Animation.standard) {
                        currentPage += 1
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(currentPage < Self.pages.count - 1 ? DesignSystem.Colors.textSecondary : DesignSystem.Colors.textMuted)
                }
                .buttonStyle(.plain)
                .disabled(currentPage >= Self.pages.count - 1)
            }
        }
    }
}

private struct TourPage {
    let icon: String
    let iconGradient: LinearGradient
    let title: String
    let description: String
}
