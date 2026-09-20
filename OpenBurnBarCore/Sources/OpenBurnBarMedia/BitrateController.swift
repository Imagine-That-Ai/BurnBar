import Foundation

/// Receiver-driven bandwidth-estimation ceiling for Mercury video streams.
///
/// Trimmed port of WebRTC's Google Congestion Control (GCC) algorithm —
/// delay-based loss detection plus a slow-start ramp. Receiver computes the
/// target ceiling every 200 ms and feeds it back to the encoder over the
/// `media.control` stream as a `BweFeedback` frame; the encoder treats the
/// value as a hard cap rather than a target so producer-side pacing stays
/// coupled to whatever the network is actually swallowing.
///
/// Screen-share rungs include cellular steps below the original 1 Mbps floor.
/// A constrained path (NWPath cellular/expensive/constrained, or the same
/// signal from the phone) fast-drops to the 500 kbps ceiling; RTT ≥ 200 ms
/// or loss ≥ 4% still walks the ladder, including 250 kbps.
public struct BitrateController: Sendable {
    /// Bitrate adapt steps per feature. The controller never picks a rate
    /// outside these — anything finer-grained is encoder noise rather
    /// than a user-visible quality tier.
    public struct Steps: Sendable, Equatable {
        public var values: [Int]

        public init(values: [Int]) {
            precondition(!values.isEmpty, "BitrateController requires at least one step")
            self.values = values.sorted()
        }

        /// Cellular / constrained floor and ceiling inside the screen ladder.
        public static let screenShareCellularFloor = 250_000
        public static let screenShareConstrainedCeiling = 500_000

        public static let screenShare = Steps(values: [
            screenShareCellularFloor,
            screenShareConstrainedCeiling,
            1_000_000,
            2_000_000,
            4_000_000,
            8_000_000
        ])

        public static let videoCall = Steps(values: [300_000, 600_000, 1_200_000])
    }

    public struct Sample: Sendable, Equatable {
        public var roundTripMillis: Int
        public var packetLossRate: Double // 0.0 … 1.0
        public var observedBitsPerSecond: Int
        /// Phone NWPath / ConnectivityManager: cellular, expensive, or constrained.
        public var pathConstrained: Bool

        public init(
            roundTripMillis: Int,
            packetLossRate: Double,
            observedBitsPerSecond: Int,
            pathConstrained: Bool = false
        ) {
            self.roundTripMillis = roundTripMillis
            self.packetLossRate = packetLossRate
            self.observedBitsPerSecond = observedBitsPerSecond
            self.pathConstrained = pathConstrained
        }
    }

    public let steps: Steps
    public let rttDownAdaptThresholdMillis: Int
    public let lossDownAdaptThreshold: Double
    public let recoveryHysteresisSamples: Int
    public let constrainedCeilingBitsPerSecond: Int

    public private(set) var currentBitsPerSecond: Int
    private var goodSamplesSinceDownAdapt: Int = 0

    public init(
        steps: Steps,
        rttDownAdaptThresholdMillis: Int = 200,
        lossDownAdaptThreshold: Double = 0.04,
        recoveryHysteresisSamples: Int = 3,
        constrainedCeilingBitsPerSecond: Int = Steps.screenShareConstrainedCeiling
    ) {
        self.steps = steps
        self.rttDownAdaptThresholdMillis = rttDownAdaptThresholdMillis
        self.lossDownAdaptThreshold = lossDownAdaptThreshold
        self.recoveryHysteresisSamples = recoveryHysteresisSamples
        self.constrainedCeilingBitsPerSecond = constrainedCeilingBitsPerSecond
        self.currentBitsPerSecond = steps.values.last ?? 0
    }

    /// Apply one observation and return the new target ceiling. The encoder
    /// reads the returned value and reconfigures only when it differs from
    /// its current target — ABR oscillation is bounded by the step ladder.
    public mutating func apply(sample: Sample) -> Int {
        if sample.pathConstrained {
            clampToConstrainedCeiling()
        }

        if sample.roundTripMillis >= rttDownAdaptThresholdMillis ||
           sample.packetLossRate >= lossDownAdaptThreshold {
            stepDown()
            if sample.pathConstrained {
                clampToConstrainedCeiling()
            }
            goodSamplesSinceDownAdapt = 0
            return currentBitsPerSecond
        }

        goodSamplesSinceDownAdapt += 1
        if goodSamplesSinceDownAdapt >= recoveryHysteresisSamples {
            stepUp()
            if sample.pathConstrained {
                clampToConstrainedCeiling()
            }
            goodSamplesSinceDownAdapt = 0
        }
        return currentBitsPerSecond
    }

    private mutating func stepDown() {
        let sorted = steps.values
        guard let currentIndex = sorted.firstIndex(of: currentBitsPerSecond) else {
            currentBitsPerSecond = sorted.first ?? currentBitsPerSecond
            return
        }
        let nextIndex = max(0, currentIndex - 1)
        currentBitsPerSecond = sorted[nextIndex]
    }

    private mutating func stepUp() {
        let sorted = steps.values
        guard let currentIndex = sorted.firstIndex(of: currentBitsPerSecond) else {
            currentBitsPerSecond = sorted.last ?? currentBitsPerSecond
            return
        }
        let nextIndex = min(sorted.count - 1, currentIndex + 1)
        currentBitsPerSecond = sorted[nextIndex]
    }

    private mutating func clampToConstrainedCeiling() {
        let cap = min(constrainedCeilingBitsPerSecond, steps.values.last ?? constrainedCeilingBitsPerSecond)
        if currentBitsPerSecond > cap {
            currentBitsPerSecond = steps.values.last(where: { $0 <= cap }) ?? steps.values.first ?? cap
        }
    }
}
