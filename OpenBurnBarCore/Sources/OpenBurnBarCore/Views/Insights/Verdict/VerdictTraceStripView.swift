import SwiftUI

/// Vercel-style horizontal flame strip rendered under the verdict hero.
///
/// Plan §3.6 — yesterday's session-trace strip is one of the three
/// always-above-the-fold elements. The strip is at-a-glance: lanes by
/// kind (model/tool/cache/prompt/response/retry), a thin axis with cost
/// ticks, and a `summary` caption to the right. Tap opens the full
/// session trace view.
public struct VerdictTraceStripView: View {

    public var strip: VerdictTraceStrip
    public var onTapSession: ((String) -> Void)?

    public init(
        strip: VerdictTraceStrip,
        onTapSession: ((String) -> Void)? = nil
    ) {
        self.strip = strip
        self.onTapSession = onTapSession
    }

    public var body: some View {
        Button(action: { onTapSession?(strip.sessionID) }) {
            HStack(alignment: .top, spacing: UnifiedDesignSystem.Spacing.md) {
                lanesColumn
                summaryColumn
            }
            .padding(.vertical, UnifiedDesignSystem.Spacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens the full session trace.")
    }

    @ViewBuilder
    private var lanesColumn: some View {
        GeometryReader { geo in
            VStack(spacing: 3) {
                ForEach(strip.lanes) { lane in
                    laneRow(lane, width: geo.size.width)
                }
                axisRow(width: geo.size.width)
            }
        }
        .frame(minHeight: 78, idealHeight: 78)
    }

    private func laneRow(_ lane: TraceLane, width: CGFloat) -> some View {
        let total = max(strip.duration, 0.001)
        let leading = CGFloat(lane.startOffset / total) * width
        let widthValue = max(CGFloat(lane.duration / total) * width, 2)
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(UnifiedDesignSystem.Colors.borderSubtle.opacity(0.5))
                .frame(height: 9)
            RoundedRectangle(cornerRadius: 2)
                .fill(lane.tint.color.opacity(0.85))
                .frame(width: widthValue, height: 9)
                .offset(x: leading)
        }
        .overlay(alignment: .leading) {
            Text(lane.label)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                .padding(.leading, 2)
                .offset(y: -10)
                .opacity(0.0)
                // Lane label is provided to accessibility but visually subordinate.
        }
    }

    private func axisRow(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(UnifiedDesignSystem.Colors.border.opacity(0.4))
                .frame(height: 0.5)
            ForEach(strip.ticks) { tick in
                tickGlyph(for: tick, width: width)
            }
        }
        .frame(height: 14)
    }

    private func tickGlyph(for tick: TraceTick, width: CGFloat) -> some View {
        let total = max(strip.duration, 0.001)
        let x = CGFloat(tick.offset / total) * width
        return VStack(spacing: 1) {
            Rectangle()
                .fill(UnifiedDesignSystem.Colors.textSecondary)
                .frame(width: 1, height: 5)
            if let label = tick.label {
                Text(label)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                    .lineLimit(1)
            }
        }
        .offset(x: max(0, x - 0.5))
    }

    @ViewBuilder
    private var summaryColumn: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(strip.summary)
                .font(UnifiedDesignSystem.Typography.caption)
                .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
            HStack(spacing: UnifiedDesignSystem.Spacing.xs) {
                Text("$\(String(format: "%.2f", strip.costUSD))")
                    .font(UnifiedDesignSystem.Typography.monoSmall)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                if strip.didTimeout {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(UnifiedDesignSystem.Colors.warning)
                }
            }
            Text(timeLabel)
                .font(UnifiedDesignSystem.Typography.tiny)
                .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
        }
        .frame(maxWidth: 140, alignment: .trailing)
    }

    private var timeLabel: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let start = formatter.string(from: strip.startedAt)
        let end = formatter.string(from: strip.endedAt)
        return "\(start) → \(end)"
    }

    private var accessibilityLabel: String {
        var parts: [String] = ["Session trace."]
        parts.append("Summary: \(strip.summary)")
        parts.append("Cost $\(String(format: "%.2f", strip.costUSD)).")
        parts.append("\(Int(strip.duration / 60)) minutes.")
        if strip.didTimeout { parts.append("Ended in timeout.") }
        parts.append("\(strip.lanes.count) lanes.")
        return parts.joined(separator: " ")
    }
}
