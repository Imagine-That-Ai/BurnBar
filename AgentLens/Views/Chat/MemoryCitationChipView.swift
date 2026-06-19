import SwiftUI
import OpenBurnBarCore

/// F-3: a compact citation affordance rendered on assistant turns whose system
/// prompt included memories. Tap behavior is classified by
/// `MemoryCitationResolver` — never a dead link:
///  - live + device-local `messageID` → "Source message" (tap jumps to it)
///  - live, cross-device only (`crossDeviceHMAC`, no `messageID`) → "Source on another device"
///  - `sourcePruned`/`tombstoned` → "Source no longer available"
/// Many sources render the canonical (live, jumpable) citation + a "+N more" count.
struct MemoryCitationChipView: View {
    let citations: [MemoryCitation]
    var onJumpToLocal: ((String) -> Void)? = nil

    var body: some View {
        if let resolved = MemoryCitationResolver.canonicalAndExtra(from: citations) {
            let affordance = MemoryCitationResolver.affordance(for: resolved.canonical)
            chip(affordance: affordance, extraCount: resolved.extraCount)
        }
    }

    @ViewBuilder
    private func chip(affordance: MemoryCitationAffordance, extraCount: Int) -> some View {
        let label = MemoryCitationResolver.label(for: affordance, extraCount: extraCount)
        Button {
            if case .jumpToLocal(let messageID) = affordance {
                onJumpToLocal?(messageID)
            }
        } label: {
            HStack(spacing: DesignSystem.Spacing.xxs) {
                Image(systemName: Self.icon(for: affordance))
                    .font(.system(size: 9))
                Text(label)
                    .font(DesignSystem.Typography.tiny)
            }
            .padding(.horizontal, DesignSystem.Spacing.sm)
            .padding(.vertical, DesignSystem.Spacing.xxs)
            .foregroundStyle(Self.foreground(for: affordance))
            .background(Self.background(for: affordance))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!Self.isJumpable(affordance) || onJumpToLocal == nil)
        .accessibilityLabel(label)
    }

    private static func isJumpable(_ a: MemoryCitationAffordance) -> Bool {
        if case .jumpToLocal = a { return true }
        return false
    }

    private static func icon(for a: MemoryCitationAffordance) -> String {
        switch a {
        case .jumpToLocal: return "arrow.up.right.square"
        case .crossDeviceOnly: return "iphone.radiowaves.left.and.right"
        case .sourceUnavailable: return "tray"
        }
    }

    private static func foreground(for a: MemoryCitationAffordance) -> Color {
        switch a {
        case .jumpToLocal: return DesignSystem.Colors.hermesAureate
        case .crossDeviceOnly: return DesignSystem.Colors.textSecondary
        case .sourceUnavailable: return DesignSystem.Colors.textMuted
        }
    }

    private static func background(for a: MemoryCitationAffordance) -> Color {
        switch a {
        case .jumpToLocal: return DesignSystem.Colors.hermesAureate.opacity(0.10)
        case .crossDeviceOnly: return DesignSystem.Colors.surfaceElevated
        case .sourceUnavailable: return DesignSystem.Colors.surfaceElevated.opacity(0.5)
        }
    }
}
