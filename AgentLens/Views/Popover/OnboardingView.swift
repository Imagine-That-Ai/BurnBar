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
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            AppLogoView(size: 44)
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                Text("Look up. That's the app.")
                    .font(DesignSystem.Typography.headline)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("No Dock icon. The receipt lives in the menu bar.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Run Claude or Codex once. We pick up the local logs. No account.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
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
                    onSkip()
                } label: {
                    Text("Got it")
                        .font(DesignSystem.Typography.body)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DesignSystem.Spacing.sm)
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignSystem.Colors.ember)

                Button("Get Started") {
                    onOpenWizard()
                }
                .buttonStyle(.plain)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(DesignSystem.Spacing.xl)
        .frame(width: 340)
        .background {
            Color.clear
                .liquidGlassSurface(
                    in: RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous),
                    fallback: .ultraThinMaterial
                )
        }
    }
}
