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
/// Phase 3 ships the screen-share consumer of this controller; Phase 5
/// ships the video-call consumer. Phase 1 builds it as substrate so the
/// step ladders are locked down in a unit test before real consumers wire
/// in (per `plans/2026-05-15-mercury-media-master-plan.md` § B.6).
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

        public static let screenShare = Steps(values: [1_000_000, 2_000_000, 4_000_000, 8_000_000])
        public static let videoCall = Steps(values: [300_000, 600_000, 1_200_000])
    }

    public struct Sample: Sendable, Equatable {
        public var roundTripMillis: Int
        public var packetLossRate: Double // 0.0 … 1.0
        public var observedBitsPerSecond: Int

        public init(roundTripMillis: Int, packetLossRate: Double, observedBitsPerSecond: Int) {
            self.roundTripMillis = roundTripMillis
            self.packetLossRate = packetLossRate
            self.observedBitsPerSecond = observedBitsPerSecond
        }
    }

    public let steps: Steps
    public let rttDownAdaptThresholdMillis: Int
    public let lossDownAdaptThreshold: Double
    public let recoveryHysteresisSamples: Int

    private(set) public var currentBitsPerSecond: Int
    private var goodSamplesSinceDownAdapt: Int = 0

    public init(
        steps: Steps,
        rttDownAdaptThresholdMillis: Int = 200,
        lossDownAdaptThreshold: Double = 0.04,
        recoveryHysteresisSamples: Int = 3
    ) {
        self.steps = steps
        self.rttDownAdaptThresholdMillis = rttDownAdaptThresholdMillis
        self.lossDownAdaptThreshold = lossDownAdaptThreshold
        self.recoveryHysteresisSamples = recoveryHysteresisSamples
        self.currentBitsPerSecond = steps.values.last ?? 0
    }

    /// Apply one observation and return the new target ceiling. The encoder
    /// reads the returned value and reconfigures only when it differs from
    /// its current target — ABR oscillation is bounded by the step ladder.
    public mutating func apply(sample: Sample) -> Int {
        if sample.roundTripMillis >= rttDownAdaptThresholdMillis ||
           sample.packetLossRate >= lossDownAdaptThreshold {
            stepDown()
            goodSamplesSinceDownAdapt = 0
            return currentBitsPerSecond
        }

        goodSamplesSinceDownAdapt += 1
        if goodSamplesSinceDownAdapt >= recoveryHysteresisSamples {
            stepUp()
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
}
