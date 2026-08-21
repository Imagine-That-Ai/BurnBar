import SwiftUI
import OpenBurnBarInsights
import OpenBurnBarRecap

// MARK: - Reveal
//
// Cards rise into place as they scroll in. The whole system has one job beyond
// looking good: make a long deck feel paced rather than dumped.
//
// Every effect here has a Reduce Motion branch that degrades to a plain fade —
// "springs become fades, stagger becomes simultaneous", which is the bar this
// repo already holds its animations to.

/// Fires `onReveal` the first time the view becomes visible in its scroll view,
/// falling back to `onAppear` on systems without scroll visibility callbacks.
private struct RecapVisibilityTrigger: ViewModifier {
    let onReveal: () -> Void

    func body(content: Content) -> some View {
        if #available(macOS 15, iOS 18, *) {
            content.onScrollVisibilityChange(threshold: 0.05) { visible in
                if visible { onReveal() }
            }
        } else {
            content.onAppear(perform: onReveal)
        }
    }
}

/// Staggered entrance for one card.
public struct RecapReveal: ViewModifier {
    /// Position within its row — drives the stagger so a row arrives as a row,
    /// not as three unrelated events.
    public let indexInRow: Int

    @State private var revealed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(indexInRow: Int) {
        self.indexInRow = indexInRow
    }

    private var delay: Double {
        reduceMotion ? 0 : min(Double(indexInRow) * 0.06, 0.24)
    }

    public func body(content: Content) -> some View {
        content
            .opacity(revealed ? 1 : 0)
            .offset(y: reduceMotion ? 0 : (revealed ? 0 : 22))
            .scaleEffect(reduceMotion ? 1 : (revealed ? 1 : 0.97), anchor: .top)
            .animation(
                reduceMotion
                    ? .easeOut(duration: 0.22)
                    : UnifiedDesignSystem.Animation.gentle.delay(delay),
                value: revealed
            )
            .modifier(RecapVisibilityTrigger { revealed = true })
    }
}

/// Subtle vertical parallax for full-bleed moments.
///
/// Uses `visualEffect`, which reads geometry without wrapping the content in a
/// `GeometryReader` — the wrapper would take the card's layout over from it.
public struct RecapParallax: ViewModifier {
    public let magnitude: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(magnitude: CGFloat = 14) {
        self.magnitude = magnitude
    }

    public func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.visualEffect { effect, proxy in
                let midpoint = proxy.frame(in: .scrollView).midY
                let height = max(proxy.size.height, 1)
                // -1…1 as the card travels through the viewport.
                let progress = max(-1, min(1, midpoint / (height * 3)))
                return effect.offset(y: progress * magnitude)
            }
        }
    }
}

// MARK: - Count-up

/// A numeral that counts up to its value once, the first time it appears.
///
/// The text content itself changes as `displayed` animates, which is what lets
/// `contentTransition(.numericText())` roll the digits rather than crossfade
/// them. Paired with the monospaced-digit fonts in `RecapTheme` so a rolling
/// number cannot reflow the card around it.
public struct RecapAnimatedNumeral: View {
    public let value: Double
    public let unit: RecapMetricUnit
    public let font: Font
    public let fill: LinearGradient

    @State private var displayed: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(value: Double, unit: RecapMetricUnit, font: Font, fill: LinearGradient) {
        self.value = value
        self.unit = unit
        self.font = font
        self.fill = fill
    }

    public var body: some View {
        Text(RecapMetric.format(displayed, unit))
            .font(font)
            .foregroundStyle(fill)
            .contentTransition(.numericText(value: displayed))
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .onAppear {
                guard !reduceMotion else {
                    displayed = value
                    return
                }
                withAnimation(.easeOut(duration: 0.9)) { displayed = value }
            }
            .accessibilityHidden(true)
    }
}

public extension View {
    func recapReveal(indexInRow: Int = 0) -> some View {
        modifier(RecapReveal(indexInRow: indexInRow))
    }

    func recapParallax(magnitude: CGFloat = 14) -> some View {
        modifier(RecapParallax(magnitude: magnitude))
    }
}
