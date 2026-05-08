import SwiftUI
import OpenBurnBarCore

// MARK: - Mercury Thinking Indicator

/// Three droplets that pool and separate — replaces the old 3-dot pulse.
/// 1.8s cycle, 0.3s stagger per droplet.
struct MercuryThinkingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = 0.0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { index in
                MercuryDroplet(index: index, phase: phase)
            }
        }
        .padding(MobileTheme.Spacing.md)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 1.8).repeatForever(autoreverses: false)) {
                phase = .pi * 2
            }
        }
    }
}

// MARK: - Mercury Droplet

private struct MercuryDroplet: View {
    let index: Int
    let phase: Double

    private var dropletPhase: Double {
        phase + Double(index) * 0.3
    }

    private var scale: CGFloat {
        1.0 + 0.25 * sin(dropletPhase)
    }

    private var opacity: Double {
        0.5 + 0.5 * sin(dropletPhase)
    }

    private var horizontalOffset: CGFloat {
        CGFloat(sin(dropletPhase * 0.5)) * 3
    }

    var body: some View {
        Circle()
            .fill(mercuryGradient)
            .frame(width: 10, height: 10)
            .scaleEffect(scale)
            .opacity(opacity)
            .offset(x: horizontalOffset)
    }

    private var mercuryGradient: LinearGradient {
        LinearGradient(
            colors: [
                UnifiedDesignSystem.Colors.hermesMercury,
                UnifiedDesignSystem.Colors.hermesAureate
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - Preview

#Preview {
    MercuryThinkingIndicator()
        .padding()
        .background(UnifiedDesignSystem.Colors.background)
}
