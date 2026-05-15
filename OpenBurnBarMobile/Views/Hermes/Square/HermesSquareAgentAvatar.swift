import SwiftUI
import OpenBurnBarCore

// MARK: - Hermes Square Agent Avatar
//
// Single source of truth for "render this agent as a circular avatar"
// across the Living Inbox, pinned grid, mission tiles, brand zone, fan-
// out composer, discover drawer, and split-view list.
//
// Priority:
//   1. If the identity resolves to an `AgentProvider`, render the bundled
//      brand logo via `UnifiedProviderLogoView`. This is the WeChat-class
//      "I recognize this brand instantly" affordance.
//   2. Otherwise fall back to the gradient disc + glyph treatment (the
//      original Hermes Square avatar) so user-installed agents without a
//      known vendor still get a beautiful, palette-correct circle.
//
// Optional decorations:
//   • `availabilityDot` — coloured ring + dot on the bottom-right corner
//   • `accentRing` — palette-coloured stroke around the entire avatar
//   • `glyphFallback` — override the glyph when no logo is present

struct HermesSquareAgentAvatar: View {
    let identity: AgentIdentity
    var size: CGFloat = 38
    var showAvailability: Bool = true
    var ringStroke: Bool = false

    private var accent: Color { Color(hex: identity.paletteHex) }
    private var hasLogo: Bool { identity.resolvedProvider != nil }
    private var availabilityDotSize: CGFloat { max(6, size * 0.20) }

    var body: some View {
        ZStack {
            avatar
            if showAvailability && identity.availability != .unknown {
                Circle()
                    .fill(availabilityColor)
                    .frame(width: availabilityDotSize, height: availabilityDotSize)
                    .overlay(
                        Circle().stroke(DesignSystemColors.background, lineWidth: max(1, size * 0.04))
                    )
                    // Bottom-right anchor: offset by ~37% of size so the
                    // dot sits half on / half off the avatar edge.
                    .offset(x: size * 0.37, y: size * 0.37)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(accessibilityDescription)
    }

    @ViewBuilder
    private var avatar: some View {
        if let provider = identity.resolvedProvider {
            // Logo treatment: bundled brand artwork on a clean rounded
            // square (UnifiedProviderLogoView already handles dark-mode
            // backdrop for monochrome marks). We wrap in a subtle accent
            // ring when `ringStroke` is set so the avatar still reads as
            // "this agent's identity" rather than just "a logo."
            UnifiedProviderLogoView(provider: provider, size: size, useFallbackColor: true)
                .overlay(
                    Group {
                        if ringStroke {
                            RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
                                .stroke(accent.opacity(0.55), lineWidth: max(0.8, size * 0.03))
                        }
                    }
                )
        } else {
            // Gradient fallback for user-installed agents whose vendor
            // doesn't match a bundled provider. Preserves the editorial
            // palette + glyph so the avatar still feels owned.
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [accent, accent.opacity(0.66)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Text(identity.glyph)
                    .font(.system(size: size * 0.47, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                if ringStroke {
                    Circle().stroke(accent.opacity(0.55), lineWidth: max(0.8, size * 0.03))
                }
            }
        }
    }

    private var availabilityColor: Color {
        switch identity.availability {
        case .online:    return DesignSystemColors.success
        case .degraded:  return DesignSystemColors.warning
        case .offline:   return DesignSystemColors.error
        case .unknown:   return DesignSystemColors.textMuted
        }
    }

    private var accessibilityDescription: String {
        let logoNote = hasLogo ? "" : " (gradient avatar)"
        return "\(identity.displayName) — \(identity.availability.displayLabel)\(logoNote)"
    }
}
