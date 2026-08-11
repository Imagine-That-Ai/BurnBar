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
protocol ScreenCaptureSession: AnyObject {
    func start() async throws
    func stop() async
}

extension ScreenCapturePipeline: ScreenCaptureSession {}

@MainActor
final class MediaSessionCoordinator: ObservableObject {
    typealias ScreenCaptureSessionFactory = @MainActor @Sendable (
        ScreenCapturePipeline.Configuration,
        @escaping ScreenCapturePipeline.FrameHandler
    ) -> any ScreenCaptureSession
    typealias VideoEncoderFactory = @MainActor @Sendable (
        VideoEncoder.Configuration,
        @escaping VideoEncoder.EncodedHandler
    ) -> any VideoEncoding
    typealias RuntimeHealthProvider = @MainActor @Sendable () -> MercuryRuntimeHealthSnapshot

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
    private let screenCaptureFactory: ScreenCaptureSessionFactory
    private var screenCapture: (any ScreenCaptureSession)?
    private let videoEncoderFactory: VideoEncoderFactory
    private let runtimeHealthProvider: RuntimeHealthProvider
    private var videoEncoder: (any VideoEncoding)?
    private var bitrateController: BitrateController
    private var shadowBweController: MercuryShadowBweController
    private var streamSinks: [String: MediaStreamSink] = [:]
    private var sessionMetadata: MediaSessionMetadata?
    private var activeAdmissionRequest: ActiveAdmissionRequest?
    private var admissionMonitorTask: Task<Void, Never>?
    private let admissionRecheckIntervalNanoseconds: UInt64
    private var codecRoute: MercuryCodecRoutingDecision?
    private var activeStreamClass: MediaStreamClass = .screenVideo
    private var cursorProvider: (@MainActor @Sendable () -> MediaFrame.CursorMetadata?)?
    private var activeScreenCaptureConfiguration = ScreenCapturePipeline.Configuration()
    /// Visual surface for this session. When `.cliPTY` the coordinator stays idle (no
    /// ScreenCapturePipeline/SCStream) to keep idle budgets. Desktop share debits
    /// `MediaBudgetStatusStore` via `capabilityGate` (120 min normal / 30 soft).
    private var visualCaptureSource: VisualCaptureSource = .desktopApp

    init(
        capabilityGate: any MediaCapabilityGate,
        defaultBitrateSteps: BitrateController.Steps = .screenShare,
        admissionRecheckIntervalNanoseconds: UInt64 = 5_000_000_000,
        runtimeHealthProvider: @escaping RuntimeHealthProvider = {
            MercuryRuntimeHealthProbe.snapshot()
        },
        screenCaptureFactory: @escaping ScreenCaptureSessionFactory = { configuration, frameHandler in
            // Factory is surface-agnostic; surface is injected at startScreenShare time via
            // ScreenCapturePipeline(..., visualCaptureSource:). The default here stays
            // `.desktopApp` for backward compat when caller doesn't pass surface.
            ScreenCapturePipeline(configuration: configuration, frameHandler: frameHandler)
        },
        videoEncoderFactory: @escaping VideoEncoderFactory = { configuration, onEncoded in
            VideoEncoder(configuration: configuration, onEncoded: onEncoded)
        }
    ) {
        self.capabilityGate = capabilityGate
        self.admissionRecheckIntervalNanoseconds = admissionRecheckIntervalNanoseconds
        self.runtimeHealthProvider = runtimeHealthProvider
        self.screenCaptureFactory = screenCaptureFactory
        self.videoEncoderFactory = videoEncoderFactory
        self.bitrateController = BitrateController(steps: defaultBitrateSteps)
        self.shadowBweController = MercuryShadowBweController(steps: defaultBitrateSteps)
    }

