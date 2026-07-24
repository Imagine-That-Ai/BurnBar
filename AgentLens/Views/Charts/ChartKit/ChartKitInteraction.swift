import SwiftUI

// MARK: - ChartKit · Interaction
//
// Shared pointer-interaction chrome for the ChartKit renderers: the floating
// value tooltip, the readout-caption style, and index-snapping math. All
// interaction is hover-driven (`onContinuousHover`) — no timers, no gesture
// recognizers, zero cost while the pointer is away, so the page keeps its
// all-day idle discipline.

/// The floating value label that trails the crosshair / hovered element.
struct ChartKitTooltip: View {
    let value: String
    var title: String?
    var accent: Color = DesignSystem.Colors.ember

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(accent)
                .frame(width: 5, height: 5)
            if let title {
                Text(title)
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            Text(value)
                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(DesignSystem.Colors.textPrimary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background {
            Capsule()
                .fill(DesignSystem.Colors.surfaceElevated.opacity(0.96))
        }
        .overlay(
            Capsule().stroke(accent.opacity(0.35), lineWidth: 0.75)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 6, y: 2)
        .fixedSize()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The quiet one-line readout used by dense grids (heatmap) where a floating
/// tooltip would collide with neighbors.
struct ChartKitReadout: View {
    let text: String
    var accent: Color = DesignSystem.Colors.ember

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(accent)
                .frame(width: 5, height: 5)
            Text(text)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityHidden(true)
    }
}

enum ChartKitHover {
    /// Snaps an x-coordinate to the nearest evenly-spaced point index.
    static func pointIndex(atX x: CGFloat, count: Int, width: CGFloat) -> Int {
        guard count > 1, width > 0 else { return 0 }
        let step = width / CGFloat(count - 1)
        return min(count - 1, max(0, Int((x / step).rounded())))
    }

    /// Snaps an x-coordinate to the nearest cell index in `count` columns.
    static func cellIndex(atX x: CGFloat, count: Int, width: CGFloat) -> Int {
        guard count > 0, width > 0 else { return 0 }
        return min(count - 1, max(0, Int(x / width * CGFloat(count))))
    }
}
