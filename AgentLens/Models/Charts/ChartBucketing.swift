import Foundation

// MARK: - Chart Bucketing
//
// Pure, deterministic math for the Charts page. Every function here is
// side-effect free and operates on plain `(Date, Double)` events or `[Double]`
// arrays so the whole surface is unit-testable without a database or a view
// tree (see `AgentLensTests/Active/ChartBucketingTests.swift`).

enum ChartBucketing {

    // MARK: Types

    /// One time bucket: the bucket's start instant and the summed value.
    struct DateBucket: Equatable {
        let start: Date
        let value: Double
    }

    /// One histogram bin over `lower..<upper` with the number of samples inside.
    struct HistogramBin: Equatable {
        let lower: Double
        let upper: Double
        let count: Int
    }

    /// Least-squares fit over an evenly spaced series (x = 0, 1, 2, …).
    struct LinearFit: Equatable {
        let slope: Double
        let intercept: Double

        /// Value the fit predicts at index `x` (may extend past the data).
        func projected(at x: Double) -> Double {
            intercept + slope * x
        }
    }

    // MARK: Date buckets

    /// Sums `events` into contiguous calendar buckets covering `range`.
    ///
    /// `component` must be `.day` or `.hour`. Buckets are aligned to calendar
    /// boundaries (start of day / start of hour), so DST transitions produce
    /// 23- and 25-hour days rather than drifting edges. Events outside `range`
    /// are ignored; empty buckets are materialized with value 0 so series have
    /// a stable, gap-free shape.
    static func dateBuckets(
        events: [(date: Date, value: Double)],
        range: ClosedRange<Date>,
        component: Calendar.Component,
        calendar: Calendar = .current
    ) -> [DateBucket] {
        guard range.upperBound > range.lowerBound else { return [] }

        var starts: [Date] = []
        var cursor = alignedStart(of: range.lowerBound, component: component, calendar: calendar)
        // Hard ceiling keeps a malformed range from allocating unbounded buckets.
        let maxBuckets = component == .hour ? 24 * 62 : 6_200
        while cursor < range.upperBound && starts.count < maxBuckets {
            starts.append(cursor)
            guard let next = calendar.date(byAdding: component, value: 1, to: cursor) else { break }
            cursor = next
        }
        guard !starts.isEmpty else { return [] }

        var totals = [Double](repeating: 0, count: starts.count)
        for event in events where range.contains(event.date) {
            // Binary search for the owning bucket (starts is ascending).
            var low = 0
            var high = starts.count - 1
            while low < high {
                let mid = (low + high + 1) / 2
                if starts[mid] <= event.date { low = mid } else { high = mid - 1 }
            }
            totals[low] += event.value
        }
        return zip(starts, totals).map(DateBucket.init)
    }

    private static func alignedStart(
        of date: Date,
        component: Calendar.Component,
        calendar: Calendar
    ) -> Date {
        switch component {
        case .hour:
            let comps = calendar.dateComponents([.year, .month, .day, .hour], from: date)
            return calendar.date(from: comps) ?? date
        default:
            return calendar.startOfDay(for: date)
        }
    }

    // MARK: Hour × weekday heatmap

    /// Sums `events` into a 7×24 matrix — `matrix[weekdayIndex][hour]` — where
    /// `weekdayIndex` is 0-based from the calendar's weekday numbering
    /// (Gregorian: 0 = Sunday). Rendered as the time-of-day heatmap.
    static func hourWeekdayMatrix(
        events: [(date: Date, value: Double)],
        calendar: Calendar = .current
    ) -> [[Double]] {
        var matrix = [[Double]](repeating: [Double](repeating: 0, count: 24), count: 7)
        for event in events {
            let comps = calendar.dateComponents([.weekday, .hour], from: event.date)
            guard let weekday = comps.weekday, let hour = comps.hour,
                  (1...7).contains(weekday), (0...23).contains(hour) else { continue }
            matrix[weekday - 1][hour] += event.value
        }
        return matrix
    }

    // MARK: Histogram (log buckets)

    /// Buckets strictly positive `values` into `bucketCount` bins that are
    /// evenly spaced in log₁₀ space — the natural scale for session costs,
    /// which span from fractions of a cent to tens of dollars.
    /// Non-positive values are dropped. The final bin's upper edge is inclusive.
    static func histogramLogBuckets(values: [Double], bucketCount: Int = 8) -> [HistogramBin] {
        let positives = values.filter { $0 > 0 }
        guard bucketCount > 0, let minValue = positives.min(), let maxValue = positives.max() else {
            return []
        }
        guard maxValue > minValue else {
            return [HistogramBin(lower: minValue, upper: maxValue, count: positives.count)]
        }
        let logMin = log10(minValue)
        let logMax = log10(maxValue)
        let step = (logMax - logMin) / Double(bucketCount)
        var counts = [Int](repeating: 0, count: bucketCount)
        for value in positives {
            let raw = (log10(value) - logMin) / step
            let index = min(bucketCount - 1, max(0, Int(raw)))
            counts[index] += 1
        }
        return (0..<bucketCount).map { i in
            HistogramBin(
                lower: pow(10, logMin + Double(i) * step),
                upper: pow(10, logMin + Double(i + 1) * step),
                count: counts[i]
            )
        }
    }

    // MARK: Linear forecast

    /// Ordinary least-squares fit over an evenly spaced series (x = index).
    /// Returns nil for fewer than 2 points (no trend is defensible).
    static func linearFit(values: [Double]) -> LinearFit? {
        let n = values.count
        guard n >= 2 else { return nil }
        let xs = (0..<n).map(Double.init)
        let sumX = xs.reduce(0, +)
        let sumY = values.reduce(0, +)
        let sumXY = zip(xs, values).reduce(0) { $0 + $1.0 * $1.1 }
        let sumXX = xs.reduce(0) { $0 + $1 * $1 }
        let denominator = Double(n) * sumXX - sumX * sumX
        guard abs(denominator) > .ulpOfOne else { return nil }
        let slope = (Double(n) * sumXY - sumX * sumY) / denominator
        let intercept = (sumY - slope * sumX) / Double(n)
        return LinearFit(slope: slope, intercept: intercept)
    }

    // MARK: Entropy / focus

    /// Normalized Shannon entropy of a share distribution, in 0…1.
    /// 0 = all weight on one bucket (fully focused), 1 = perfectly uniform.
    /// Zero/negative weights are ignored; a distribution with fewer than two
    /// positive buckets is fully focused by definition.
    static func entropyIndex(_ weights: [Double]) -> Double {
        let positives = weights.filter { $0 > 0 }
        guard positives.count > 1 else { return 0 }
        let total = positives.reduce(0, +)
        guard total > 0 else { return 0 }
        let entropy = positives.reduce(0.0) { partial, weight in
            let p = weight / total
            return partial - p * log2(p)
        }
        return entropy / log2(Double(positives.count))
    }

    // MARK: Median

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }
}
