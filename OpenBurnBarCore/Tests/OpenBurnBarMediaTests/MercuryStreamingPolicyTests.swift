import XCTest
@testable import OpenBurnBarMedia

final class MercuryStreamingPolicyTests: XCTestCase {
    func testCodecRouterUsesProductionOrderAndRecordsStats() {
        let local = capabilitySnapshot(
            codecs: [
                codec(.av1, encode: true, decode: true),
                codec(.hevc, encode: true, decode: true),
                codec(.h264, encode: true, decode: true)
            ],
            versions: .v1AndV2,
            datagramBytes: 1_400
        )
        let remote = capabilitySnapshot(
            codecs: [
                codec(.av1, encode: true, decode: true),
                codec(.hevc, encode: false, decode: true),
                codec(.h264, encode: false, decode: true)
            ],
            versions: .v1AndV2,
            datagramBytes: 1_300
        )

        let route = MercuryCodecRouter.route(local: local, remote: remote)

        XCTAssertEqual(route.status, .routed)
        XCTAssertEqual(route.codec, .hevc)
        XCTAssertEqual(route.wireVersion, .v2)
        XCTAssertEqual(route.stats.codec, .hevc)
        XCTAssertEqual(route.stats.wireVersion, .v2)
        XCTAssertEqual(route.datagramPayloadBudgetBytes, 1_236)
    }

    func testCodecRouterDoesNotMigrateActiveSessionMidStream() {
        let hevcRoute = MercuryCodecRoutingDecision(
            status: .routed,
            codec: .hevc,
            wireVersion: .v1,
            datagramPayloadBudgetBytes: nil,
            stats: MercuryRtcStatsSnapshot(timestampMillis: 1, codec: .hevc),
            reason: "initial"
        )
        let local = capabilitySnapshot(codecs: [codec(.h264, encode: true, decode: true)])
        let remote = capabilitySnapshot(codecs: [codec(.h264, encode: false, decode: true)])

        let route = MercuryCodecRouter.route(
            local: local,
            remote: remote,
            activeSessionRoute: hevcRoute,
            timestampMillis: 2
        )

        XCTAssertEqual(route.codec, .hevc)
        XCTAssertEqual(route.stats.timestampMillis, 2)
        XCTAssertTrue(route.reason.contains("restart"))
    }

    func testShadowBweReportsRiskWithoutChangingProductionController() {
        let production = BitrateController(steps: .screenShare)
        let before = production.currentBitsPerSecond
        var shadow = MercuryShadowBweController(steps: .screenShare)

        let decision = shadow.observe(sample: MercuryBweShadowSample(
            timestampMillis: 1,
            roundTripMillis: 320,
            packetLossRate: 0.08,
            observedBitsPerSecond: 8_000_000,
            expectedPresentationMillis: 1_000,
            actualPresentationMillis: 1_130,
            pacerQueueDepth: 12,
            isProbe: true
        ))

        XCTAssertEqual(production.currentBitsPerSecond, before)
        XCTAssertLessThan(decision.shadowTargetBitsPerSecond, before)
        XCTAssertGreaterThan(decision.freezeRiskScore, 0)
        XCTAssertFalse(decision.promotionReady)
    }

    func testShadowBweRequiresProbeAndCleanEvidenceBeforePromotion() {
        var shadow = MercuryShadowBweController(steps: .videoCall, minimumPromotionSamples: 3)

        for index in 0..<3 {
            _ = shadow.observe(sample: MercuryBweShadowSample(
                timestampMillis: UInt64(index),
                roundTripMillis: 30,
                packetLossRate: 0,
                observedBitsPerSecond: 1_200_000,
                expectedPresentationMillis: 1_000,
                actualPresentationMillis: 1_004,
                isProbe: index == 0
            ))
        }

        XCTAssertTrue(shadow.currentDecision.promotionReady)
        XCTAssertEqual(shadow.currentDecision.probeSamples, 1)
    }

