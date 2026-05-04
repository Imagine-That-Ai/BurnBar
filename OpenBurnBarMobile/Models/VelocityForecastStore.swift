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

        // Linear extrapolation of today's run-rate to a full day.
        let projectedCost = todayCost / progress
        let projectedTokens = Int(Double(todayTokens) / progress)

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
