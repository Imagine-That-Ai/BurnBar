import OpenBurnBarCore
import SwiftUI

/// Minimal splash shown in the popover on first launch.
/// Opens the full onboarding wizard window.
struct OnboardingView: View {
    let settingsManager: SettingsManager
    let onOpenWizard: () -> Void
    let onSkip: () -> Void

    private var detection: [AgentProvider: Bool] {
        settingsManager.detectAvailableProviders()
    }

    private var detectedCount: Int {
        detection.values.filter { $0 }.count
    }

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.lg) {
            BurnBarLogoFormationView()
                .frame(width: 240, height: 200)

            VStack(spacing: DesignSystem.Spacing.sm) {
                Text("Welcome to OpenBurnBar")
                    .font(DesignSystem.Typography.headline)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                Text("Track token spend across all your AI agents. Local-first, private by default.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if detectedCount > 0 {
                HStack(spacing: DesignSystem.Spacing.xs) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(DesignSystem.Colors.success)
                        .font(.system(size: 12))
                    Text("\(detectedCount) agent\(detectedCount == 1 ? "" : "s") detected on this Mac")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
            }

            VStack(spacing: DesignSystem.Spacing.sm) {
                Button {
                    onOpenWizard()
                } label: {
                    Text("Get Started")
                        .font(DesignSystem.Typography.body)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DesignSystem.Spacing.sm)
                }
                .buttonStyle(.borderedProminent)

                Button("Skip for now") {
                    onSkip()
                }
                .buttonStyle(.plain)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
        }
        .padding(DesignSystem.Spacing.xl)
        .frame(width: 340)
        .background(DesignSystem.Colors.background)
    }
}
