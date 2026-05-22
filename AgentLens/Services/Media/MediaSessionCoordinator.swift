import Foundation
import AVFoundation
import AppKit
import Combine
import OpenBurnBarCore
import OpenBurnBarIrohRelay
import OpenBurnBarMedia

/// Mac-side orchestrator for a single Mercury media session. Composes
/// capture pipeline → encoder → packetizer → iroh stream → BWE feedback
/// → teardown for one feature at a time. Multiple features (screen
/// share + video call) compose by spinning up multiple coordinators
/// against the same iroh blob/control endpoint.
@MainActor
final class MediaSessionCoordinator: ObservableObject {
    enum Phase: Equatable, Sendable {
        case idle
        case starting(feature: MediaStreamClass.Feature)
        case active(feature: MediaStreamClass.Feature)
        case stopping
        case ended(reason: MediaSessionMetadata.EndReason)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var bitrateBitsPerSecond: Int = 0
    @Published private(set) var freezeCount: Int = 0
    @Published private(set) var roundTripMillis: Int = 0
    @Published private(set) var negotiatedCodec: MercuryVideoCodec?
    @Published private(set) var streamingStats: MercuryRtcStatsSnapshot?
    @Published private(set) var shadowBweDecision: MercuryBweShadowDecision?

    private let capabilityGate: any MediaCapabilityGate
    private var screenCapture: ScreenCapturePipeline?
    private var videoEncoder: VideoEncoder?
    private var bitrateController: BitrateController
    private var shadowBweController: MercuryShadowBweController
    private var streamSink: MediaStreamSink?
    private var sessionMetadata: MediaSessionMetadata?
    private var codecRoute: MercuryCodecRoutingDecision?
    private var activeStreamClass: MediaStreamClass = .screenVideo
    private var cursorProvider: (@MainActor @Sendable () -> MediaFrame.CursorMetadata?)?
    private var activeScreenCaptureConfiguration = ScreenCapturePipeline.Configuration()

    init(
        capabilityGate: any MediaCapabilityGate,
        defaultBitrateSteps: BitrateController.Steps = .screenShare
    ) {
        self.capabilityGate = capabilityGate
        self.bitrateController = BitrateController(steps: defaultBitrateSteps)
        self.shadowBweController = MercuryShadowBweController(steps: defaultBitrateSteps)
    }

    func startScreenShare(
        peerDeviceID: String,
        sink: MediaStreamSink,
        streamClassOverride: MediaStreamClass? = nil,
        displayId: String? = nil,
        cursorProvider: (@MainActor @Sendable () -> MediaFrame.CursorMetadata?)? = nil,
        localStreamingCapabilities: MercuryStreamingCapabilitySnapshot? = nil,
        remoteStreamingCapabilities: MercuryStreamingCapabilitySnapshot? = nil,
        codecPolicy: MercuryCodecPolicy = .production
    ) async throws {
        guard phase.isRestartable else {
            return
        }
        let check = await capabilityGate.check(
            feature: .screenShare,
            sessionDurationLimitSeconds: 60 * 60,
            sessionByteBudget: nil
        )
        switch check {
        case .denied(let reason):
            phase = .ended(reason: reason.endReason)
            throw MediaSessionError.denied(reason: reason)
        case .allowed:
            break
        }

        phase = .starting(feature: .screenShare)
        let streamClass = streamClassOverride ?? .screenVideo
        activeStreamClass = streamClass
        self.cursorProvider = cursorProvider
        var enableLongTermReference = false
        if let localStreamingCapabilities, let remoteStreamingCapabilities {
            let route = MercuryCodecRouter.route(
                local: localStreamingCapabilities,
                remote: remoteStreamingCapabilities,
                policy: codecPolicy,
                runtimeHealth: MercuryRuntimeHealthProbe.snapshot()
            )
            guard route.status == .routed else {
                phase = .ended(reason: .error)
                streamingStats = route.stats
                throw MediaSessionError.encodeFailed
            }
            codecRoute = route
            negotiatedCodec = route.codec
            streamingStats = route.stats
            if let codec = route.codec {
                enableLongTermReference =
                    localStreamingCapabilities.capability(for: codec)?.longTermReference == true &&
                    remoteStreamingCapabilities.capability(for: codec)?.longTermReference == true
            }
        } else {
            negotiatedCodec = .hevc
            streamingStats = MercuryRtcStatsSnapshot(
                timestampMillis: UInt64(Date().timeIntervalSince1970 * 1000),
                codec: .hevc,
                wireVersion: .v1,
                runtimeHealth: MercuryRuntimeHealthProbe.snapshot()
            )
        }
        sessionMetadata = MediaSessionMetadata(
            sessionID: UUID().uuidString,
            feature: .screenShare,
            streamClass: streamClass,
            peerDeviceID: peerDeviceID
        )
        self.streamSink = sink
        let encoder = VideoEncoder(
            configuration: .init(
                width: 1920,
                height: 1080,
                targetBitsPerSecond: bitrateController.currentBitsPerSecond,
                keyframeIntervalSeconds: 2.0,
                preferredCodec: VideoEncoder.Codec(mercuryCodec: negotiatedCodec) ?? .hevc,
                frameRate: 30,
                enableLongTermReference: enableLongTermReference
            )
        ) { [weak self] encodedFrame in
            await self?.handleEncodedFrame(encodedFrame)
        }
        try encoder.start()
        self.videoEncoder = encoder
        bitrateBitsPerSecond = bitrateController.currentBitsPerSecond

        activeScreenCaptureConfiguration = ScreenCapturePipeline.Configuration(displayId: displayId)
        let pipeline = ScreenCapturePipeline(configuration: activeScreenCaptureConfiguration) { [weak self] sample in
            guard let self else { return }
            try? await self.videoEncoder?.encode(sampleBuffer: sample)
        }
        try await pipeline.start()
        self.screenCapture = pipeline
        phase = .active(feature: .screenShare)
    }

