import SwiftUI

/// The three-ring strip rendered immediately under the verdict hero.
///
/// Mirrors the Apple Activity rings — each ring has a stroke that wraps
/// past 1.0 when over-target. Voice contract §3.6 — these three rings are
/// the "peripheral vision" of the surface: a user walking past their
/// laptop should be able to read whether today is on track without
/// stopping to read the headline.
public struct VerdictRingsStrip: View {

    public var rings: [VerdictRing]
    public var compact: Bool
    public var onRingTap: ((VerdictRing) -> Void)?

    public init(
        rings: [VerdictRing],
        compact: Bool = false,
        onRingTap: ((VerdictRing) -> Void)? = nil
    ) {
        self.rings = rings
        self.compact = compact
        self.onRingTap = onRingTap
    }

    public var body: some View {
        HStack(spacing: compact ? UnifiedDesignSystem.Spacing.md
                                : UnifiedDesignSystem.Spacing.xl) {
            ForEach(rings) { ring in
                ringCell(ring)
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func ringCell(_ ring: VerdictRing) -> some View {
        let stack = HStack(spacing: UnifiedDesignSystem.Spacing.sm) {
            VerdictRingView(ring: ring, compact: compact)
            if !compact {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ring.label)
                        .font(UnifiedDesignSystem.Typography.tiny)
                        .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                        .textCase(.uppercase)
                    Text(ring.valueLabel)
                        .font(UnifiedDesignSystem.Typography.monoSmall)
                        .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                    if let delta = ring.delta {
                        VerdictDeltaChip(delta: delta, compact: true)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .accessibilityLabel(accessibilityLabel(for: ring))
        if let onRingTap {
            Button(action: { onRingTap(ring) }, label: { stack })
                .buttonStyle(.plain)
        } else {
            stack
        }
    }

    private func accessibilityLabel(for ring: VerdictRing) -> String {
        var parts: [String] = ["\(ring.label) ring."]
        parts.append(ring.valueLabel.replacingOccurrences(of: "/", with: " of "))
        if let delta = ring.delta {
            parts.append(deltaDescription(delta))
        }
        if ring.isNearCap {
            parts.append("Near cap.")
        }
        return parts.joined(separator: " ")
    }

    private func deltaDescription(_ delta: VerdictDelta) -> String {
        let direction = delta.value == 0 ? "unchanged"
                      : delta.value > 0 ? "up" : "down"
        return "\(direction) \(Int(abs(delta.value).rounded()))% \(delta.baseline)."
    }
}

/// A single Activity-style ring.
private struct VerdictRingView: View {
    let ring: VerdictRing
    let compact: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let strokeWidth: CGFloat = compact ? 6 : 9
        let dimension: CGFloat = compact ? 38 : 56
        ZStack {
            Circle()
                .stroke(strokeColor.opacity(0.15), lineWidth: strokeWidth)
            Circle()
                .trim(from: 0, to: min(ring.progress, 1.0))
                .stroke(strokeColor,
                        style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil
                           : UnifiedDesignSystem.Animation.standard,
                           value: ring.progress)
            // Wrap-around: paint the over-target portion in the wrap tint.
            if ring.progress > 1.0 {
                Circle()
                    .trim(from: 0, to: min(ring.progress - 1.0, 0.5))
                    .stroke(wrapColor,
                            style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: dimension, height: dimension)
        .modifier(NearCapPulse(isNearCap: ring.isNearCap, reduceMotion: reduceMotion))
    }

    private var strokeColor: Color {
        ring.tint.color
    }

    private var wrapColor: Color {
        ring.tint.color.opacity(0.6)
    }
}

private struct NearCapPulse: ViewModifier {
    let isNearCap: Bool
    let reduceMotion: Bool
    @State private var pulse = false

    func body(content: Content) -> some View {
        if isNearCap && !reduceMotion {
            content
                .scaleEffect(pulse ? 1.04 : 1.0)
                .onAppear {
                    withAnimation(UnifiedDesignSystem.Animation.mercuryPulse) {
                        pulse = true
                    }
                }
        } else {
            content
        }
    }
}

extension ProviderTint {
    /// SwiftUI color mapped from the schema-level tint identity.
    public var color: Color {
        switch self {
        case .ember: return UnifiedDesignSystem.Colors.ember
        case .whimsy: return UnifiedDesignSystem.Colors.whimsy
        case .silver: return UnifiedDesignSystem.Colors.hermesMercury
        case .mercury: return UnifiedDesignSystem.Colors.hermesMercury
        case .prism: return UnifiedDesignSystem.Colors.whimsy
        case .ember2: return UnifiedDesignSystem.Colors.amber
        case .neutral: return UnifiedDesignSystem.Colors.textSecondary
        }
    }
}
