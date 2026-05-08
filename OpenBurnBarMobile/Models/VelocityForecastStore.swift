import Foundation
import OpenBurnBarCore

// MARK: - Velocity Forecast
//
// Produces a projected end-of-day spend / token estimate from the existing
// rollup signals plus today's runtime. Pure math kept in a value-type
// `VelocityForecast` so we can unit-test without spinning a store.

struct VelocityForecast: Equatable, Sendable {
    let projectedCost: Double
    let projectedTokens: Int
    let pace: Pace
    /// `0...1` — fraction of the day already burned at the time of computation.
    let dayProgress: Double

    enum Pace: String, Sendable {
        case ahead
        case onTrack
        case below

        var label: String {
            switch self {
            case .ahead:   return "Ahead of pace"
            case .onTrack: return "On pace"
            case .below:   return "Below pace"
            }
        }

        var icon: String {
            switch self {
            case .ahead:   return "flame.fill"
            case .onTrack: return "gauge.medium"
            case .below:   return "arrow.down.right.circle.fill"
            }
        }
    }
}

enum VelocityForecaster {

    /// Computes a forecast given the current `today` totals and the
    /// trailing 7-day totals. Returns `nil` when both inputs are empty.
    static func forecast(
        todayCost: Double,
        todayTokens: Int,
        sevenDayCost: Double,
        sevenDayTokens: Int,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> VelocityForecast? {
        guard todayCost > 0 || todayTokens > 0 || sevenDayCost > 0 else {
            return nil
        }

        let startOfDay = calendar.startOfDay(for: now)
        let secondsInDay: Double = 86_400
        let elapsed = now.timeIntervalSince(startOfDay)
        let progress = max(0.001, min(1, elapsed / secondsInDay))

        // Blended forecast: mix today's linear extrapolation with the
        // 7-day daily average, weighting today more as the day progresses.
        // This prevents wild projections early in the morning when a single
        // burst session gets divided by a tiny progress fraction.
        let linearCost = todayCost / progress
        let linearTokens = Double(todayTokens) / progress

        let dailyAvgTokens = sevenDayTokens > 0 ? Double(sevenDayTokens) / 7.0 : linearTokens
        let historicalCost = sevenDayCost > 0 ? sevenDayCost / 7.0 : linearCost

        // Sigmoid-ish weight: today's data dominates after ~40% of the day.
        // Before that, lean heavily on the historical average so a 2am burst
        // doesn't claim you'll spend 24× your normal rate.
        let todayWeight = min(1.0, progress * 2.0)  // 0→0, 0.25→0.5, 0.5→1.0
        let projectedCost = linearCost * todayWeight + historicalCost * (1.0 - todayWeight)
        let projectedTokens = Int(linearTokens * todayWeight + dailyAvgTokens * (1.0 - todayWeight))

        // Pace is relative to the 7-day daily average.
        let dailyAvgCost = sevenDayCost / 7.0
        let pace: VelocityForecast.Pace
        if dailyAvgCost <= 0 {
            pace = .onTrack
        } else if projectedCost > dailyAvgCost * 1.25 {
            pace = .ahead
        } else if projectedCost < dailyAvgCost * 0.75 {
            pace = .below
        } else {
            pace = .onTrack
        }

        return VelocityForecast(
            projectedCost: projectedCost,
            projectedTokens: projectedTokens,
            pace: pace,
            dayProgress: progress
        )
    }
}
