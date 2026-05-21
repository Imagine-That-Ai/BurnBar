import Foundation

public struct MercuryCodecRoutingDecision: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable, Equatable {
        case routed
        case noCompatibleCodec
    }

    public var status: Status
    public var codec: MercuryVideoCodec?
    public var wireVersion: MercuryMediaFrameWireVersion
    public var datagramPayloadBudgetBytes: Int?
    public var stats: MercuryRtcStatsSnapshot
    public var reason: String

    public init(
        status: Status,
        codec: MercuryVideoCodec?,
        wireVersion: MercuryMediaFrameWireVersion,
        datagramPayloadBudgetBytes: Int?,
        stats: MercuryRtcStatsSnapshot,
        reason: String
    ) {
        self.status = status
        self.codec = codec
        self.wireVersion = wireVersion
        self.datagramPayloadBudgetBytes = datagramPayloadBudgetBytes
        self.stats = stats
        self.reason = reason
    }
}

public enum MercuryCodecRouter {
    public static let datagramEnvelopeOverheadBytes = 64

    public static func route(
        local: MercuryStreamingCapabilitySnapshot,
        remote: MercuryStreamingCapabilitySnapshot,
        policy: MercuryCodecPolicy = .production,
        activeSessionRoute: MercuryCodecRoutingDecision? = nil,
        timestampMillis: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000),
        runtimeHealth: MercuryRuntimeHealthSnapshot? = nil
    ) -> MercuryCodecRoutingDecision {
        let wireVersion = MercuryWireVersionNegotiator.resolve(
            local: local.mediaFrameVersions,
            remote: remote.mediaFrameVersions
        )
        let datagramBudget = remote.videoDatagrams.payloadBudget(reserving: datagramEnvelopeOverheadBytes)

        if let activeSessionRoute {
            var stats = activeSessionRoute.stats
            stats.timestampMillis = timestampMillis
            stats.runtimeHealth = runtimeHealth
            return MercuryCodecRoutingDecision(
                status: activeSessionRoute.status,
                codec: activeSessionRoute.codec,
                wireVersion: activeSessionRoute.wireVersion,
                datagramPayloadBudgetBytes: activeSessionRoute.datagramPayloadBudgetBytes,
                stats: stats,
                reason: "active session keeps its negotiated codec until restart"
            )
        }

        let codec = MercuryCodecResolver.resolveSendCodec(local: local, remote: remote, policy: policy)
        let stats = MercuryRtcStatsSnapshot(
            timestampMillis: timestampMillis,
            codec: codec,
            wireVersion: wireVersion,
            runtimeHealth: runtimeHealth
        )
        guard let codec else {
            return MercuryCodecRoutingDecision(
                status: .noCompatibleCodec,
                codec: nil,
                wireVersion: wireVersion,
                datagramPayloadBudgetBytes: datagramBudget,
                stats: stats,
                reason: "no codec has local encode and remote decode support under policy"
            )
        }
        return MercuryCodecRoutingDecision(
            status: .routed,
            codec: codec,
            wireVersion: wireVersion,
            datagramPayloadBudgetBytes: datagramBudget,
            stats: stats,
            reason: "selected \(codec.rawValue) from runtime capability probes"
        )
    }
}

public struct MercuryBweShadowSample: Sendable, Equatable {
    public var timestampMillis: UInt64
    public var roundTripMillis: Int
    public var packetLossRate: Double
    public var observedBitsPerSecond: Int
    public var expectedPresentationMillis: UInt64?
    public var actualPresentationMillis: UInt64?
    public var pacerQueueDepth: Int
    public var isProbe: Bool

    public init(
        timestampMillis: UInt64,
        roundTripMillis: Int,
        packetLossRate: Double,
        observedBitsPerSecond: Int,
        expectedPresentationMillis: UInt64? = nil,
        actualPresentationMillis: UInt64? = nil,
        pacerQueueDepth: Int = 0,
        isProbe: Bool = false
    ) {
        self.timestampMillis = timestampMillis
        self.roundTripMillis = roundTripMillis
        self.packetLossRate = packetLossRate
        self.observedBitsPerSecond = observedBitsPerSecond
        self.expectedPresentationMillis = expectedPresentationMillis
        self.actualPresentationMillis = actualPresentationMillis
        self.pacerQueueDepth = pacerQueueDepth
        self.isProbe = isProbe
    }
}

