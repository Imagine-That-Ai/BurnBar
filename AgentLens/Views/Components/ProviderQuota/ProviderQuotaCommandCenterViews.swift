import SwiftUI
import OpenBurnBarCore

#if canImport(AppKit)
import AppKit
#endif

// MARK: - Menu bar popover strip

// MARK: - Quota Command Center

// MARK: - Row Actions

enum QuotaRowAction {
    case enable
    case repair
    case remove
}

// MARK: - Quota Command Row

// MARK: - Claude Bridge State Description

extension ClaudeQuotaBridgeStatus.State {
    var description: String {
        switch self {
        case .notInstalled: return "Not installed"
        case .awaitingFirstPayload: return "Waiting for first response"
        case .ready: return "Bridge active"
        case .disabledByHooks: return "Hooks disabled"
        case .invalidConfiguration: return "Needs reconfiguration"
        }
    }
}

// MARK: - Glass Button Style for rows

struct GlassButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DesignSystem.Typography.caption)
            .foregroundStyle(prominent ? DesignSystem.Colors.blaze : DesignSystem.Colors.textSecondary)
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.sm)
            .background {
                if prominent {
                    ZStack {
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                            .fill(DesignSystem.Colors.blaze.opacity(0.15))
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                            .stroke(DesignSystem.Colors.blaze.opacity(0.3), lineWidth: 0.5)
                    }
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                            .fill(DesignSystem.Colors.surface.opacity(0.5))
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                            .stroke(DesignSystem.Colors.border.opacity(0.5), lineWidth: 0.5)
                    }
                }
            }
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(DesignSystem.Animation.snappy, value: configuration.isPressed)
    }
}
