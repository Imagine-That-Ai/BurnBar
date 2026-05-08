import SwiftUI
import OpenBurnBarCore

// MARK: - Flame Refresh Indicator

/// A branded flame-arc spinner shown during pull-to-refresh.
/// Uses an ember-tinted arc that rotates and pulses.
struct FlameRefreshIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotation = 0.0
    @State private var pulsePhase = 0.0

    var body: some View {
        ZStack {
            // Outer arc
            ArcShape(startAngle: .degrees(0), endAngle: .degrees(270))
                .stroke(
                    AngularGradient(
                        colors: [
                            UnifiedDesignSystem.Colors.ember.opacity(0.0),
                            UnifiedDesignSystem.Colors.ember,
                            UnifiedDesignSystem.Colors.amber,
                            UnifiedDesignSystem.Colors.ember.opacity(0.0)
                        ],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
                .frame(width: 24, height: 24)
                .rotationEffect(.degrees(rotation))

            // Inner dot
            Circle()
                .fill(UnifiedDesignSystem.Colors.amber)
                .frame(width: 6, height: 6)
                .scaleEffect(1.0 + 0.3 * sin(pulsePhase))
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                rotation = 360
            }
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                pulsePhase = .pi * 2
            }
        }
    }
}

// MARK: - Arc Shape

private struct ArcShape: Shape {
    var startAngle: Angle
    var endAngle: Angle

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        path.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: false)
        return path
    }
}

#Preview {
    FlameRefreshIndicator()
        .padding()
        .background(UnifiedDesignSystem.Colors.background)
}
