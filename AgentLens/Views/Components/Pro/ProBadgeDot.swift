import SwiftUI

// MARK: - Pro Badge Dot (macOS)
//
// 6pt foil whisper on persistent surfaces (sidebar user row, menu-bar
// popover footer). Free users see breathing; members swap for `MercuryCrest`.

struct ProBadgeDot: View {
    enum Pulse {
        case breathing
        case still
    }

    var pulse: Pulse = .breathing
    var diameter: CGFloat = ProTheme.Layout.badgeDot

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bright = false

    var body: some View {
        Circle()
            .fill(DesignSystem.Colors.mercuryGradient)
            .overlay(
                Circle().stroke(ProTheme.Palette.aureate.opacity(0.95), lineWidth: 0.7)
            )
            .frame(width: diameter, height: diameter)
            .shadow(color: ProTheme.Palette.aureate.opacity(0.55), radius: 3)
            .opacity(pulse == .breathing && !reduceMotion ? (bright ? 1.0 : 0.6) : 1.0)
            .onAppear {
                guard pulse == .breathing, !reduceMotion else { return }
                withAnimation(ProTheme.Motion.breathing) { bright = true }
            }
            .accessibilityHidden(true)
    }
}

#Preview("Pro Badge Dot (macOS)") {
    ZStack {
        ProTheme.Palette.obsidian.ignoresSafeArea()
        HStack(spacing: 24) {
            ProBadgeDot(pulse: .breathing)
            ProBadgeDot(pulse: .breathing, diameter: 8)
            ProBadgeDot(pulse: .still)
        }
    }
    .frame(width: 240, height: 80)
}
