import SwiftUI

struct SessionLogCloudConsentSheet: View {
    @Bindable var settingsManager: SettingsManager
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    DesignSystem.Colors.ember.opacity(0.4),
                                    DesignSystem.Colors.amber.opacity(0.25)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 52, height: 52)

                    Image(systemName: "scroll.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    Text("Back up session logs to the cloud?")
                        .font(DesignSystem.Typography.title)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("OpenBurnBar can securely back up your full conversation logs — including provider sessions and OpenBurnBar Assistant history — to your private cloud storage. Access and export them from any device.")
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                featureBullet(
                    icon: "lock.icloud",
                    iconColor: DesignSystem.Colors.whimsy,
                    text: "Stored under your account — no other user can access your logs."
                )
                featureBullet(
                    icon: "arrow.triangle.2.circlepath",
                    iconColor: DesignSystem.Colors.amber,
                    text: "Existing logs are backfilled automatically on first enable."
                )
                featureBullet(
                    icon: "gearshape",
                    iconColor: DesignSystem.Colors.textMuted,
                    text: "Toggle off anytime in Settings → Account."
                )
            }

            Divider().background(DesignSystem.Colors.border.opacity(0.5))

            HStack(spacing: DesignSystem.Spacing.md) {
                Button("Not now") {
                    settingsManager.conversationBackupEnabled = false
                    settingsManager.sessionLogCloudBackupConsentShown = true
                    onDismiss()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Enable Cloud Backup") {
                    settingsManager.conversationBackupEnabled = true
                    settingsManager.sessionLogCloudBackupConsentShown = true
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignSystem.Colors.ember)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DesignSystem.Spacing.xl)
        .frame(minWidth: 440, maxWidth: 520)
        .liquidGlassSurface(
            in: RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous),
            fallback: .ultraThinMaterial
        )
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                    .fill(DesignSystem.Colors.surfaceElevated.opacity(0.55))

                LinearGradient(
                    colors: [
                        DesignSystem.Colors.ember.opacity(0.06),
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: .center
                )
                .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous))
            }
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.16), DesignSystem.Colors.border.opacity(0.35)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.5
                    )
            )
        }
    }

    private func featureBullet(icon: String, iconColor: Color, text: String) -> some View {
        Label {
            Text(text)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: 20, alignment: .center)
        }
    }
}