    func startScreenShare(
        peerDeviceID: String,
        sink: MediaStreamSink,
        streamClassOverride: MediaStreamClass? = nil,
        displayId: String? = nil,
        viewerID: String? = nil,
        cursorProvider: (@MainActor @Sendable () -> MediaFrame.CursorMetadata?)? = nil,
        localStreamingCapabilities: MercuryStreamingCapabilitySnapshot? = nil,
        remoteStreamingCapabilities: MercuryStreamingCapabilitySnapshot? = nil,
        codecPolicy: MercuryCodecPolicy = .production,
        visualCaptureSource: VisualCaptureSource = .desktopApp
    ) async throws {
        let sinkID = viewerID ?? peerDeviceID
        let streamClass = streamClassOverride ?? .screenVideo
        if case .active(feature: .screenShare) = phase {
            guard streamClass == activeStreamClass else { throw MediaSessionError.encodeFailed }
            streamSinks[sinkID] = sink
            return
        }
        guard phase.isRestartable else { throw MediaSessionError.captureFailed }
        self.visualCaptureSource = visualCaptureSource
        // PERF guard: when surface is .cliPTY stay idle — must NOT touch SCShareableContent,
        // SCStream, or debit MediaBudgetStatusStore. PTY path is text-only (256KB bounded).
        if visualCaptureSource == .cliPTY {
            // No screen capture pipeline, no budget check. Stay in idle but return success
            // so caller can fall back to PTY text streaming without an error.
            // We still need to set a minimal session so detach logic works, but without
            // starting encoder/pipeline. For simplicity we early-return and keep phase idle;
            // the caller (MercuryRouter) will handle PTY fallback outside this coordinator.
            // Log and keep `screenCapture` nil to guarantee no SCStream is created.
            // Note: MediaBudgetStatusStore minutes are NOT debited for PTY.
            return
        }
        // Desktop path — gate on entitlement + daily cap (120 min normal / 30 soft)
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

        do {
            phase = .starting(feature: .screenShare)
            activeStreamClass = streamClass
            self.cursorProvider = cursorProvider
            var enableLongTermReference = false
            if let localStreamingCapabilities, let remoteStreamingCapabilities {
                let route = MercuryCodecRouter.route(
                    local: localStreamingCapabilities,
                    remote: remoteStreamingCapabilities,
                    policy: codecPolicy,
                    runtimeHealth: runtimeHealthProvider()
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
                    runtimeHealth: runtimeHealthProvider()
                )
            }
            sessionMetadata = MediaSessionMetadata(
                sessionID: UUID().uuidString,
                feature: .screenShare,
                streamClass: streamClass,
                peerDeviceID: peerDeviceID
            )
            self.streamSinks = [sinkID: sink]
            let encoder = videoEncoderFactory(
                .init(
                    width: 1920,
                    height: 1080,
                    targetBitsPerSecond: bitrateController.currentBitsPerSecond,
                    keyframeIntervalSeconds: 2.0,
                    preferredCodec: VideoEncoder.Codec(mercuryCodec: negotiatedCodec) ?? .hevc,
                    frameRate: 30,
                    enableLongTermReference: enableLongTermReference
                ),
                { [weak self] encodedFrame in
                    await self?.handleEncodedFrame(encodedFrame)
                }
            )
            try encoder.start()
            self.videoEncoder = encoder
            bitrateBitsPerSecond = bitrateController.currentBitsPerSecond

            activeScreenCaptureConfiguration = ScreenCapturePipeline.Configuration(displayId: displayId)
            let pipeline = screenCaptureFactory(activeScreenCaptureConfiguration) { [weak self] sample in
                guard let self else { return }
                try? await self.videoEncoder?.encode(sampleBuffer: sample) // try?-ok(drop live frame)
            }
            do {
                try await pipeline.start()
            } catch let error as ScreenCapturePipeline.Failure { // try?-ok(screen capture fallback)
                guard case .screenRecordingPermissionDenied = error else { throw error }
                // P1 #4 — Desktop capture denied (TCC revoked or never granted). Fail closed to PTY:
                // - Do NOT leave a half-started encoder/stream (tear down)
                // - Emit Mac toast + phone pill via SystemPermissionMonitor (synchronous, not poll)
                // - Audit entry with denyReason=screen_recording_denied_fallback_to_pty is emitted by
                //   the Computer Use path (ComputerUseSessionCoordinator); here we just log and stay idle
                //   so the caller can stream PTY text instead of pixels.
                // - Deep link to System Settings is available via SystemPermissionKind.screenRecording.deepLink
                await SystemPermissionMonitor.shared.emitRequesting(
                    kind: .screenRecording,
                    bundleId: nil,
                    originatingToolCallId: nil,
                    originatingToolName: nil,
                    instructions: "Screen Recording denied — showing terminal. Enable in System Settings → Privacy & Security → Screen Recording.",
                    failureCategory: "screen_recording_denied_fallback_to_pty"
                )
                // Tear down encoder we already started
                self.videoEncoder?.stop()
                self.videoEncoder = nil
                self.streamSinks.removeAll()
                self.sessionMetadata = nil
                self.phase = .ended(reason: .error)
                // Throw so MercuryRouter can surface a fallback UI (PTY) instead of silent empty frame
                throw error
            }
            self.screenCapture = pipeline
            phase = .active(feature: .screenShare)
            activeAdmissionRequest = ActiveAdmissionRequest(
                feature: .screenShare,
                sessionDurationLimitSeconds: 60 * 60,
                sessionByteBudget: nil
            )
            startAdmissionMonitor()
        } catch {
            await stop(reason: .error)
            throw error
        }
    }

