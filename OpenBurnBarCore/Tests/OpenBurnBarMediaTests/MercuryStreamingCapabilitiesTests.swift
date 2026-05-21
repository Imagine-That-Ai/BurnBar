import XCTest
@testable import OpenBurnBarCore
@testable import OpenBurnBarMedia

final class MercuryStreamingCapabilitiesTests: XCTestCase {
    func testProductionPolicyDoesNotSelectAV1BeforeExperimentFlag() {
        let local = snapshot([
            capability(.av1, encode: true, decode: true),
            capability(.hevc, encode: true, decode: true),
            capability(.h264, encode: true, decode: true)
        ])
        let remote = snapshot([
            capability(.av1, encode: false, decode: true),
            capability(.hevc, encode: false, decode: true),
            capability(.h264, encode: false, decode: true)
        ])

        XCTAssertEqual(
            MercuryCodecResolver.resolveSendCodec(local: local, remote: remote, policy: .production),
            .hevc
        )
        XCTAssertEqual(
            MercuryCodecResolver.resolveSendCodec(local: local, remote: remote, policy: .experimentalAV1),
            .av1
        )
    }

    func testCodecResolverFallsBackToH264WhenHEVCIsNotMutual() {
        let local = snapshot([
            capability(.hevc, encode: true, decode: true),
            capability(.h264, encode: true, decode: true)
        ])
        let remote = snapshot([
            capability(.hevc, encode: false, decode: false),
            capability(.h264, encode: false, decode: true)
        ])

        XCTAssertEqual(MercuryCodecResolver.resolveSendCodec(local: local, remote: remote), .h264)
    }

    func testCodecResolverReturnsNilWithoutAMutualSendCodec() {
        let local = snapshot([
            capability(.hevc, encode: true, decode: true),
            capability(.h264, encode: false, decode: true)
        ])
        let remote = snapshot([
            capability(.hevc, encode: false, decode: false),
            capability(.h264, encode: false, decode: true)
        ])

        XCTAssertNil(MercuryCodecResolver.resolveSendCodec(local: local, remote: remote))
    }

    func testWireVersionNegotiatorKeepsV1UntilBothPeersSupportV2() {
        XCTAssertEqual(
            MercuryWireVersionNegotiator.resolve(local: .v1Only, remote: .v1AndV2),
            .v1
        )
        XCTAssertFalse(
            MercuryWireVersionNegotiator.canSendMetadataV2(local: .v1Only, remote: .v1AndV2)
        )

        XCTAssertEqual(
            MercuryWireVersionNegotiator.resolve(local: .v1AndV2, remote: .v1AndV2),
            .v2
        )
        XCTAssertTrue(
            MercuryWireVersionNegotiator.canSendMetadataV2(local: .v1AndV2, remote: .v1AndV2)
        )
    }

    func testDatagramCapabilityRequiresRuntimeMaxPayload() {
        XCTAssertFalse(MercuryDatagramCapability(maxPayloadBytes: nil).isSupported)
        XCTAssertNil(MercuryDatagramCapability(maxPayloadBytes: nil).payloadBudget(reserving: 24))
        XCTAssertNil(MercuryDatagramCapability(maxPayloadBytes: 16).payloadBudget(reserving: 24))
        XCTAssertEqual(
            MercuryDatagramCapability(maxPayloadBytes: 1200).payloadBudget(reserving: 24),
            1176
        )
    }

    func testDatagramProbeNormalizesRuntimeMaxSize() {
        XCTAssertEqual(
            MercuryDatagramCapabilityProbe.snapshot(maxDatagramSize: 1200),
            MercuryDatagramCapability(maxPayloadBytes: 1200)
        )
        XCTAssertEqual(
            MercuryDatagramCapabilityProbe.snapshot(maxDatagramSize: 0),
            MercuryDatagramCapability(maxPayloadBytes: nil)
        )
        XCTAssertEqual(
            MercuryDatagramCapabilityProbe.snapshot { throw NSError(domain: "iroh", code: 1) },
            MercuryDatagramCapability(maxPayloadBytes: nil)
        )
    }

    func testStreamingCapabilitiesConvertToRelayWireShape() {
        let snapshot = MercuryStreamingCapabilitySnapshot(
            codecCapabilities: [
                MercuryVideoCodecCapability(
                    codec: .hevc,
                    canEncode: true,
                    canDecode: true,
                    hardwareAccelerated: true,
                    lowLatencyEncode: true,
                    longTermReference: true
                )
            ],
            mediaFrameVersions: .v1Only,
            videoDatagrams: MercuryDatagramCapability(maxPayloadBytes: 1200),
            source: "test"
        )

        let roundTripped = MercuryStreamingCapabilitySnapshot(wire: snapshot.wireValue)

        XCTAssertEqual(roundTripped, snapshot)
        XCTAssertEqual(snapshot.wireValue.codecCapabilities.first?.codec, .hevc)
    }

    #if canImport(VideoToolbox)
    func testVideoToolboxProbeReportsAuditedCodecsWithoutAssumingScreenContentCoding() {
        let snapshot = MercuryVideoToolboxCapabilityProbe.snapshot(width: 640, height: 360)

        XCTAssertEqual(snapshot.source, "VideoToolbox")
        XCTAssertNotNil(snapshot.capability(for: .av1))
        XCTAssertNotNil(snapshot.capability(for: .hevc))
        XCTAssertNotNil(snapshot.capability(for: .h264))
        XCTAssertFalse(snapshot.capability(for: .av1)?.screenContentCoding ?? true)
        XCTAssertFalse(snapshot.capability(for: .hevc)?.screenContentCoding ?? true)
        XCTAssertFalse(snapshot.capability(for: .h264)?.screenContentCoding ?? true)
    }
    #endif

    private func snapshot(
        _ capabilities: [MercuryVideoCodecCapability],
        mediaFrameVersions: MercuryMediaFrameVersionSupport = .v1Only,
        datagramMaxPayloadBytes: Int? = nil
    ) -> MercuryStreamingCapabilitySnapshot {
        MercuryStreamingCapabilitySnapshot(
            codecCapabilities: capabilities,
            mediaFrameVersions: mediaFrameVersions,
            videoDatagrams: MercuryDatagramCapability(maxPayloadBytes: datagramMaxPayloadBytes),
            source: "test"
        )
    }

    private func capability(
        _ codec: MercuryVideoCodec,
        encode: Bool,
        decode: Bool
    ) -> MercuryVideoCodecCapability {
        MercuryVideoCodecCapability(
            codec: codec,
            canEncode: encode,
            canDecode: decode,
            hardwareAccelerated: encode || decode,
            lowLatencyEncode: encode,
            temporalLayering: false,
            longTermReference: false,
            screenContentCoding: false
        )
    }
}
