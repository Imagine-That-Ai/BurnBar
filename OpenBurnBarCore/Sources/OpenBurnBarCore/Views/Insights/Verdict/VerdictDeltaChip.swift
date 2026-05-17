import SwiftUI

/// A small mono delta chip rendered next to numbers and bullet claims.
///
/// The chip color is driven by the delta's `isFavorable` computed property
/// (which already knows whether the metric's direction is
/// higher-is-better or lower-is-better). Neutral deltas render in a calm
/// secondary tone — never warning or success.
public struct VerdictDeltaChip: View {

    public var delta: VerdictDelta
    public var compact: Bool

    public init(delta: VerdictDelta, compact: Bool = false) {
        self.delta = delta
        self.compact = compact
    }

    public var body: some View {
        HStack(spacing: 2) {
            Image(systemName: glyph)
                .font(.system(size: compact ? 8 : 10, weight: .bold))
            Text(label)
                .font(compact
                      ? UnifiedDesignSystem.Typography.monoTiny
                      : UnifiedDesignSystem.Typography.monoSmall)
            if !compact {
                Text(delta.baseline)
                    .font(UnifiedDesignSystem.Typography.tiny)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
            }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, compact ? 4 : UnifiedDesignSystem.Spacing.xs)
        .padding(.vertical, compact ? 1 : 2)
        .background(
            Capsule().fill(tint.opacity(0.12))
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var glyph: String {
        if delta.value == 0 { return "minus" }
        return delta.value > 0 ? "arrow.up" : "arrow.down"
    }

    private var label: String {
        let mag = abs(delta.value)
        switch delta.unit {
        case .percent:
            return "\(Int(mag.rounded()))%"
        case .usd:
            return "$\(String(format: "%.2f", mag))"
        case .tokens:
            return InsightFormatting.tokensFormatter(mag)
        case .sessions, .count:
            return "\(Int(mag.rounded()))"
        case .days:
            return "\(Int(mag.rounded()))d"
        case .milliseconds:
            return "\(Int(mag.rounded()))ms"
        case .ratio:
            return String(format: "%.2fx", mag)
        }
    }

    private var tint: Color {
        switch (delta.direction, delta.value.sign) {
        case (.neutral, _): return UnifiedDesignSystem.Colors.textSecondary
        case _ where delta.value == 0: return UnifiedDesignSystem.Colors.textSecondary
        case _ where delta.isFavorable: return UnifiedDesignSystem.Colors.success
        default: return UnifiedDesignSystem.Colors.error
        }
    }

    private var accessibilityLabel: String {
        let directionWord: String
        if delta.value == 0 {
            directionWord = "unchanged"
        } else if delta.value > 0 {
            directionWord = "up"
        } else {
            directionWord = "down"
        }
        return "\(directionWord) \(label) \(delta.baseline)"
    }
}
