import SwiftUI

// MARK: - Aurora Button Style
//
// Five visual flavors. All share scale-press feedback and haptic coupling.

enum AuroraButtonRole {
    case primary
    case secondary
    case ghost
    case destructive
    case hermes
}

struct AuroraButtonStyle: ButtonStyle {
    let role: AuroraButtonRole
    let fullWidth: Bool

    init(role: AuroraButtonRole = .primary, fullWidth: Bool = false) {
        self.role = role
        self.fullWidth = fullWidth
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(MobileTheme.Typography.headline)
            .foregroundStyle(foreground)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .padding(.horizontal, MobileTheme.Spacing.xl)
            .padding(.vertical, MobileTheme.Spacing.md)
            .background(background(isPressed: configuration.isPressed))
            .overlay(stroke)
            .clipShape(Capsule(style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .shadow(
                color: shadowColor,
                radius: configuration.isPressed ? 4 : 14,
                x: 0,
                y: configuration.isPressed ? 2 : 8
            )
            .animation(AuroraDesign.Motion.cardPress, value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, newValue in
                guard newValue else { return }
                switch role {
                case .primary, .hermes: HapticBus.primaryAction()
                case .destructive:      HapticBus.threshold()
                case .secondary, .ghost: HapticBus.toggle()
                }
            }
    }

    // MARK: - Backgrounds

    @ViewBuilder
    private func background(isPressed: Bool) -> some View {
        switch role {
        case .primary:
            Capsule(style: .continuous)
                .fill(MobileTheme.primaryGradient)
                .opacity(isPressed ? 0.92 : 1.0)
        case .secondary:
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule(style: .continuous)
                        .fill(MobileTheme.Colors.surface.opacity(isPressed ? 0.4 : 0.6))
                )
        case .ghost:
            Capsule(style: .continuous)
                .fill(MobileTheme.ember.opacity(isPressed ? 0.18 : 0.10))
        case .destructive:
            Capsule(style: .continuous)
                .fill(MobileTheme.error.opacity(isPressed ? 0.85 : 1.0))
        case .hermes:
            Capsule(style: .continuous)
                .fill(AuroraDesign.Gradients.mercuryFoil)
                .opacity(isPressed ? 0.92 : 1.0)
        }
    }

    private var stroke: some View {
        Capsule(style: .continuous)
            .stroke(strokeColor, lineWidth: strokeWidth)
    }

    // MARK: - Per-Role Tokens

    private var foreground: Color {
        switch role {
        case .primary: return .white
        case .secondary: return MobileTheme.Colors.textPrimary
        case .ghost: return MobileTheme.ember
        case .destructive: return .white
        case .hermes: return .white
        }
    }

    private var strokeColor: Color {
        switch role {
        case .primary: return MobileTheme.amber.opacity(0.45)
        case .secondary: return MobileTheme.Colors.border.opacity(0.6)
        case .ghost: return MobileTheme.ember.opacity(0.4)
        case .destructive: return MobileTheme.error.opacity(0.55)
        case .hermes: return MobileTheme.hermesAureate.opacity(0.5)
        }
    }

    private var strokeWidth: CGFloat {
        switch role {
        case .secondary: return 0.5
        default: return 1.0
        }
    }

    private var shadowColor: Color {
        switch role {
        case .primary: return MobileTheme.ember.opacity(0.35)
        case .destructive: return MobileTheme.error.opacity(0.30)
        case .hermes: return MobileTheme.hermesAureate.opacity(0.30)
        case .secondary, .ghost: return Color.black.opacity(0.10)
        }
    }
}

extension ButtonStyle where Self == AuroraButtonStyle {
    static func aurora(_ role: AuroraButtonRole = .primary, fullWidth: Bool = false) -> AuroraButtonStyle {
        AuroraButtonStyle(role: role, fullWidth: fullWidth)
    }
}
