import SwiftUI

// MARK: - Memory consent (first-run)

/// First-run consent before OpenBurnBar extracts memories from chats. Mirrors
/// `CLIAssistantConsentSheet`'s structure, sizing, and glass surface so the two
/// permission moments feel like one app. This view only reports the decision via
/// `onDecision`; the integrator persists the flag — no `SettingsManager` writes here.
struct MemoryConsentSheet: View {
    var onDecision: (Bool) -> Void

    /// The privacy promise. Cloud models for memory are a separate, off-by-default
    /// opt-in (`MemoryCloudModelsConsentSheet`), so this bullet must not claim
    /// an unconditional "nothing leaves your device".
    static let privacyBullet = "Nothing leaves your device unless you turn on cloud models in Settings → Privacy."

    init(onDecision: @escaping (Bool) -> Void) {
        self.onDecision = onDecision
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                // The kernel is the emblem: a living fluid aurora in BurnBar's
                // colours (whimsy → mint → lavender → ember) replaces the flat
                // circle-and-glyph, so the permission moment reads as the app's
                // own weather. It carries the emblem's accessibility meaning
                // under VoiceOver, replacing the SF Symbol entirely.
                FluidAuroraKernelView(size: 48, accessibilityLabel: "Memory")

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    Text("Remember useful details from your chats?")
                        .font(DesignSystem.Typography.title)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(
                        "OpenBurnBar can quietly note durable facts and preferences as you chat, so future answers pick up where you left off."
                    )
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                bullet(
                    icon: "doc.text.magnifyingglass",
                    tint: DesignSystem.Colors.ember.opacity(0.9),
                    text: "Extracts lasting facts and preferences locally on this Mac."
                )
                bullet(
                    icon: "eye.slash",
                    tint: DesignSystem.Colors.amber.opacity(0.9),
                    text: "Strips secrets and personal identifiers before anything is stored."
                )
                bullet(
                    icon: "checkmark.shield",
                    tint: DesignSystem.Colors.success.opacity(0.9),
                    text: "Everything is quarantined for your approval before it's ever used."
                )
                bullet(
                    icon: "lock",
                    tint: DesignSystem.Colors.textMuted,
                    text: Self.privacyBullet
                )
            }

            HStack(spacing: DesignSystem.Spacing.md) {
                Button("Not now") {
                    onDecision(false)
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)

                Button("Enable") {
                    onDecision(true)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(DesignSystem.Colors.ember)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(DesignSystem.Spacing.xl)
        .frame(minWidth: 420)
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

    private func bullet(icon: String, tint: Color, text: String) -> some View {
        Label {
            Text(text)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(tint)
        }
    }
}
