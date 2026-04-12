import SwiftUI
import OpenBurnBarCore

struct SwitcherOnboardingDoneStep: View {
    let addedCount: Int
    let verifiedCount: Int
    let identities: [DiscoveredIdentity]
    let onOpenSettings: () -> Void
    let onDismiss: () -> Void

    @State private var checkmarkScale: CGFloat = 0.3
    @State private var checkmarkOpacity: Double = 0

    private var browserCount: Int {
        identities.filter {
            if case .chromeProfile = $0.source { return true }
            if case .safari = $0.source { return true }
            return false
        }.count
    }

    private var cliCount: Int {
        identities.filter {
            if case .codex = $0.source { return true }
            if case .claudeCode = $0.source { return true }
            if case .opencode = $0.source { return true }
            return false
        }.count
    }

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.xl) {
            Spacer()

            // Animated success
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(DesignSystem.Colors.success)
                .scaleEffect(checkmarkScale)
                .opacity(checkmarkOpacity)

            VStack(spacing: DesignSystem.Spacing.sm) {
                Text("You\u{2019}re switched in")
                    .font(DesignSystem.Typography.headline)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                Text("\(addedCount) profile\(addedCount == 1 ? "" : "s") ready \u{2014} \(browserCount) browser\(browserCount == 1 ? "" : "s"), \(cliCount) CLI\(cliCount == 1 ? "" : "s")")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .multilineTextAlignment(.center)
            }

            // Verification results
            if verifiedCount > 0 {
                GlassCard {
                    VStack(spacing: DesignSystem.Spacing.xs) {
                        ForEach(identities.filter { $0.isVerified }) { identity in
                            HStack(spacing: DesignSystem.Spacing.sm) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(DesignSystem.Colors.success)
                                Text(identity.displayTitle)
                                    .font(DesignSystem.Typography.caption)
                                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                                Spacer()
                                Text("Verified")
                                    .font(DesignSystem.Typography.tiny)
                                    .foregroundStyle(DesignSystem.Colors.success)
                            }
                        }
                    }
                    .padding(DesignSystem.Spacing.md)
                }
            }

            // Tips
            VStack(spacing: DesignSystem.Spacing.sm) {
                tipRow(text: "Switch profiles instantly from the menu bar popover")
                tipRow(text: "Launch your active profile with one click from the Dashboard")
                tipRow(text: "Manage profiles anytime in Settings \u{2192} Account Switcher")
            }
            .padding(.vertical, DesignSystem.Spacing.md)

            Spacer()

            VStack(spacing: DesignSystem.Spacing.sm) {
                Button {
                    onOpenSettings()
                } label: {
                    Text("Open Settings")
                        .font(DesignSystem.Typography.body)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DesignSystem.Spacing.sm)
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignSystem.Colors.amber)

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

    private func tipRow(text: String) -> some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 10))
                .foregroundStyle(DesignSystem.Colors.success)
            Text(text)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DesignSystem.Spacing.md)
    }
}
