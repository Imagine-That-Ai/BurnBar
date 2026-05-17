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

    private let capabilityGate: any MediaCapabilityGate
    private var screenCapture: ScreenCapturePipeline?
    private var videoEncoder: VideoEncoder?
    private var bitrateController: BitrateController
    private var streamSink: MediaStreamSink?
    private var sessionMetadata: MediaSessionMetadata?
    private var activeStreamClass: MediaStreamClass = .screenVideo
    private var cursorProvider: (@MainActor @Sendable () -> MediaFrame.CursorMetadata?)?

    init(
        capabilityGate: any MediaCapabilityGate,
        defaultBitrateSteps: BitrateController.Steps = .screenShare
    ) {
        self.capabilityGate = capabilityGate
        self.bitrateController = BitrateController(steps: defaultBitrateSteps)
    }

    func startScreenShare(
        peerDeviceID: String,
        sink: MediaStreamSink,
        streamClassOverride: MediaStreamClass? = nil,
        cursorProvider: (@MainActor @Sendable () -> MediaFrame.CursorMetadata?)? = nil
    ) async throws {
        guard phase == .idle || phase == .ended(reason: .completedSuccess) else {
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
                preferredCodec: .hevc,
                frameRate: 30
            )
        ) { [weak self] frame in
            await self?.handleEncodedFrame(frame)
        }
        try encoder.start()
        self.videoEncoder = encoder
        bitrateBitsPerSecond = bitrateController.currentBitsPerSecond

        let pipeline = ScreenCapturePipeline { [weak self] sample in
            guard let self else { return }
            try? await self.videoEncoder?.encode(sampleBuffer: sample)
        }
        try await pipeline.start()
        self.screenCapture = pipeline
        phase = .active(feature: .screenShare)
    }

    func ingestBandwidthSample(_ sample: BitrateController.Sample) {
        let next = bitrateController.apply(sample: sample)
        if next != bitrateBitsPerSecond {
            bitrateBitsPerSecond = next
            try? videoEncoder?.setTargetBitsPerSecond(next)
        }
        roundTripMillis = sample.roundTripMillis
    }

    func recordFreeze() {
        freezeCount += 1
    }

    func stop(reason: MediaSessionMetadata.EndReason = .completedUserCancel) async {
        phase = .stopping
        if let screenCapture {
            await screenCapture.stop()
        }
        videoEncoder?.stop()
        await streamSink?.close()
        cursorProvider = nil
        activeStreamClass = .screenVideo

        var metadata = sessionMetadata
        metadata?.endedAt = Date()
        metadata?.endReason = reason
        sessionMetadata = metadata

        phase = .ended(reason: reason)
    }

    private func handleEncodedFrame(_ frame: MediaFrame) async {
        var outbound = frame
        if activeStreamClass == .controlSurfaceFrame {
            outbound.flags.insert(.hasCursorMetadata)
            outbound.cursor = cursorProvider?() ?? Self.currentCursorMetadata()
        }
        await streamSink?.write(frame: outbound)
        sessionMetadata?.byteCountOutbound += Int64(outbound.payload.count)
    }

    private static func currentCursorMetadata() -> MediaFrame.CursorMetadata? {
        let location = NSEvent.mouseLocation
        let x = max(Int(Int16.min), min(Int(Int16.max), Int(location.x.rounded())))
        let y = max(Int(Int16.min), min(Int(Int16.max), Int(location.y.rounded())))
        return MediaFrame.CursorMetadata(x: Int16(x), y: Int16(y))
    }
}

/// Abstraction over "where encoded frames land": for Phase 3 it's the
/// per-GOP iroh stream the Mac opens against the paired iPhone via the
/// `media.screen.video` ALPN. For tests it's a recorder that asserts on
/// what was written.
protocol MediaStreamSink: Sendable {
    func write(frame: MediaFrame) async
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
