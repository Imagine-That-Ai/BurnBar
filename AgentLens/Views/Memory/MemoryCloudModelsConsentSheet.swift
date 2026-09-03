import SwiftUI

// MARK: - Memory Pro cloud-models consent (first enable)

/// Consent before Memory Pro may send redacted memory facts and questions to a
/// provider the member picks, on the member's own key or subscription. Same
/// chrome as `CLIAssistantConsentSheet`; writes the settings itself.
struct MemoryCloudModelsConsentSheet: View {
    @Bindable var settingsManager: SettingsManager
    var onDismiss: () -> Void

    static let bullets: [String] = [
        "Sends redacted facts and questions to the provider you choose, on your key or subscription.",
        "Never sends raw transcripts, anything the secret filter caught, or your vault.",
        "BurnBar never receives your memory data; the audit log records every request without content.",
        "Off by default. Change providers or turn it off anytime in Settings → Privacy."
    ]

    private static let icons = ["arrow.up.right.circle", "eye.slash", "lock.shield", "gearshape"]

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    DesignSystem.Colors.whimsy.opacity(0.35),
                                    DesignSystem.Colors.ember.opacity(0.25)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 48, height: 48)
                    Image(systemName: "brain")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                }

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    Text("Use cloud models for memory?")
                        .font(DesignSystem.Typography.title)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(
                        "Bigger models extract more, reconcile better, and can answer questions from your memories. They run on your own subscription or keys, straight from this Mac."
                    )
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                ForEach(Array(Self.bullets.enumerated()), id: \.offset) { index, text in
                    Label {
                        Text(text)
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: Self.icons[index])
                            .foregroundStyle(DesignSystem.Colors.whimsy.opacity(0.9))
                    }
                }
            }

            HStack(spacing: DesignSystem.Spacing.md) {
                Button("Not now") {
                    settingsManager.memoryCloudModelsOptIn = false
                    settingsManager.memoryCloudModelsConsentShown = true
                    onDismiss()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)

                Button("Turn on") {
                    settingsManager.memoryCloudModelsOptIn = true
                    settingsManager.memoryCloudModelsConsentShown = true
                    Analytics.shared.track(.settingsChanged, [
                        "setting_key": "memory_cloud_models",
                        "new_value": .bool(true)
                    ])
                    onDismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(DesignSystem.Colors.whimsy)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(DesignSystem.Spacing.xl)
        .frame(minWidth: 460)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                    .fill(DesignSystem.Colors.surfaceElevated.opacity(0.6))
            }
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.15), DesignSystem.Colors.border.opacity(0.35)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.5
                    )
            )
        }
        .liquidGlassSurface(in: RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous), fallback: .ultraThinMaterial)
    }
}