    func testLTRRecoveryUsesRealAcknowledgementTokensOnly() {
        var state = MercuryLTRRecoveryState()
        state.requestRefresh()

        XCTAssertNil(state.recordEncodedRefreshToken(nil))
        XCTAssertEqual(state.idrFallbacks, 1)

        let realToken = MercuryLTRToken(value: 0xCAFE)
        XCTAssertEqual(state.recordEncodedRefreshToken(realToken.value), realToken)
        XCTAssertEqual(state.pendingRefreshTokens, [realToken])

        state.acknowledgeDecodedToken(realToken)
        XCTAssertEqual(state.pendingRefreshTokens, [])
        XCTAssertEqual(state.acknowledgedTokenValuesForEncoder, [realToken.value])
    }

    func testDatagramSchedulerKeepsCriticalVideoReliable() {
        let capability = MercuryDatagramCapability(maxPayloadBytes: 1_200)
        let keyframe = MediaFrame(kind: .videoNAL, flags: [.keyframe], payload: Data(repeating: 1, count: 100))
        let delta = MediaFrame(kind: .videoNAL, payload: Data(repeating: 2, count: 100))

        XCTAssertEqual(
            MercuryVideoDatagramScheduler.schedule(
                frame: keyframe,
                datagramsEnabled: true,
                remoteCapability: capability
            ).delivery,
            .reliableStream
        )
        XCTAssertEqual(
            MercuryVideoDatagramScheduler.schedule(
                frame: delta,
                datagramsEnabled: true,
                remoteCapability: capability
            ).delivery,
            .datagram
        )
        XCTAssertEqual(
            MercuryVideoDatagramScheduler.schedule(
                frame: delta,
                datagramsEnabled: true,
                remoteCapability: MercuryDatagramCapability(maxPayloadBytes: nil)
            ).delivery,
            .reliableStream
        )
    }

    func testAdvancedFeatureGateRequiresFullBenchmarkEvidence() {
        let temporalCodec = MercuryVideoCodecCapability(
            codec: .hevc,
            canEncode: true,
            canDecode: true,
            hardwareAccelerated: true,
            temporalLayering: true,
            screenContentCoding: true
        )
        let local = capabilitySnapshot(codecs: [temporalCodec])
        let remote = capabilitySnapshot(codecs: [temporalCodec])

        let denied = MercuryAdvancedFeatureGate.evaluate(local: local, remote: remote, benchmark: nil)
        XCTAssertFalse(denied.fecEnabled)
        XCTAssertFalse(denied.temporalLayersEnabled)
        XCTAssertFalse(denied.roiEnabled)

        let benchmark = MercuryBenchmarkEvidence(
            coveredImpairmentScenarios: MercuryImpairmentScenario.defaultMatrix,
            freezeCountImprovementPercent: 12,
            presentTimeErrorDeltaMillis: -4,
            cpuUsageDeltaPercent: 2,
            batteryDrainDeltaPercent: 1
        )
        let allowed = MercuryAdvancedFeatureGate.evaluate(
            local: local,
            remote: remote,
            benchmark: benchmark,
            dirtyRegionHintsSupported: true
        )

        XCTAssertTrue(allowed.fecEnabled)
        XCTAssertTrue(allowed.temporalLayersEnabled)
        XCTAssertTrue(allowed.roiEnabled)
    }

    private func capabilitySnapshot(
        codecs: [MercuryVideoCodecCapability],
        versions: MercuryMediaFrameVersionSupport = .v1Only,
        datagramBytes: Int? = nil
    ) -> MercuryStreamingCapabilitySnapshot {
        MercuryStreamingCapabilitySnapshot(
            codecCapabilities: codecs,
            mediaFrameVersions: versions,
            videoDatagrams: MercuryDatagramCapability(maxPayloadBytes: datagramBytes),
            source: "test"
        )
    }

    private func codec(
        _ codec: MercuryVideoCodec,
        encode: Bool,
        decode: Bool
    ) -> MercuryVideoCodecCapability {
        MercuryVideoCodecCapability(
            codec: codec,
            canEncode: encode,
            canDecode: decode,
            hardwareAccelerated: true
        )
    }
}