    func switchScreenShareDisplay(displayId: String) async throws {
        try await switchScreenShareTarget(displayId: displayId, windowID: nil)
    }

    func switchScreenShareTarget(displayId: String?, windowID: CGWindowID?) async throws {
        guard phase == .active(feature: .screenShare) else { return }
        var nextConfiguration = activeScreenCaptureConfiguration
        nextConfiguration.displayId = displayId
        nextConfiguration.windowID = windowID
        let pipeline = ScreenCapturePipeline(configuration: nextConfiguration) { [weak self] sample in
            guard let self else { return }
            try? await self.videoEncoder?.encode(sampleBuffer: sample)
        }
        try await pipeline.start()
        let previousCapture = screenCapture
        self.screenCapture = pipeline
        activeScreenCaptureConfiguration = nextConfiguration
        if let previousCapture {
            await previousCapture.stop()
        }
    }

    func ingestBandwidthSample(_ sample: BitrateController.Sample) {
        let next = bitrateController.apply(sample: sample)
        let shadowDecision = shadowBweController.observe(sample: MercuryBweShadowSample(
            timestampMillis: UInt64(Date().timeIntervalSince1970 * 1000),
            roundTripMillis: sample.roundTripMillis,
            packetLossRate: sample.packetLossRate,
            observedBitsPerSecond: sample.observedBitsPerSecond,
            pacerQueueDepth: 0,
            isProbe: sample.observedBitsPerSecond > bitrateBitsPerSecond
        ))
        shadowBweDecision = shadowDecision
        if next != bitrateBitsPerSecond {
            bitrateBitsPerSecond = next
            try? videoEncoder?.setTargetBitsPerSecond(next)
        }
        roundTripMillis = sample.roundTripMillis
        refreshStreamingStats(sample: sample, shadowDecision: shadowDecision)
    }

    func recordFreeze() {
        freezeCount += 1
        refreshStreamingStats()
    }

    func acknowledgeLongTermReferenceToken(_ token: MercuryLTRToken) {
        videoEncoder?.acknowledgeLongTermReferenceToken(token.value)
        refreshStreamingStats()
    }

    func stop(reason: MediaSessionMetadata.EndReason = .completedUserCancel) async {
        phase = .stopping
        if let screenCapture {
            await screenCapture.stop()
        }
        videoEncoder?.stop()
        await streamSink?.close()
        screenCapture = nil
        videoEncoder = nil
        streamSink = nil
        cursorProvider = nil
        activeStreamClass = .screenVideo
        codecRoute = nil

        var metadata = sessionMetadata
        metadata?.endedAt = Date()
        metadata?.endReason = reason
        sessionMetadata = metadata

        phase = .ended(reason: reason)
    }