public struct MercuryBweShadowDecision: Sendable, Equatable {
    public var shadowTargetBitsPerSecond: Int
    public var delayTrendMillis: Int
    public var lossResponseFactor: Double
    public var probeSamples: Int
    public var pacerQueueDepth: Int
    public var presentTimeErrorMillis: Double?
    public var freezeRiskScore: Double
    public var promotionReady: Bool

    public init(
        shadowTargetBitsPerSecond: Int,
        delayTrendMillis: Int,
        lossResponseFactor: Double,
        probeSamples: Int,
        pacerQueueDepth: Int,
        presentTimeErrorMillis: Double?,
        freezeRiskScore: Double,
        promotionReady: Bool
    ) {
        self.shadowTargetBitsPerSecond = shadowTargetBitsPerSecond
        self.delayTrendMillis = delayTrendMillis
        self.lossResponseFactor = lossResponseFactor
        self.probeSamples = probeSamples
        self.pacerQueueDepth = pacerQueueDepth
        self.presentTimeErrorMillis = presentTimeErrorMillis
        self.freezeRiskScore = freezeRiskScore
        self.promotionReady = promotionReady
    }
}

public struct MercuryShadowBweController: Sendable, Equatable {
    public var steps: BitrateController.Steps
    public var minimumPromotionSamples: Int
    public private(set) var currentDecision: MercuryBweShadowDecision

    private var previousRoundTripMillis: Int?
    private var sampleCount: Int = 0
    private var probeSamples: Int = 0
    private var cumulativePresentTimeErrorMillis: Double = 0
    private var presentTimeErrorSamples: Int = 0
    private var riskySamples: Int = 0

    public init(
        steps: BitrateController.Steps,
        minimumPromotionSamples: Int = 30
    ) {
        self.steps = steps
        self.minimumPromotionSamples = minimumPromotionSamples
        self.currentDecision = MercuryBweShadowDecision(
            shadowTargetBitsPerSecond: steps.values.last ?? 0,
            delayTrendMillis: 0,
            lossResponseFactor: 1,
            probeSamples: 0,
            pacerQueueDepth: 0,
            presentTimeErrorMillis: nil,
            freezeRiskScore: 0,
            promotionReady: false
        )
    }

    public mutating func observe(sample: MercuryBweShadowSample) -> MercuryBweShadowDecision {
        sampleCount += 1
        if sample.isProbe { probeSamples += 1 }
        let delayTrend = previousRoundTripMillis.map { sample.roundTripMillis - $0 } ?? 0
        previousRoundTripMillis = sample.roundTripMillis

        let presentError = Self.presentTimeError(expected: sample.expectedPresentationMillis, actual: sample.actualPresentationMillis)
        if let presentError {
            cumulativePresentTimeErrorMillis += abs(presentError)
            presentTimeErrorSamples += 1
        }

        let lossResponse = max(0.45, 1.0 - min(0.5, sample.packetLossRate * 4.0))
        let delayPenalty = delayTrend > 0 ? min(0.30, Double(delayTrend) / 600.0) : 0
        let rawTarget = Int(Double(sample.observedBitsPerSecond) * lossResponse * (1.0 - delayPenalty))
        let quantizedTarget = Self.quantize(rawTarget, steps: steps)

        var risk = 0.0
        if sample.packetLossRate >= 0.04 { risk += min(0.4, sample.packetLossRate * 4) }
        if delayTrend >= 50 { risk += min(0.3, Double(delayTrend) / 300.0) }
        if let presentError, abs(presentError) >= 80 { risk += min(0.2, abs(presentError) / 500.0) }
        if sample.pacerQueueDepth >= 8 { risk += min(0.1, Double(sample.pacerQueueDepth) / 100.0) }
        risk = min(1.0, risk)
        if risk > 0 { riskySamples += 1 }

        let averagePresentError = presentTimeErrorSamples == 0
            ? 0
            : cumulativePresentTimeErrorMillis / Double(presentTimeErrorSamples)
        let promotionReady = sampleCount >= minimumPromotionSamples &&
            riskySamples == 0 &&
            averagePresentError <= 20 &&
            probeSamples > 0

        currentDecision = MercuryBweShadowDecision(
            shadowTargetBitsPerSecond: quantizedTarget,
            delayTrendMillis: delayTrend,
            lossResponseFactor: lossResponse,
            probeSamples: probeSamples,
            pacerQueueDepth: sample.pacerQueueDepth,
            presentTimeErrorMillis: presentError,
            freezeRiskScore: risk,
            promotionReady: promotionReady
        )
        return currentDecision
    }

