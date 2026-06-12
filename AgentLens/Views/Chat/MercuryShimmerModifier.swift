import SwiftUI

// MARK: - Mercury Shimmer

/// Sweeping translucent highlight band that travels across a view.
/// Uses `TimelineView` with pause control for zero GPU cost when inactive.
struct MercuryShimmerModifier: ViewModifier {
    var active: Bool

    func body(content: Content) -> some View {
        content.overlay {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !active)) { ctx in
                let phase = active
                    ? ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3.0) / 3.0
                    : 0

                GeometryReader { geo in
                    let bandWidth = geo.size.width * 0.35
                    let travel = geo.size.width + bandWidth
                    let offset = travel * CGFloat(phase) - bandWidth

                    Rectangle()
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0),
                                    .init(color: .white.opacity(0.15), location: 0.3),
                                    .init(color: .white.opacity(0.25), location: 0.5),
                                    .init(color: .white.opacity(0.15), location: 0.7),
                                    .init(color: .clear, location: 1)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: bandWidth)
                        .offset(x: offset)
                        .opacity(active ? 1 : 0)
                }
                .allowsHitTesting(false)
            }
        }
    }
}

extension View {
    /// Applies a mercury shimmer highlight sweep. Pauses when `active` is false.
    func mercuryShimmer(active: Bool = true) -> some View {
        modifier(MercuryShimmerModifier(active: active))
            .clipped()
    }
}