    func switchScreenShareDisplay(displayId: String) async throws {
        try await switchScreenShareTarget(displayId: displayId, windowID: nil)
    }

    func switchScreenShareTarget(displayId: String?, windowID: CGWindowID?) async throws {
        guard phase == .active(feature: .screenShare) else { return }
        // Perf guard: do not switch/create pipeline when surface is cliPTY
        guard visualCaptureSource == .desktopApp else { return }
        var nextConfiguration = activeScreenCaptureConfiguration
        nextConfiguration.displayId = displayId
        nextConfiguration.windowID = windowID
        let pipeline = screenCaptureFactory(nextConfiguration) { [weak self] sample in
            guard let self else { return }
            try? await self.videoEncoder?.encode(sampleBuffer: sample) // try?-ok(drop live frame)
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
            try? videoEncoder?.setTargetBitsPerSecond(next) // try?-ok(best-effort BWE tune)
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
        admissionMonitorTask?.cancel()
        admissionMonitorTask = nil
        activeAdmissionRequest = nil
        phase = .stopping
        if let screenCapture {
            await screenCapture.stop()
        }
        videoEncoder?.stop()
        for sink in streamSinks.values {
            await sink.close()
        }
        screenCapture = nil
        videoEncoder = nil
        streamSinks.removeAll()
        cursorProvider = nil
        activeStreamClass = .screenVideo
        codecRoute = nil

        var metadata = sessionMetadata
        metadata?.endedAt = Date()
        metadata?.endReason = reason
        sessionMetadata = metadata

        phase = .ended(reason: reason)
    }

    @discardableResult
    func detachScreenShareViewer(viewerID: String, reason: MediaSessionMetadata.EndReason = .completedUserCancel) async -> Bool {
        guard let sink = streamSinks.removeValue(forKey: viewerID) else {
            return false
        }
        await sink.close()
        if streamSinks.isEmpty {
            await stop(reason: reason)
        }
        return true
    }

    var activeScreenShareViewerCount: Int {
        streamSinks.count
    }

    func recheckActiveAdmissionForTesting() async {
        await recheckActiveAdmission()
    }

    func seedActiveScreenShareForTesting(
        peerDeviceID: String,
        sink: any MediaStreamSink,
        screenCapture: any ScreenCaptureSession,
        videoEncoder: any VideoEncoding
    ) {
        admissionMonitorTask?.cancel()
        admissionMonitorTask = nil
        activeStreamClass = .screenVideo
        activeScreenCaptureConfiguration = ScreenCapturePipeline.Configuration()
        streamSinks = [peerDeviceID: sink]
        self.screenCapture = screenCapture
        self.videoEncoder = videoEncoder
        sessionMetadata = MediaSessionMetadata(
            sessionID: UUID().uuidString,
            feature: .screenShare,
            streamClass: .screenVideo,
            peerDeviceID: peerDeviceID
        )
        activeAdmissionRequest = ActiveAdmissionRequest(
            feature: .screenShare,
            sessionDurationLimitSeconds: 60 * 60,
            sessionByteBudget: nil
        )
        phase = .active(feature: .screenShare)
    }

    private func handleEncodedFrame(_ encodedFrame: VideoEncoder.EncodedFrame) async {
        var outbound = encodedFrame.frame
        if activeStreamClass == .controlSurfaceFrame {
            outbound.flags.insert(.hasCursorMetadata)
            outbound.cursor = cursorProvider?() ?? Self.currentCursorMetadata()
        }
        if codecRoute?.wireVersion == .v2, activeStreamClass == .screenVideo {
            let frameV2 = Self.makeFrameV2(
                from: outbound,
                codec: negotiatedCodec,
                longTermReferenceToken: encodedFrame.longTermReferenceToken
            )
            for sink in streamSinks.values {
                await sink.write(frameV2: frameV2)
            }
        } else {
            for sink in streamSinks.values {
                await sink.write(frame: outbound)
            }
        }
        sessionMetadata?.byteCountOutbound += Int64(outbound.payload.count * streamSinks.count)
    }

    private func startAdmissionMonitor() {
        admissionMonitorTask?.cancel()
        // Tests use UInt64.max to disable the background monitor and drive
        // admission rechecks manually without spawning a centuries-long sleep.
        guard admissionRecheckIntervalNanoseconds < UInt64.max else {
            return
        }
        admissionMonitorTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: self.admissionRecheckIntervalNanoseconds)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self.recheckActiveAdmission()
            }
        }
    }

    private func recheckActiveAdmission() async {
        guard let request = activeAdmissionRequest,
              case .active(let feature) = phase,
              feature == request.feature else {
            return
        }
        let check = await capabilityGate.check(
            feature: request.feature,
            sessionDurationLimitSeconds: request.sessionDurationLimitSeconds,
            sessionByteBudget: request.sessionByteBudget
        )
        guard case .denied(let reason) = check else { return }
        await stop(reason: reason.endReason)
    }

    nonisolated static func makeFrameV2(
        from frame: MediaFrame,
        codec: MercuryVideoCodec?,
        longTermReferenceToken: MercuryLTRToken?
    ) -> MediaFrameV2 {
        // try?-ok(optional descriptive metadata)
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
        stats.runtimeHealth = runtimeHealthProvider()
        streamingStats = stats
    }

    private static func currentCursorMetadata() -> MediaFrame.CursorMetadata? {
        let location = NSEvent.mouseLocation
        let x = max(Int(Int16.min), min(Int(Int16.max), Int(location.x.rounded())))
        let y = max(Int(Int16.min), min(Int(Int16.max), Int(location.y.rounded())))
        return MediaFrame.CursorMetadata(x: Int16(x), y: Int16(y))
    }
}

