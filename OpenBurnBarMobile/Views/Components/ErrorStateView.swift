import SwiftUI

struct ErrorStateView: View {
    let message: String
    let onRetry: (() -> Void)?

    var body: some View {
        VStack(spacing: MobileTheme.Spacing.lg) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(MobileTheme.Colors.warning)
            Text("Something went wrong")
                .font(MobileTheme.Typography.headline)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
            Text(message)
                .font(MobileTheme.Typography.body)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
            if let onRetry {
                Button(action: onRetry) {
                    Label("Try Again", systemImage: "arrow.clockwise")
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
