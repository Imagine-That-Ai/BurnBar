import SwiftUI

struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: MobileTheme.Spacing.lg) {
            Image(systemName: icon)
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(MobileTheme.Colors.textMuted)
            Text(title)
                .font(MobileTheme.Typography.headline)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
            Text(message)
                .font(MobileTheme.Typography.body)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(MobileTheme.Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    EmptyStateView(
        icon: "chart.bar",
        title: "No Data Yet",
        message: "Start using your agents and usage will appear here."
    )
}