private struct ActiveAdmissionRequest {
    var feature: MediaStreamClass.Feature
    var sessionDurationLimitSeconds: Int?
    var sessionByteBudget: Int64?
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

enum MediaSessionError: Error, Equatable, LocalizedError {
    case denied(reason: MediaCapabilityDenialReason)
    case captureFailed
    case encodeFailed

    var errorDescription: String? {
        switch self {
        case .denied(let reason):
            switch reason {
            case .entitlementMissing:
                return "Screen sharing requires an active Cloud Pro or Ultra subscription."
            case .entitlementExpired:
                return "The screen-sharing subscription has expired."
            case .dailyCapReached:
                return "The daily screen-sharing limit has been reached."
            case .sessionCapReached:
                return "This screen-sharing session reached its limit."
            case .concurrentSessionCapReached:
                return "Too many screen-sharing sessions are already active."
            case .budgetSoftCapReached:
                return "Screen sharing is temporarily limited by the service budget."
            case .budgetHardCapReached:
                return "Screen sharing is temporarily unavailable because the service budget was reached."
            case .killSwitchActive:
                return "Screen sharing is temporarily disabled."
            }
        case .captureFailed:
            return "The Mac could not start screen capture."
        case .encodeFailed:
            return "The Mac could not start the video encoder."
        }
    }
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
