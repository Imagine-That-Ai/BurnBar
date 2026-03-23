import SwiftUI

// MARK: - CLI assistant permission (Claude Code / Codex)

/// First-run consent before the app invokes local `claude` or `codex` binaries for the docked chat panel.
struct CLIAssistantConsentSheet: View {
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
                                    DesignSystem.Colors.teal.opacity(0.35),
                                    DesignSystem.Colors.purple.opacity(0.25)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 48, height: 48)
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                }

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    Text("Use Claude Code or Codex on this Mac?")
                        .font(DesignSystem.Typography.title)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(
                        "The assistant panel can run your installed `claude` or `codex` CLI to answer using your usage context. Commands execute locally; BurnBar does not send prompts to our servers."
                    )
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                Label {
                    Text("You stay in control — deny and the rest of the app works as before.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                } icon: {
                    Image(systemName: "lock.shield")
                        .foregroundStyle(DesignSystem.Colors.teal.opacity(0.9))
                }

                Label {
                    Text("Change anytime under Settings → Privacy.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                } icon: {
                    Image(systemName: "gearshape")
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
            }

            HStack(spacing: DesignSystem.Spacing.md) {
                Button("Not now") {
                    settingsManager.cliAssistantAllowed = false
                    settingsManager.cliAssistantConsentShown = true
                    onDismiss()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)

                Button("Allow") {
                    settingsManager.cliAssistantAllowed = true
                    settingsManager.cliAssistantConsentShown = true
                    onDismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(DesignSystem.Colors.teal)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(DesignSystem.Spacing.xl)
        .frame(minWidth: 420)
        .background {
            RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                .fill(DesignSystem.Colors.surfaceElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                        .stroke(DesignSystem.Colors.border.opacity(0.6), lineWidth: 0.5)
                )
        }
    }
}
