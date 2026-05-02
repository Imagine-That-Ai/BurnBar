import SwiftUI

struct ErrorStateView: View {
    let icon: String
    let title: String
    let message: String
    let retryLabel: String
    let onRetry: (() -> Void)?

    init(
        icon: String = "exclamationmark.triangle.fill",
        title: String = "Something went wrong",
        message: String,
        retryLabel: String = "Try Again",
        onRetry: (() -> Void)? = nil
    ) {
        self.icon = icon
        self.title = title
        self.message = message
        self.retryLabel = retryLabel
        self.onRetry = onRetry
    }

    var body: some View {
        VStack(spacing: MobileTheme.Spacing.lg) {
            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundStyle(MobileTheme.Colors.warning)
            Text(title)
                .font(MobileTheme.Typography.headline)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
            Text(message)
                .font(MobileTheme.Typography.body)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
            if let onRetry {
                Button(action: onRetry) {
                    Label(retryLabel, systemImage: "arrow.clockwise")
                        .font(MobileTheme.Typography.body)
                }
                .buttonStyle(.borderedProminent)
                .tint(MobileTheme.Colors.accent)
            }
        }
        .padding(MobileTheme.Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    ErrorStateView(message: "Network request failed.") {}
}
