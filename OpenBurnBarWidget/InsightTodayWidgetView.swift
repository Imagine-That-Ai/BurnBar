import SwiftUI
import WidgetKit
import OpenBurnBarCore

struct InsightTodayWidgetView: View {
    var entry: InsightTodayWidgetEntry

    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        Group {
            switch family {
            case .systemSmall:
                InsightSmallView(snap: entry.snapshot)
            case .systemMedium:
                InsightMediumView(snap: entry.snapshot)
            case .systemLarge:
                InsightLargeView(snap: entry.snapshot)
            case .accessoryRectangular:
                InsightRectangularView(snap: entry.snapshot)
            case .accessoryCircular:
                InsightCircularView(snap: entry.snapshot)
            case .accessoryInline:
                InsightInlineView(snap: entry.snapshot)
            default:
                InsightSmallView(snap: entry.snapshot)
            }
        }
        .widgetURL(URL(string: "burnbar://insights/today"))
    }
}

// MARK: - Small (2x2)

struct InsightSmallView: View {
    var snap: InsightVerdictWidgetSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(snap?.windowLabel ?? "Insights")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(snap?.headline ?? "No data yet")
                .font(.caption)
                .lineLimit(3)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                if let snap = snap {
                    RingProgressView(
                        progress: min(1, snap.spendCurrent / max(1, snap.spendTarget)),
                        color: .orange
                    )
                    .frame(width: 18, height: 18)
                    RingProgressView(
                        progress: min(1, snap.cacheCurrent / max(1, snap.cacheTarget)),
                        color: .green
                    )
                    .frame(width: 18, height: 18)
                }
            }
        }
        .padding(8)
        .containerBackground(.clear, for: .widget)
    }
}

// MARK: - Medium (4x2)

struct InsightMediumView: View {
    var snap: InsightVerdictWidgetSnapshot?

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(snap?.windowLabel ?? "Insights")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(snap?.headline ?? "No data yet")
                    .font(.subheadline)
                    .lineLimit(2)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let snap = snap {
                VStack(spacing: 6) {
                    RingRow(label: "Spend", value: snap.spendCurrent, target: snap.spendTarget, color: .orange)
                    RingRow(label: "Cache", value: snap.cacheCurrent, target: snap.cacheTarget, color: .green)
                    RingRow(label: "Sessions", value: Double(snap.sessionsCurrent), target: Double(snap.sessionsTarget), color: .blue)
                }
                .frame(width: 100)
            }
        }
        .padding(12)
        .containerBackground(.clear, for: .widget)
    }
}

// MARK: - Large (4x4)

struct InsightLargeView: View {
    var snap: InsightVerdictWidgetSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(snap?.windowLabel ?? "Insights")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(snap?.headline ?? "No data yet")
                .font(.headline)
                .lineLimit(2)
                .foregroundStyle(.primary)

            if let snap = snap {
                HStack(spacing: 16) {
                    VStack(spacing: 8) {
                        RingProgressView(progress: min(1, snap.spendCurrent / max(1, snap.spendTarget)), color: .orange)
                            .frame(height: 60)
                        Text("$\(String(format: "%.2f", snap.spendCurrent))")
                            .font(.caption)
                    }
                    VStack(spacing: 8) {
                        RingProgressView(progress: min(1, snap.cacheCurrent / max(1, snap.cacheTarget)), color: .green)
                            .frame(height: 60)
                        Text("\(Int(snap.cacheCurrent))%")
                            .font(.caption)
                    }
                    VStack(spacing: 8) {
                        RingProgressView(progress: min(1, Double(snap.sessionsCurrent) / max(1, Double(snap.sessionsTarget))), color: .blue)
                            .frame(height: 60)
                        Text("\(snap.sessionsCurrent)")
                            .font(.caption)
                    }
                }
                .frame(maxWidth: .infinity)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .containerBackground(.clear, for: .widget)
    }
}

// MARK: - Lock Screen / Accessory

struct InsightRectangularView: View {
    var snap: InsightVerdictWidgetSnapshot?

    var body: some View {
        HStack(spacing: 8) {
            if let snap = snap {
                RingProgressView(progress: min(1, snap.spendCurrent / max(1, snap.spendTarget)), color: .orange)
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(snap.windowLabel)
                        .font(.system(size: 10, weight: .semibold))
                    Text(snap.headline)
                        .font(.system(size: 10))
                        .lineLimit(1)
                }
            } else {
                Text("OpenBurnBar Insights")
                    .font(.system(size: 12))
            }
        }
    }
}

struct InsightCircularView: View {
    var snap: InsightVerdictWidgetSnapshot?

    var body: some View {
        if let snap = snap {
            RingProgressView(progress: min(1, snap.spendCurrent / max(1, snap.spendTarget)), color: .orange)
        } else {
            Image(systemName: "sparkles")
        }
    }
}

struct InsightInlineView: View {
    var snap: InsightVerdictWidgetSnapshot?

    var body: some View {
        if let snap = snap {
            Text("\(snap.windowLabel): $\(String(format: "%.2f", snap.spendCurrent))")
        } else {
            Text("BurnBar Insights")
        }
    }
}

// MARK: - Ring helpers

struct RingProgressView: View {
    var progress: Double
    var color: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.2), lineWidth: 4)
            Circle()
                .trim(from: 0, to: CGFloat(min(progress, 1.0)))
                .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

struct RingRow: View {
    var label: String
    var value: Double
    var target: Double
    var color: Color

    var body: some View {
        HStack(spacing: 6) {
            RingProgressView(
                progress: min(1, value / max(1, target)),
                color: color
            )
            .frame(width: 14, height: 14)
            Text(label)
                .font(.system(size: 10))
            Spacer(minLength: 0)
            Text(formattedValue)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
        }
    }

    private var formattedValue: String {
        if label == "Spend" {
            return "\(String(format: "%.2f", value))"
        } else if label == "Cache" {
            return "\(Int(value))%"
        } else {
            return "\(Int(value))"
        }
    }
}
