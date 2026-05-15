import SwiftUI

// MARK: - Mercury Crest (macOS)
//
// Member identity medallion. Mirrors the iOS variant.

struct MercuryCrest: View {
    enum Size {
        case small
        case medium
        case large

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
            Circle().fill(ProTheme.Palette.obsidian)
            Circle().stroke(ProTheme.Palette.aureateStroke, lineWidth: size.ringWidth)
            Circle()
                .stroke(DesignSystem.Colors.mercuryGradient, lineWidth: size.ringWidth * 0.55)
                .padding(size.diameter * 0.20)
            Circle()
                .fill(ProTheme.Palette.emberPop)
                .frame(width: size.diameter * 0.18, height: size.diameter * 0.18)
                .shadow(color: ProTheme.Palette.emberPop.opacity(0.7), radius: 3)
            if shimmer && !reduceMotion {
                Circle()
                    .fill(Color.clear)
                    .mercuryShimmer(active: true)
                    .opacity(0.6)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size.diameter, height: size.diameter)
        .accessibilityHidden(true)
    }
}

#Preview("Mercury Crest (macOS)") {
    ZStack {
        ProTheme.Palette.obsidian.ignoresSafeArea()
        HStack(spacing: 28) {
            MercuryCrest(size: .small)
            MercuryCrest(size: .medium)
            MercuryCrest(size: .large)
        }
    }
    .frame(width: 320, height: 160)
}