    private func handleEncodedFrame(_ encodedFrame: VideoEncoder.EncodedFrame) async {
        var outbound = encodedFrame.frame
        if activeStreamClass == .controlSurfaceFrame {
            outbound.flags.insert(.hasCursorMetadata)
            outbound.cursor = cursorProvider?() ?? Self.currentCursorMetadata()
        }
        if codecRoute?.wireVersion == .v2, activeStreamClass == .screenVideo {
            await streamSink?.write(frameV2: Self.makeFrameV2(
                from: outbound,
                codec: negotiatedCodec,
                longTermReferenceToken: encodedFrame.longTermReferenceToken
            ))
        } else {
            await streamSink?.write(frame: outbound)
        }
        sessionMetadata?.byteCountOutbound += Int64(outbound.payload.count)
    }

    nonisolated static func makeFrameV2(
        from frame: MediaFrame,
        codec: MercuryVideoCodec?,
        longTermReferenceToken: MercuryLTRToken?
    ) -> MediaFrameV2 {
        let metadata = (try? MediaFrameV2Metadata(
            codec: codec,
            longTermReferenceToken: longTermReferenceToken
        ).encode()) ?? Data()
        return MediaFrameV2(
            kind: .videoNAL,
            flags: UInt16(frame.flags.rawValue),
            gopID: frame.gopID,
            frameIndex: frame.frameIndex,
            presentationTimestampMillis: frame.presentationTimestampMillis,
            metadata: metadata,
            payload: frame.payload
        )
    }

    private func refreshStreamingStats(
        sample: BitrateController.Sample? = nil,
        shadowDecision: MercuryBweShadowDecision? = nil
    ) {
        var stats = streamingStats ?? MercuryRtcStatsSnapshot(
            timestampMillis: UInt64(Date().timeIntervalSince1970 * 1000),
            codec: negotiatedCodec,
            wireVersion: codecRoute?.wireVersion ?? .v1
        )
        stats.timestampMillis = UInt64(Date().timeIntervalSince1970 * 1000)
        stats.codec = negotiatedCodec
        stats.wireVersion = codecRoute?.wireVersion ?? stats.wireVersion
        stats.targetBitsPerSecond = bitrateBitsPerSecond
        if let sample {
            stats.actualBitsPerSecond = sample.observedBitsPerSecond
            stats.roundTripMillis = sample.roundTripMillis
            stats.packetLossRate = sample.packetLossRate
        }
        stats.pacerQueueDepth = shadowDecision?.pacerQueueDepth ?? stats.pacerQueueDepth
        stats.presentTimeErrorMillis = shadowDecision?.presentTimeErrorMillis ?? stats.presentTimeErrorMillis
        stats.freezeCount = freezeCount
        stats.runtimeHealth = MercuryRuntimeHealthProbe.snapshot()
        streamingStats = stats
    }

    private static func currentCursorMetadata() -> MediaFrame.CursorMetadata? {
        let location = NSEvent.mouseLocation
        let x = max(Int(Int16.min), min(Int(Int16.max), Int(location.x.rounded())))
        let y = max(Int(Int16.min), min(Int(Int16.max), Int(location.y.rounded())))
        return MediaFrame.CursorMetadata(x: Int16(x), y: Int16(y))
    }
}

private extension VideoEncoder.Codec {
    init?(mercuryCodec: MercuryVideoCodec?) {
        switch mercuryCodec {
        case .hevc:
            self = .hevc
        case .h264:
            self = .h264
        case .av1, .none:
            return nil
        }
    }
}

private extension MediaSessionCoordinator.Phase {
    var isRestartable: Bool {
        switch self {
        case .idle, .ended:
            return true
        case .starting, .active, .stopping:
            return false
        }
    }
}

/// Abstraction over "where encoded frames land": for Phase 3 it's the
/// per-GOP iroh stream the Mac opens against the paired iPhone via the
/// `media.screen.video` ALPN. For tests it's a recorder that asserts on
/// what was written.
protocol MediaStreamSink: Sendable {
    func write(frame: MediaFrame) async
    func write(frameV2: MediaFrameV2) async
    func close() async
}

enum MediaSessionError: Error, Equatable {
    case denied(reason: MediaCapabilityDenialReason)
    case captureFailed
    case encodeFailed
}

private extension MediaCapabilityDenialReason {
    var endReason: MediaSessionMetadata.EndReason {
        switch self {
        case .budgetSoftCapReached: return .budgetSoftCap
        case .budgetHardCapReached: return .budgetHardCap
        case .killSwitchActive: return .budgetHardCap
        default: return .error
        }
    }
}