    private static func presentTimeError(expected: UInt64?, actual: UInt64?) -> Double? {
        guard let expected, let actual else { return nil }
        return Double(Int64(actual) - Int64(expected))
    }

    private static func quantize(_ rawTarget: Int, steps: BitrateController.Steps) -> Int {
        let sorted = steps.values.sorted()
        guard let first = sorted.first, let last = sorted.last else { return rawTarget }
        if rawTarget <= first { return first }
        if rawTarget >= last { return last }
        return sorted.last { $0 <= rawTarget } ?? first
    }
}

public struct MercuryLTRToken: Codable, Sendable, Hashable {
    /// VideoToolbox exposes LTR acknowledgement tokens as CFNumber values.
    /// Mercury carries the numeric value across the control path and returns
    /// the same value to `kVTEncodeFrameOptionKey_AcknowledgedLTRTokens`.
    public var value: UInt64

    public init(value: UInt64) {
        self.value = value
    }
}

public struct MercuryLTRRecoveryState: Codable, Sendable, Equatable {
    public private(set) var refreshRequested: Bool
    public private(set) var pendingRefreshTokens: [MercuryLTRToken]
    public private(set) var acknowledgedTokens: [MercuryLTRToken]
    public private(set) var idrFallbacks: Int

    public init(
        refreshRequested: Bool = false,
        pendingRefreshTokens: [MercuryLTRToken] = [],
        acknowledgedTokens: [MercuryLTRToken] = [],
        idrFallbacks: Int = 0
    ) {
        self.refreshRequested = refreshRequested
        self.pendingRefreshTokens = pendingRefreshTokens
        self.acknowledgedTokens = acknowledgedTokens
        self.idrFallbacks = idrFallbacks
    }

    public mutating func requestRefresh() {
        refreshRequested = true
    }

    public mutating func recordEncodedRefreshToken(_ token: UInt64?) -> MercuryLTRToken? {
        refreshRequested = false
        guard let token else {
            idrFallbacks += 1
            return nil
        }
        let wrapped = MercuryLTRToken(value: token)
        pendingRefreshTokens.append(wrapped)
        return wrapped
    }

    public mutating func acknowledgeDecodedToken(_ token: MercuryLTRToken) {
        pendingRefreshTokens.removeAll { $0 == token }
        if !acknowledgedTokens.contains(token) {
            acknowledgedTokens.append(token)
        }
    }

    public mutating func markRecoveryFailed() {
        acknowledgedTokens.removeAll()
        idrFallbacks += 1
        refreshRequested = true
    }

    public var acknowledgedTokenValuesForEncoder: [UInt64] {
        acknowledgedTokens.map(\.value)
    }
}

public enum MercuryFrameDelivery: String, Codable, Sendable, Equatable {
    case reliableStream
    case datagram
}

public struct MercuryDatagramSchedulingDecision: Codable, Sendable, Equatable {
    public var delivery: MercuryFrameDelivery
    public var payloadBudgetBytes: Int?
    public var reason: String

    public init(delivery: MercuryFrameDelivery, payloadBudgetBytes: Int?, reason: String) {
        self.delivery = delivery
        self.payloadBudgetBytes = payloadBudgetBytes
        self.reason = reason
    }
}

public enum MercuryVideoDatagramScheduler {
    public static func schedule(
        frame: MediaFrame,
        datagramsEnabled: Bool,
        remoteCapability: MercuryDatagramCapability,
        overheadBytes: Int = MercuryCodecRouter.datagramEnvelopeOverheadBytes,
        carriesParameterSets: Bool = false
    ) -> MercuryDatagramSchedulingDecision {
        guard datagramsEnabled else {
            return MercuryDatagramSchedulingDecision(
                delivery: .reliableStream,
                payloadBudgetBytes: nil,
                reason: "experiment flag disabled"
            )
        }
        if frame.flags.contains(.keyframe) || carriesParameterSets {
            return MercuryDatagramSchedulingDecision(
                delivery: .reliableStream,
                payloadBudgetBytes: remoteCapability.payloadBudget(reserving: overheadBytes),
                reason: "keyframes and parameter sets stay reliable"
            )
        }
        guard let budget = remoteCapability.payloadBudget(reserving: overheadBytes) else {
            return MercuryDatagramSchedulingDecision(
                delivery: .reliableStream,
                payloadBudgetBytes: nil,
                reason: "runtime datagram max payload is unavailable"
            )
        }
        guard frame.payload.count <= budget else {
            return MercuryDatagramSchedulingDecision(
                delivery: .reliableStream,
                payloadBudgetBytes: budget,
                reason: "payload exceeds runtime datagram budget"
            )
        }
        return MercuryDatagramSchedulingDecision(
            delivery: .datagram,
            payloadBudgetBytes: budget,
            reason: "delta video frame fits runtime datagram budget"
        )
    }
}

