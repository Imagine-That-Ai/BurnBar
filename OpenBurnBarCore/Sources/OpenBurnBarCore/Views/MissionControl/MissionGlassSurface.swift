import SwiftUI

// MARK: - Mission Glass Surface
//
// Core-side mirror of `LiquidGlassFallback` (which lives in OpenBurnBarMobile
// and is therefore not visible to macOS). Same intent: pick `.glassEffect`
// when iOS 26 / macOS 26 are present, fall back to `.ultraThinMaterial` +
// hand-tuned sheen + edge gradient on older OS versions. Honors
// `accessibilityReduceTransparency` with an opaque fill.
//
// Variants drive sheen + edge tuning so a single modifier covers hero, default,
// urgent, success, and Hermes surfaces inside the Mission Control Console.

public enum MissionGlassVariant {
    case hero
    case standard
    case compact
    case urgent
    case success
    case hermes
}

public struct MissionGlassSurface: ViewModifier {
    public let variant: MissionGlassVariant
    public let cornerRadius: CGFloat

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public func body(content: Content) -> some View {
        content
            .background(backgroundLayer)
            .overlay(edgeLayer)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    @ViewBuilder
    private var backgroundLayer: some View {
        if reduceTransparency {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(opaqueFill)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(sheenGradient)
            }
            .modifier(LiquidGlassEffectIfAvailable(cornerRadius: cornerRadius))
        }
    }

    private var edgeLayer: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .stroke(edgeGradient, lineWidth: edgeWidth)
            .blendMode(.plusLighter)
    }

    // MARK: Sheens

    private var sheenGradient: LinearGradient {
        switch variant {
        case .hero:
            return LinearGradient(
                colors: [
                    UnifiedDesignSystem.Colors.ember.opacity(colorScheme == .dark ? 0.16 : 0.10),
                    Color.clear,
                    UnifiedDesignSystem.Colors.amber.opacity(colorScheme == .dark ? 0.06 : 0.04)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .standard, .compact:
            return LinearGradient(
                colors: [
                    Color.white.opacity(colorScheme == .dark ? 0.06 : 0.45),
                    Color.clear,
                    UnifiedDesignSystem.Colors.ember.opacity(colorScheme == .dark ? 0.03 : 0.02)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .urgent:
            return LinearGradient(
                colors: [
                    UnifiedDesignSystem.Colors.warning.opacity(0.20),
                    Color.clear,
                    UnifiedDesignSystem.Colors.error.opacity(0.10)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .success:
            return LinearGradient(
                colors: [
                    UnifiedDesignSystem.Colors.success.opacity(0.18),
                    Color.clear,
                    UnifiedDesignSystem.Colors.success.opacity(0.04)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .hermes:
            return LinearGradient(
                colors: [
                    UnifiedDesignSystem.Colors.hermesMercury.opacity(0.16),
                    UnifiedDesignSystem.Colors.hermesAureate.opacity(0.12),
                    UnifiedDesignSystem.Colors.hermesMercury.opacity(0.16)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    // MARK: Edges

    private var edgeGradient: LinearGradient {
        switch variant {
        case .hero:
            return LinearGradient(
                colors: [
                    UnifiedDesignSystem.Colors.ember.opacity(0.55),
                    UnifiedDesignSystem.Colors.amber.opacity(0.35),
                    UnifiedDesignSystem.Colors.blaze.opacity(0.25)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .standard:
            return LinearGradient(
                colors: [
                    Color.white.opacity(colorScheme == .dark ? 0.18 : 0.55),
                    UnifiedDesignSystem.Colors.border.opacity(0.45),
                    UnifiedDesignSystem.Colors.ember.opacity(0.18)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .compact:
            return LinearGradient(
                colors: [
                    UnifiedDesignSystem.Colors.border.opacity(0.45),
                    UnifiedDesignSystem.Colors.borderSubtle.opacity(0.35)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .urgent:
            return LinearGradient(
                colors: [
                    UnifiedDesignSystem.Colors.warning.opacity(0.85),
                    UnifiedDesignSystem.Colors.error.opacity(0.65)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .success:
            return LinearGradient(
                colors: [
                    UnifiedDesignSystem.Colors.success.opacity(0.7),
                    UnifiedDesignSystem.Colors.success.opacity(0.35)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .hermes:
            return LinearGradient(
                colors: [
                    UnifiedDesignSystem.Colors.hermesMercury.opacity(0.85),
                    UnifiedDesignSystem.Colors.hermesAureate.opacity(0.65),
                    UnifiedDesignSystem.Colors.hermesMercury.opacity(0.85)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var edgeWidth: CGFloat {
        switch variant {
        case .hero, .urgent, .success, .hermes: return 1.0
        case .standard, .compact: return 0.6
        }
    }

    private var opaqueFill: Color {
        switch variant {
        case .hero, .standard: return UnifiedDesignSystem.Colors.surface
        case .compact:         return UnifiedDesignSystem.Colors.surfaceElevated
        case .urgent:          return UnifiedDesignSystem.Colors.warning.opacity(0.12)
        case .success:         return UnifiedDesignSystem.Colors.success.opacity(0.12)
        case .hermes:          return UnifiedDesignSystem.Colors.surface
        }
    }
}

/// Wraps the OS-26 `.glassEffect` call so the call site stays simple. On older
/// SDKs / OS versions the modifier becomes a no-op (we keep the manual sheen).
private struct LiquidGlassEffectIfAvailable: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            content
        }
    }
}

public extension View {
    /// Apply Mission Control glass to any view. Defaults to `.standard` at the
    /// Aurora "standard" corner.
    func missionGlass(
        _ variant: MissionGlassVariant = .standard,
        cornerRadius: CGFloat = UnifiedDesignSystem.Radius.lg
    ) -> some View {
        modifier(MissionGlassSurface(variant: variant, cornerRadius: cornerRadius))
    }
}
