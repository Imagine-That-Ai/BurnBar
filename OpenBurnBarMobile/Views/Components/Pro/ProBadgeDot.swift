import SwiftUI
import OpenBurnBarCore

// MARK: - Pro Badge Dot
//
// Pro vocabulary — the whisper. A 6pt foil dot with subtle 2.4s breathing
// opacity for free users. Lives on persistent surfaces (nav tray "You" tab,
// sidebar user row, FAB corner) so the presence of Pro is never invisible
// without being intrusive. Honors `accessibilityReduceMotion` — the dot is
// static in reduced-motion contexts.

struct ProBadgeDot: View {
    enum Pulse {
        case breathing  // Free user — 0.6 → 1.0 opacity loop.
        case still      // Static contexts.
    }

    var pulse: Pulse = .breathing
    var diameter: CGFloat = ProTheme.Layout.badgeDot

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bright = false

    var body: some View {
        Circle()
            .fill(UnifiedDesignSystem.mercuryGradient)
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

// MARK: - Preview

#Preview("Pro Badge Dot") {
    ZStack {
        ProTheme.Palette.obsidian.ignoresSafeArea()
        HStack(spacing: 24) {
            ProBadgeDot(pulse: .breathing)
            ProBadgeDot(pulse: .breathing, diameter: 8)
            ProBadgeDot(pulse: .still)
        }
    }
}
