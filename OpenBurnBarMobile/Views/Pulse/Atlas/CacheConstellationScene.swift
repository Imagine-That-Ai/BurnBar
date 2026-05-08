import SwiftUI
import Charts
import OpenBurnBarCore

// MARK: - Cache Constellation Scene
//
// Scatter chart of recent sessions where:
//   x = duration (sec)
//   y = cache hit rate (0...1)
//   mark size = cost
//   color = provider primary
// Plus a faint guide curve at 75% (Anthropic's quoted cache savings ceiling).

struct CacheConstellationScene: View {
    let digest: TrendDataDigest

    private var points: [Point] {
        digest.recentSessions.compactMap { s in
            guard s.durationSec > 0 else { return nil }
            return Point(
                id: s.id,
                duration: Double(s.durationSec),
                cacheHit: max(0, min(1, s.cacheHitRate)),
                cost: max(0.0001, s.costUsd),
                provider: s.provider,
                providerKey: s.providerKey,
                model: s.model,
                project: s.project
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            chart
            statsLine
        }
    }

    private var chart: some View {
        Chart {
            // Guide line at 75%
            RuleMark(y: .value("Ideal cache", 0.75))
                .foregroundStyle(MobileTheme.success.opacity(0.45))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .annotation(position: .topLeading, alignment: .leading) {
                    Text("Ideal · 75%")
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.success.opacity(0.7))
                }

            ForEach(points) { p in
                PointMark(
                    x: .value("Duration", p.duration),
                    y: .value("Cache hit rate", p.cacheHit)
                )
                .symbolSize(symbolSize(for: p))
                .foregroundStyle(by: .value("Provider", p.provider))
                .opacity(0.85)
            }

            if !points.isEmpty {
                let avg = points.reduce(0.0) { $0 + $1.cacheHit } / Double(points.count)
                RuleMark(y: .value("Yours", avg))
                    .foregroundStyle(MobileTheme.amber.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    .annotation(position: .bottomTrailing, alignment: .trailing) {
                        Text("Yours · \(Int(avg * 100))%")
                            .font(MobileTheme.Typography.tiny)
                            .foregroundStyle(MobileTheme.amber)
                    }
            }
        }
        .chartForegroundStyleScale(
            domain: providerLegend.map(\.0),
            range: providerLegend.map(\.1)
        )
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(MobileTheme.Colors.border.opacity(0.20))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(formatDuration(v))
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(values: [0, 0.25, 0.5, 0.75, 1.0]) { value in
                AxisGridLine().foregroundStyle(MobileTheme.Colors.border.opacity(0.20))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text("\(Int(v * 100))%")
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                    }
                }
            }
        }
        .frame(height: 200)
    }

    private var statsLine: some View {
        HStack(spacing: 10) {
            statBadge(
                label: "Cache hit",
                value: "\(Int(digest.cache.cacheHitRate * 100))%",
                color: digest.cache.cacheHitRate >= 0.5 ? MobileTheme.success : MobileTheme.warning
            )
            statBadge(
                label: "Cache reads",
                value: digest.cache.totalCacheReadTokens.formatAsTokenVolume(),
                color: MobileTheme.amber
            )
            statBadge(
                label: "Sessions",
                value: "\(points.count)",
                color: MobileTheme.hermesAureate
            )
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }

    private func statBadge(label: String, value: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(value)
                .font(MobileTheme.Typography.tiny)
                .fontWeight(.semibold)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
            Text(label)
                .font(MobileTheme.Typography.tiny)
                .foregroundStyle(MobileTheme.Colors.textMuted)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(MobileTheme.Colors.surface.opacity(0.45))
        )
    }

    private func symbolSize(for point: Point) -> Double {
        let maxCost = points.map(\.cost).max() ?? 1
        let normalized = min(1, point.cost / maxCost)
        return 20 + normalized * 220
    }

    private var providerLegend: [(String, Color)] {
        var seen: Set<String> = []
        var out: [(String, Color)] = []
        for p in points where !seen.contains(p.provider) {
            seen.insert(p.provider)
            let color = AgentProvider.fromPersistedToken(p.providerKey).map(MobileTheme.Colors.primary(for:)) ?? MobileTheme.amber
            out.append((p.provider, color))
        }
        return out
    }

    private func formatDuration(_ seconds: Double) -> String {
        if seconds < 60 { return "\(Int(seconds))s" }
        let m = Int(seconds / 60)
        return "\(m)m"
    }

    fileprivate struct Point: Identifiable {
        let id: String
        let duration: Double
        let cacheHit: Double
        let cost: Double
        let provider: String
        let providerKey: String
        let model: String
        let project: String
    }
}
