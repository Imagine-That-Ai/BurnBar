import SwiftUI

// MARK: - Hermes Thinking View

/// Three mercury droplets that pool and separate like liquid metal.
/// Shown when Hermes is streaming but no text has arrived yet.
struct HermesThinkingView: View {
    var body: some View {
        HStack(spacing: 5) {
            MercuryDroplet(delay: 0.0)
            MercuryDroplet(delay: 0.3)
            MercuryDroplet(delay: 0.6)
        }
        .padding(.horizontal, DesignSystem.Spacing.lg)
        .padding(.vertical, DesignSystem.Spacing.md)
    }
}

// MARK: - Mercury Droplet

private struct MercuryDroplet: View {
    let delay: Double

    @State private var phase: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(DesignSystem.Colors.mercuryGradient)
            .frame(width: 8, height: 8)
            .scaleEffect(scaleForPhase(phase))
            .offset(y: offsetForPhase(phase))
            .opacity(opacityForPhase(phase))
            .animation(
                reduceMotion
                    ? nil
                    : .linear(duration: 1.8)
                        .repeatForever(autoreverses: false)
                        .delay(delay),
                value: phase
            )
            .onAppear {
                if !reduceMotion { phase = 1 }
            }
    }

    private func scaleForPhase(_ p: CGFloat) -> CGFloat {
        // 0→0.17: 1→1.4, 0.17→0.33: 1.4→0.8, 0.33→1.0: 0.8→1
        if p < 0.17 { return 1.0 + (p / 0.17) * 0.4 }
        if p < 0.33 { return 1.4 - ((p - 0.17) / 0.16) * 0.6 }
        return 0.8 + ((p - 0.33) / 0.67) * 0.2
    }

    private func offsetForPhase(_ p: CGFloat) -> CGFloat {
        if p < 0.17 { return 0 }
        if p < 0.33 { return -2.0 * ((p - 0.17) / 0.16) }
        if p < 0.5 { return -2.0 + ((p - 0.33) / 0.17) * 3.0 }
        return 1.0 - ((p - 0.5) / 0.5) * 1.0
    }

    private func opacityForPhase(_ p: CGFloat) -> Double {
        if p < 0.17 { return 0.5 + (p / 0.17) * 0.5 }
        if p < 0.33 { return 1.0 - ((p - 0.17) / 0.16) * 0.4 }
        return 0.6 - ((p - 0.33) / 0.67) * 0.1
    }
}
