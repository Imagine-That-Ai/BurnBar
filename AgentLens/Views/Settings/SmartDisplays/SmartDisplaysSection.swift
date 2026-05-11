import OpenBurnBarCore
import SwiftUI

// MARK: - Smart Displays Section (macOS)
//
// Groups the Nest Hub + Pixel Clock cards under one rearrangeable
// "Smart Displays" section. Each card sits below a grab strip — the
// section label itself — that the user can **click and hold to drag
// the entire card** to a new position.
//
// The legacy section titles (`googleNestHubSectionTitle`,
// `pixelClockSectionTitle`) are preserved verbatim because existing
// tests + Settings deep-links assert on them.

struct SmartDisplaysSection: View {
    @Bindable var settingsManager: SettingsManager
    let runtimeContext: OpenBurnBarRuntimeContext?

    init(
        settingsManager: SettingsManager,
        runtimeContext: OpenBurnBarRuntimeContext? = nil
    ) {
        self.settingsManager = settingsManager
        self.runtimeContext = runtimeContext
    }

    var body: some View {
        SmartDisplayReorderable(
            settingsManager: settingsManager,
            header: { kind, _ in label(for: kind) }
        ) { kind, _ in
            switch kind {
            case .nestHub:
                NestHubSettingsCard(
                    settingsManager: settingsManager,
                    runtimeContext: runtimeContext
                )
            case .pixelClock:
                PixelClockSettingsCard(
                    settingsManager: settingsManager,
                    runtimeContext: runtimeContext
                )
            }
        }
    }
}

private extension SmartDisplaysSection {

    func label(for kind: SmartDisplayKind) -> AnyView {
        switch kind {
        case .nestHub:
            return AnyView(SmartDisplayCardLabel(
                title: MacCopy.googleNestHubSectionTitle,
                subtitle: "Refresh, mirror, and announce quota on a Nest Hub via DashCast."
            ))
        case .pixelClock:
            return AnyView(SmartDisplayCardLabel(
                title: MacCopy.pixelClockSectionTitle,
                subtitle: "Drive a Pixel Clock running AWTRIX over HTTP with palette-aware quota frames."
            ))
        }
    }
}

// MARK: - Display Card Label
//
// Used as the draggable header strip above each Smart Display card.
// The grip glyph at the right makes the affordance obvious.

private struct SmartDisplayCardLabel: View {
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .center, spacing: DesignSystem.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DesignSystem.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                Text(subtitle)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            Spacer(minLength: 0)
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .accessibilityLabel("Drag handle. Click and hold to move this display.")
        }
        .padding(.horizontal, DesignSystem.Spacing.xs)
        .padding(.bottom, DesignSystem.Spacing.xs)
    }
}
