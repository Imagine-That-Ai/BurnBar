import AppKit
import SwiftUI

// MARK: - Dashboard Depth Backdrop (macOS)
//
// Secondary aurora layer that sits behind the macOS Dashboard scroll so the
// page reads as a layered scene instead of a flat plate of cards. Mirrors
// `PulseDepthBackdrop` on iOS / Android — five slowly drifting brand-tinted
// halos that anchor the hero band, the lanes, and the activity tail.
//
// Decorative only — `allowsHitTesting(false)` everywhere. Respects
// Reduce Motion (drift becomes static) and Reduce Transparency (drops to a
// single low-opacity tint plane).

struct DashboardDepthBackdrop: View {

    var density: Density = .full

    @State private var phase: CGFloat = 0
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    enum Density { case full, subtle }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                halo(
                    color: DesignSystem.Colors.ember,
                    size: max(w * 0.62, 520),
                    blur: 90,
                    intensity: colorScheme == .dark ? 0.36 : 0.22,
                    offset: CGSize(
                        width: -w * 0.20 + drift(amount: 22, freq: 1.0),
                        height: -h * 0.18 + drift(amount: 14, freq: 0.7)
                    )
                )
                halo(
                    color: DesignSystem.Colors.amber,
                    size: max(w * 0.56, 460),
                    blur: 100,
                    intensity: colorScheme == .dark ? 0.30 : 0.16,
                    offset: CGSize(
                        width: w * 0.32 + drift(amount: -24, freq: 0.6),
                        height: -h * 0.04 + drift(amount: 18, freq: 1.3)
                    )
                )
                halo(
                    color: DesignSystem.Colors.whimsy,
                    size: max(w * 0.54, 420),
                    blur: 110,
                    intensity: colorScheme == .dark ? 0.22 : 0.12,
                    offset: CGSize(
                        width: -w * 0.22 + drift(amount: 26, freq: 0.9),
                        height: h * 0.20 + drift(amount: -22, freq: 0.5)
                    )
                )
                halo(
                    color: DesignSystem.Colors.hermesMercury,
                    size: max(w * 0.50, 380),
                    blur: 100,
                    intensity: colorScheme == .dark ? 0.20 : 0.10,
                    offset: CGSize(
                        width: w * 0.28 + drift(amount: -18, freq: 0.8),
                        height: h * 0.36 + drift(amount: 22, freq: 0.4)
                    )
                )
                halo(
                    color: DesignSystem.Colors.blaze,
                    size: max(w * 0.60, 460),
                    blur: 120,
                    intensity: colorScheme == .dark ? 0.18 : 0.08,
                    offset: CGSize(
                        width: -w * 0.04 + drift(amount: 14, freq: 1.1),
                        height: h * 0.48 + drift(amount: -14, freq: 0.7)
                    )
                )
            }
            .frame(width: w, height: h, alignment: .topLeading)
            .blendMode(.plusLighter)
            .opacity(reduceTransparency ? 0.55 : (density == .full ? 1.0 : 0.6))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { startAnimating() }
        .onChange(of: reduceMotion) { _, _ in startAnimating() }
    }

    private func halo(color: Color, size: CGFloat, blur: CGFloat, intensity: Double, offset: CGSize) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        color.opacity(intensity),
                        color.opacity(intensity * 0.35),
                        Color.clear
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: size * 0.55
                )
            )
            .frame(width: size, height: size)
            .blur(radius: blur)
            .offset(offset)
    }

    private func drift(amount: CGFloat, freq: CGFloat) -> CGFloat {
        guard !reduceMotion else { return 0 }
        let theta = phase * .pi * 2 * freq
        return CGFloat(sin(theta)) * amount
    }

    private func startAnimating() {
        guard !reduceMotion else { phase = 0; return }
        withAnimation(.linear(duration: 22).repeatForever(autoreverses: false)) {
            phase = 1
        }
    }
}
