import SwiftUI

struct OnboardingCompleteView: View {
    let dataStore: DataStore
    let selectedProviders: Set<AgentProvider>
    let onOpenDashboard: () -> Void
    let onDismiss: () -> Void

    @State private var checkmarkScale: CGFloat = 0.3
    @State private var checkmarkOpacity: Double = 0

    private var sessionCount: Int { dataStore.totalUsageSessionCount }
    private var providerCount: Int {
        dataStore.providerSummaries(for: .allTime).count
    }

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.xl) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(DesignSystem.Colors.success)
                .scaleEffect(checkmarkScale)
                .opacity(checkmarkOpacity)

            VStack(spacing: DesignSystem.Spacing.sm) {
                if sessionCount > 0 {
                    Text("Found \(sessionCount) session\(sessionCount == 1 ? "" : "s") across \(providerCount) provider\(providerCount == 1 ? "" : "s")")
                        .font(DesignSystem.Typography.headline)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .multilineTextAlignment(.center)
                } else {
                    Text("You're all set")
                        .font(DesignSystem.Typography.headline)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                }

                Text("OpenBurnBar is now tracking \(selectedProviders.count) agent\(selectedProviders.count == 1 ? "" : "s"). Your dashboard, session logs, and Hermes chat are ready.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                if sessionCount == 0 {
                    HStack(spacing: DesignSystem.Spacing.xs) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(DesignSystem.Colors.warning)
                        Text("No historical sessions were found. Your dashboard may look empty until your agents log new activity. You can trigger a manual scan anytime from the toolbar.")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, DesignSystem.Spacing.md)
                    .padding(.vertical, DesignSystem.Spacing.sm)
                    .background {
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                            .fill(DesignSystem.Colors.warning.opacity(0.06))
                    }
                }
            }

            Spacer()

            VStack(spacing: DesignSystem.Spacing.sm) {
                Button {
                    onOpenDashboard()
                } label: {
                    Text("Open Dashboard")
                        .font(DesignSystem.Typography.body)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DesignSystem.Spacing.sm)
                }
                .buttonStyle(.borderedProminent)

                Button("Stay in menu bar") {
                    onDismiss()
                }
                .buttonStyle(.plain)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.6).delay(0.15)) {
                checkmarkScale = 1.0
                checkmarkOpacity = 1.0
            }
        }
    }
}
