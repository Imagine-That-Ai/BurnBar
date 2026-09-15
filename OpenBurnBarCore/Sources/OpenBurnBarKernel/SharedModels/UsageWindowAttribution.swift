import Foundation

/// How a session-level usage row should appear on a time-window chart.
///
/// Parsers persist one `TokenUsage` per session with the *lifetime* total and
/// a `[startTime, endTime]` span. Dropping that whole total onto `endTime`
/// (or `startTime`) is what makes Home look idle for 22 hours and then grow
/// two mountains at the moments a long-running Antigravity / Claude Code
/// session was last touched — which is also when BurnBar re-reads the log.
///
/// The honest chart for session-level data is:
///   1. keep only the fraction of the session that overlaps the window
///   2. spread that fraction across the buckets the overlap actually covers
///
/// Point rows (`start == end`, or shorter than `pointInterval`) stay in one
/// bucket, so a real one-shot request still reads as a spike.
public enum UsageWindowAttribution: Sendable {
    /// Intervals shorter than this are treated as a point so we never divide
    /// by a near-zero duration.
    public static let pointInterval: TimeInterval = 1

    /// Bucket-aligned weights for `amount` inside `[windowStart, windowEnd]`.
    ///
    /// The returned array is `bucketCount` long and sums to the prorated
    /// amount (or to `amount` when the whole session sits inside the window).
    /// Empty / inverted inputs return zeros of the requested length.
    public static func allocate(
        amount: Double,
        start: Date,
        end: Date,
        windowStart: Date,
        windowEnd: Date,
        bucketCount: Int
    ) -> [Double] {
        guard bucketCount > 0 else { return [] }
        var buckets = [Double](repeating: 0, count: bucketCount)
        guard amount != 0, windowEnd > windowStart else { return buckets }

        let sessionStart = min(start, end)
        let sessionEnd = max(start, end)
        let window = windowEnd.timeIntervalSince(windowStart)
        let duration = sessionEnd.timeIntervalSince(sessionStart)

        if duration < pointInterval {
            guard sessionStart >= windowStart, sessionStart <= windowEnd else { return buckets }
            buckets[index(of: sessionStart, windowStart: windowStart, window: window, bucketCount: bucketCount)] = amount
            return buckets
        }

        let overlapStart = max(sessionStart, windowStart)
        let overlapEnd = min(sessionEnd, windowEnd)
        guard overlapEnd > overlapStart else { return buckets }

        let prorated = amount * (overlapEnd.timeIntervalSince(overlapStart) / duration)
        let step = window / Double(bucketCount)
        let first = index(of: overlapStart, windowStart: windowStart, window: window, bucketCount: bucketCount)
        // A boundary that lands exactly on a bucket edge belongs to the
        // previous bucket, not the next empty one.
        let lastInstant = overlapEnd.addingTimeInterval(-.ulpOfOne)
        let last = index(
            of: max(overlapStart, lastInstant),
            windowStart: windowStart,
            window: window,
            bucketCount: bucketCount
        )

        var weights = [Double](repeating: 0, count: bucketCount)
        var weightSum = 0.0
        for index in first...last {
            let bucketStart = windowStart.addingTimeInterval(step * Double(index))
            let bucketEnd = windowStart.addingTimeInterval(step * Double(index + 1))
            let sliceStart = max(overlapStart, bucketStart)
            let sliceEnd = min(overlapEnd, bucketEnd)
            let weight = max(0, sliceEnd.timeIntervalSince(sliceStart))
            weights[index] = weight
            weightSum += weight
        }
        guard weightSum > 0 else { return buckets }

        for index in weights.indices {
            buckets[index] = prorated * (weights[index] / weightSum)
        }
        return buckets
    }

    private static func index(
        of date: Date,
        windowStart: Date,
        window: TimeInterval,
        bucketCount: Int
    ) -> Int {
        let progress = date.timeIntervalSince(windowStart) / window
        return min(bucketCount - 1, max(0, Int(progress * Double(bucketCount))))
    }
}