public struct MercuryBenchmarkEvidence: Codable, Sendable, Equatable {
    public var coveredImpairmentScenarios: [MercuryImpairmentScenario]
    public var freezeCountImprovementPercent: Double
    public var presentTimeErrorDeltaMillis: Double
    public var cpuUsageDeltaPercent: Double
    public var batteryDrainDeltaPercent: Double

    public init(
        coveredImpairmentScenarios: [MercuryImpairmentScenario],
        freezeCountImprovementPercent: Double,
        presentTimeErrorDeltaMillis: Double,
        cpuUsageDeltaPercent: Double,
        batteryDrainDeltaPercent: Double
    ) {
        self.coveredImpairmentScenarios = coveredImpairmentScenarios
        self.freezeCountImprovementPercent = freezeCountImprovementPercent
        self.presentTimeErrorDeltaMillis = presentTimeErrorDeltaMillis
        self.cpuUsageDeltaPercent = cpuUsageDeltaPercent
        self.batteryDrainDeltaPercent = batteryDrainDeltaPercent
    }

    public var coversDefaultMatrix: Bool {
        Set(coveredImpairmentScenarios) == Set(MercuryImpairmentScenario.defaultMatrix)
    }

    public var isPositive: Bool {
        coversDefaultMatrix &&
            freezeCountImprovementPercent > 0 &&
            presentTimeErrorDeltaMillis <= 0 &&
            cpuUsageDeltaPercent <= 5 &&
            batteryDrainDeltaPercent <= 5
    }
}

public struct MercuryAdvancedFeatureDecision: Codable, Sendable, Equatable {
    public var fecEnabled: Bool
    public var temporalLayersEnabled: Bool
    public var roiEnabled: Bool
    public var reasons: [String]

    public init(fecEnabled: Bool, temporalLayersEnabled: Bool, roiEnabled: Bool, reasons: [String]) {
        self.fecEnabled = fecEnabled
        self.temporalLayersEnabled = temporalLayersEnabled
        self.roiEnabled = roiEnabled
        self.reasons = reasons
    }
}

public enum MercuryAdvancedFeatureGate {
    public static func evaluate(
        local: MercuryStreamingCapabilitySnapshot,
        remote: MercuryStreamingCapabilitySnapshot,
        benchmark: MercuryBenchmarkEvidence?,
        dirtyRegionHintsSupported: Bool = false
    ) -> MercuryAdvancedFeatureDecision {
        guard let benchmark, benchmark.isPositive else {
            return MercuryAdvancedFeatureDecision(
                fecEnabled: false,
                temporalLayersEnabled: false,
                roiEnabled: false,
                reasons: ["benchmark evidence is missing or not positive across the full impairment matrix"]
            )
        }

        let localVideo = local.capability(for: .hevc) ?? local.capability(for: .h264)
        let remoteVideo = remote.capability(for: .hevc) ?? remote.capability(for: .h264)
        let temporal = localVideo?.temporalLayering == true && remoteVideo?.temporalLayering == true
        let roi = dirtyRegionHintsSupported && localVideo?.screenContentCoding == true
        var reasons: [String] = ["benchmark evidence covers the full impairment matrix"]
        if !temporal { reasons.append("temporal layering is not proven on both peers") }
        if !roi { reasons.append("ROI/dirty-region hints are not proven by capture and encoder APIs") }
        return MercuryAdvancedFeatureDecision(
            fecEnabled: true,
            temporalLayersEnabled: temporal,
            roiEnabled: roi,
            reasons: reasons
        )
    }
}
