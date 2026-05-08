import SwiftUI
import Charts
import OpenBurnBarCore

// MARK: - Model Lane Scene
//
// "Lane Racer" view of the top 5 models. Each lane shows:
//   · model emblem color stripe
//   · animated bar that fills proportionally
//   · embedded sparkline of that model's daily share
//   · tok/s velocity badge on the right
// Designed to feel like a horse-race scoreboard, not a dry table.

struct ModelLaneScene: View {
    let digest: TrendDataDigest
    let displayMode: UsageDisplayMode

    private var lanes: [Lane] {
        let topN = digest.models.prefix(5)
        let max = topN.first?.tokens ?? 1
        return topN.map { m in
            let velocity = velocityFor(model: m.model)
            let series = sparklineFor(model: m.model)
            let progress = max > 0 ? min(1.0, Double(m.tokens) / Double(max)) : 0
            return Lane(
                model: m.model,
                provider: m.provider,
                share: m.sharePct,
                cost: m.costUsd,
                tokens: m.tokens,
                progress: progress,
                velocity: velocity,
                sparkline: series,
                color: paletteColor(for: m.model)
            )
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            if lanes.isEmpty {
                AuroraLoadingShimmer(height: 200, cornerRadius: 12)
            } else {
                ForEach(lanes, id: \.model) { lane in
                    LaneRow(lane: lane, displayMode: displayMode)
                }
            }
        }
    }

    // MARK: - Per-model sparkline

    private func sparklineFor(model: String) -> [Double] {
        // Sum tokens by day for sessions that used this model.
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        var byDay: [String: Double] = [:]
        for s in digest.recentSessions where s.model == model {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let date = iso.date(from: s.startedAt)
                ?? ISO8601DateFormatter().date(from: s.startedAt)
                ?? Date()
            let key = formatter.string(from: date)
            byDay[key, default: 0] += Double(s.outputTokens)
        }
        let sortedKeys = byDay.keys.sorted()
        let values = sortedKeys.map { byDay[$0] ?? 0 }
        return values.suffix(14).map { $0 }
    }

    private func velocityFor(model: String) -> Double {
        let sessions = digest.recentSessions.filter { $0.model == model }
        guard !sessions.isEmpty else { return 0 }
        let avg = sessions.reduce(0.0) { $0 + $1.outputTokensPerSecond } / Double(sessions.count)
        return avg
    }

    private func paletteColor(for model: String) -> Color {
        MobileTheme.Colors.colorForModel(model)
    }

    // MARK: - Lane

    fileprivate struct Lane: Identifiable {
        let model: String
        let provider: String
        let share: Double
        let cost: Double
        let tokens: Int
        let progress: Double
        let velocity: Double
        let sparkline: [Double]
        let color: Color

        var id: String { model }
    }
}

// MARK: - Single Lane Row

private struct LaneRow: View {
    let lane: ModelLaneScene.Lane
    let displayMode: UsageDisplayMode

    @State private var animatedProgress: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            // Color rail
            Capsule()
                .fill(lane.color)
                .frame(width: 4, height: 36)
                .shadow(color: lane.color.opacity(0.55), radius: 6)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(lane.model)
                        .font(MobileTheme.Typography.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                        .lineLimit(1)
                    Text(lane.provider)
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text("\(Int(lane.share))%")
                        .font(MobileTheme.Typography.tiny)
                        .fontWeight(.semibold)
                        .foregroundStyle(lane.color)
                        .monospacedDigit()
                }

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(lane.color.opacity(0.14))
                        .frame(height: 8)
                    GeometryReader { geo in
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [lane.color, lane.color.opacity(0.6)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: max(4, geo.size.width * animatedProgress), height: 8)
                    }
                    .frame(height: 8)
                    if lane.sparkline.count > 1 {
                        EmberSparkline(values: lane.sparkline, lineWidth: 1.0, fillOpacity: 0.20)
                            .frame(height: 8)
                            .blendMode(.plusLighter)
                            .opacity(0.65)
                            .allowsHitTesting(false)
                    }
                }

                HStack(spacing: 8) {
                    if lane.velocity > 0 {
                        Label("\(Int(lane.velocity)) tok/s", systemImage: "hare.fill")
                            .font(MobileTheme.Typography.tiny)
                            .foregroundStyle(MobileTheme.amber)
                    }
                    Spacer(minLength: 0)
                    Text(displayMode == .currency ? lane.cost.formatAsCost() : lane.tokens.formatAsTokenVolume())
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                        .monospacedDigit()
                }
            }
        }
        .padding(.vertical, 4)
        .onAppear {
            if reduceMotion {
                animatedProgress = CGFloat(lane.progress)
            } else {
                withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                    animatedProgress = CGFloat(lane.progress)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(lane.model), \(Int(lane.share)) percent share, \(lane.cost.formatAsCost())")
    }
}
