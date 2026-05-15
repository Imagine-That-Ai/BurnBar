import SwiftUI
import OpenBurnBarCore

// MARK: - Mercury Crest
//
// Pro vocabulary — concentric mercury foil medallion. Member identity badge.
// Replaces the breathing `ProBadgeDot` whisper once the user is a Cloud
// member, so the same visual slot signals state (free vs member) without
// flipping the layout. Pure SwiftUI shapes — no SF Symbols dependency.

struct MercuryCrest: View {
    enum Size {
        case small   // 24pt — nav tray, profile chip
        case medium  // 36pt — list rows, menu-bar footer
        case large   // 48pt — profile hero, locked-feature veil

        var diameter: CGFloat {
            switch self {
            case .small:  return ProTheme.Layout.crestSmall
            case .medium: return ProTheme.Layout.crestMedium
            case .large:  return ProTheme.Layout.crestLarge
            }
        }

        var ringWidth: CGFloat {
            switch self {
            case .small:  return 1.0
            case .medium: return 1.4
            case .large:  return 1.8
            }
        }
    }

    var size: Size = .small
    var shimmer: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .fill(ProTheme.Palette.obsidian)

            // Outer foil ring
            Circle()
                .stroke(ProTheme.Palette.aureateStroke, lineWidth: size.ringWidth)

            // Inner foil ring — smaller, mercury gradient
            Circle()
                .stroke(UnifiedDesignSystem.mercuryGradient, lineWidth: size.ringWidth * 0.55)
                .padding(size.diameter * 0.20)

            // Ember dot center
            Circle()
                .fill(ProTheme.Palette.emberPop)
                .frame(width: size.diameter * 0.18, height: size.diameter * 0.18)
                .shadow(color: ProTheme.Palette.emberPop.opacity(0.7), radius: 3)

            // Continuous shimmer overlay across the foil
            if shimmer && !reduceMotion {
                MercuryShimmerOverlay()
                    .clipShape(Circle())
                    .blendMode(.plusLighter)
                    .opacity(0.6)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size.diameter, height: size.diameter)
        .accessibilityHidden(true)
    }
}

// MARK: - Preview

#Preview("Mercury Crest Sizes") {
    ZStack {
        ProTheme.Palette.obsidian.ignoresSafeArea()
        HStack(spacing: 32) {
            MercuryCrest(size: .small)
            MercuryCrest(size: .medium)
            MercuryCrest(size: .large)
        }
    }
}
