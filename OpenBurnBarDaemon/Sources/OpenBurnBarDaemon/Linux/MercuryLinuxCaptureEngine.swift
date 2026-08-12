#if os(Linux)
import COpenBurnBarMediaCapture
import Foundation
import OpenBurnBarMedia

/// Visual capture surface for Linux (mirrors `VisualCaptureSource` on macOS).
///
/// - `.cliPTY`: PTY text path (no portal, no PipeWire, no ScreenCast).
/// - `.desktopApp`: `xdg-desktop-portal` ScreenCast (`openburnbar_portal_screencast_acquire`)
///   with `grant.isLive` fail-closed check. The portal picker itself is the Linux allowlist
///   (user-selected window/display); no additional bundle filter is needed, but the `isLive`
///   + `pipeWireFD >= 0` checks remain the gate. Documented per SECURITY_REVIEW P0 #2 Linux note.
///
/// Callers resolve the effective surface via `VisualCapturePreferences` equivalent on Linux
/// (UserDefaults `visualCaptureSourceToggleEnabled` + per-provider). When the flag is off or
/// provider is CLI-only, callers must pass `.cliPTY` so the engine stays idle.
public enum LinuxVisualCaptureSource: String, Sendable, CaseIterable, Equatable {
    case cliPTY = "cli_pty"
    case desktopApp = "desktop_app"
}

public enum MercuryLinuxCaptureCodec: UInt8, Sendable, Equatable {
    case vp9 = 0
    case av1 = 1
}

public struct MercuryLinuxScreenCastGrant: Sendable, Equatable {
    public var pipeWireFD: Int32
    public var pipeWireNodeID: UInt32
    public var sessionHandle: String
    public var isLive: Bool

}

public struct MercuryLinuxCaptureRequest: Sendable, Equatable {
    enum Source: Sendable, Equatable {
        case portal(MercuryLinuxScreenCastGrant)
        case testPattern(numBuffers: UInt32)
    }

    var source: Source
    public var targetBitrateBps: UInt32
    public var codec: MercuryLinuxCaptureCodec

    public static func portal(
        _ grant: MercuryLinuxScreenCastGrant,
        targetBitrateBps: UInt32 = 1_500_000,
        codec: MercuryLinuxCaptureCodec = .vp9
    ) -> MercuryLinuxCaptureRequest {
        MercuryLinuxCaptureRequest(
            source: .portal(grant),
            targetBitrateBps: targetBitrateBps,
            codec: codec
        )
    }

    static func testPattern(
        numBuffers: UInt32 = 30,
        targetBitrateBps: UInt32 = 600_000,
        codec: MercuryLinuxCaptureCodec = .vp9
    ) -> MercuryLinuxCaptureRequest {
        MercuryLinuxCaptureRequest(
            source: .testPattern(numBuffers: numBuffers),
            targetBitrateBps: targetBitrateBps,
            codec: codec
        )
    }

    private init(
        source: Source,
        targetBitrateBps: UInt32,
        codec: MercuryLinuxCaptureCodec
    ) {
        self.source = source
        self.targetBitrateBps = targetBitrateBps
        self.codec = codec
    }
}

public enum MercuryLinuxCaptureError: Error, LocalizedError, Equatable {
    case invalidPipeWireFD(Int32)
    case portalConsentNotLive
    case mediaCrateUnavailable
    case startFailed
    case noActivePipeline
    case sessionNotStreaming

    public var errorDescription: String? {
        switch self {
        case .invalidPipeWireFD(let fd):
            return "PipeWire fd \(fd) is invalid for Linux Mercury capture."
        case .portalConsentNotLive:
            return "Linux Mercury capture requires a live portal ScreenCast grant."
        case .mediaCrateUnavailable:
            return "Linux Mercury media capture crate is not linked in this build."
        case .startFailed:
            return "Linux Mercury capture failed to start."
        case .noActivePipeline:
            return "Linux Mercury capture has no active pipeline."
        case .sessionNotStreaming:
            return "Linux Mercury capture requires an active mirror streaming session."
        }
    }
}

public struct MercuryLinuxMediaCapabilities: Sendable, Equatable {
    public var capabilitiesKnown: Bool
    public var vp9Encode: Bool
    public var vp9Decode: Bool
    public var av1Encode: Bool
    public var av1Decode: Bool
    public var opusEncode: Bool
    public var opusDecode: Bool
    public var pipeWireSource: Bool
    public var audioPlaybackSink: Bool = false

    public var daemonCodecMap: [String: Bool] {
        [
            "vp9": vp9Encode && pipeWireSource,
            "opus": opusEncode && pipeWireSource,
            "opusPlayback": opusDecode && audioPlaybackSink,
            "h264": false,
            "av1": av1Encode && pipeWireSource
        ]
    }

    static func probe() -> MercuryLinuxMediaCapabilities {
        #if OPENBURNBAR_MEDIA_CAPTURE_LINKED
        let raw = media_capability_probe()
        return MercuryLinuxMediaCapabilities(
            capabilitiesKnown: raw.backend_available != 0,
            vp9Encode: raw.vp9enc != 0,
            vp9Decode: raw.vp9dec != 0,
            av1Encode: raw.av1enc != 0,
            av1Decode: raw.av1dec != 0,
            opusEncode: raw.opusenc != 0,
            opusDecode: raw.opusdec != 0,
            pipeWireSource: raw.pipewiresrc != 0,
            audioPlaybackSink: media_audio_playback_probe() != 0
        )
        #else
        return MercuryLinuxMediaCapabilities(
            capabilitiesKnown: false,
            vp9Encode: false,
            vp9Decode: false,
            av1Encode: false,
            av1Decode: false,
            opusEncode: false,
            opusDecode: false,
            pipeWireSource: false,
            audioPlaybackSink: false
        )
        #endif
    }
}

private final class MercuryLinuxCaptureCallbackBox: Sendable {
    let onFrame: @Sendable (MediaFrame) -> Void
    let onStopped: @Sendable (String) -> Void

    init(
        onFrame: @escaping @Sendable (MediaFrame) -> Void,
        onStopped: @escaping @Sendable (String) -> Void
    ) {
        self.onFrame = onFrame
        self.onStopped = onStopped
    }
}

private typealias MercuryLinuxCaptureFrameCallback =
    @convention(c) (UnsafePointer<UInt8>?, Int, UInt64, UInt8, UnsafeMutableRawPointer?) -> Void

private let mercuryLinuxCaptureFrameCallback: MercuryLinuxCaptureFrameCallback = { payload, len, ptsMS, flags, userData in
        guard let payload, let userData, len > 0 else { return }
        let box = Unmanaged<MercuryLinuxCaptureCallbackBox>
            .fromOpaque(userData)
            .takeUnretainedValue()
        let frame = MediaFrame(
            kind: .videoNAL,
            flags: MediaFrame.Flags(rawValue: flags),
            presentationTimestampMillis: ptsMS,
            payload: Data(bytes: payload, count: len)
        )
        box.onFrame(frame)
    }

private typealias MercuryLinuxCaptureStoppedCallback =
    @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, Int) -> Void

private let mercuryLinuxCaptureStoppedCallback: MercuryLinuxCaptureStoppedCallback = { userData, reasonPointer, reasonLength in
        guard let userData else { return }
        let box = Unmanaged<MercuryLinuxCaptureCallbackBox>
            .fromOpaque(userData)
            .takeUnretainedValue()
        let reason: String
        if let reasonPointer, reasonLength > 0 {
            reason = String(
                decoding: UnsafeRawBufferPointer(start: reasonPointer, count: reasonLength),
                as: UTF8.self
            )
        } else {
            reason = "capture_pipeline_ended"
        }
        box.onStopped(reason)
    }

/// Convenience branching for visual surface (Subagent C). Mirrors macOS `MacScreenshotService` / `ScreenCapturePipeline` guards.
public extension MercuryLinuxCaptureEngine {
    /// Start capture branched on visual surface.
    ///
    /// - `.cliPTY`: caller should NOT call the portal path at all; PTY text is streamed via
    ///   the existing `PTYInteractiveSession` path (no PipeWire). This method throws
    ///   `portalConsentNotLive` if mistakenly called with `.cliPTY` + portal request, but
    ///   the intended PTY path is to skip the engine entirely.
    /// - `.desktopApp`: validates `grant.isLive` + `pipeWireFD` and starts the portal-backed pipeline.
    func start(
        for surface: LinuxVisualCaptureSource,
        request: MercuryLinuxCaptureRequest,
        onFrame: @escaping @Sendable (MediaFrame) -> Void,
        onStopped: @escaping @Sendable (String) -> Void = { _ in }
    ) throws {
        switch surface {
        case .cliPTY:
            // PTY path must NOT touch xdg-desktop-portal or PipeWire. Caller should stream PTY bytes
            // directly (256KB bounded). We fail closed if a portal request is mistakenly supplied.
            // No `grant.isLive` check needed — PTY has no consent.
            throw MercuryLinuxCaptureError.portalConsentNotLive
        case .desktopApp:
            try start(request, onFrame: onFrame, onStopped: onStopped)
        }
    }
}

public protocol MercuryLinuxCaptureEngineProtocol: Sendable {
    func start(
        _ request: MercuryLinuxCaptureRequest,
        onFrame: @escaping @Sendable (MediaFrame) -> Void,
        onStopped: @escaping @Sendable (String) -> Void
    ) throws
    func stop()
    func setBitrate(_ targetBitrateBps: UInt32) throws
}

// AUDIT: Opaque GStreamer pipeline/context pointers are mutable only while the
// recursive lifecycle lock is held; the C ABI cannot express that ownership.
// sendable-allowlist: internal-lock-snapshot-store
public final class MercuryLinuxCaptureEngine: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var pipeline: UnsafeMutableRawPointer?
    private var callbackContext: UnsafeMutableRawPointer?

    public init() {}

    deinit {
        stop()
    }

    public func start(
        _ request: MercuryLinuxCaptureRequest,
        onFrame: @escaping @Sendable (MediaFrame) -> Void,
        onStopped: @escaping @Sendable (String) -> Void = { _ in }
    ) throws {
        if case .portal(let grant) = request.source {
            guard grant.isLive else {
                throw MercuryLinuxCaptureError.portalConsentNotLive
            }
            guard grant.pipeWireFD >= 0 else {
                throw MercuryLinuxCaptureError.invalidPipeWireFD(grant.pipeWireFD)
            }
        }
        #if OPENBURNBAR_MEDIA_CAPTURE_LINKED
        lock.lock()
        defer { lock.unlock() }

        let pipelineStarter: (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer?
        switch request.source {
        case .portal(let grant):
            pipelineStarter = { context in
                media_capture_start(
                    grant.pipeWireFD,
                    grant.pipeWireNodeID,
                    request.targetBitrateBps,
                    request.codec.rawValue,
                    mercuryLinuxCaptureFrameCallback,
                    mercuryLinuxCaptureStoppedCallback,
                    context
                )
            }
        case .testPattern(let numBuffers):
            pipelineStarter = { context in
                media_capture_start_test(
                    numBuffers,
                    request.targetBitrateBps,
                    request.codec.rawValue,
                    mercuryLinuxCaptureFrameCallback,
                    mercuryLinuxCaptureStoppedCallback,
                    context
                )
            }
        }

        stopLocked()

        let callbackBox = MercuryLinuxCaptureCallbackBox(onFrame: onFrame, onStopped: onStopped)
        let context = Unmanaged.passRetained(callbackBox).toOpaque()
        guard let pipeline = pipelineStarter(context) else {
            Unmanaged<MercuryLinuxCaptureCallbackBox>.fromOpaque(context).release()
            throw MercuryLinuxCaptureError.startFailed
        }

        self.pipeline = pipeline
        self.callbackContext = context
        #else
        _ = request
        _ = onFrame
        _ = onStopped
        throw MercuryLinuxCaptureError.mediaCrateUnavailable
        #endif
    }

    public func stop() {
        #if OPENBURNBAR_MEDIA_CAPTURE_LINKED
        lock.lock()
        defer { lock.unlock() }
        stopLocked()
        #else
        lock.lock()
        defer { lock.unlock() }
        pipeline = nil
        callbackContext = nil
        #endif
    }

    #if OPENBURNBAR_MEDIA_CAPTURE_LINKED
    private func stopLocked() {
        let oldPipeline = pipeline
        let oldContext = callbackContext
        pipeline = nil
        callbackContext = nil

        if let oldPipeline {
            media_capture_stop(oldPipeline)
        }
        if let oldContext {
            Unmanaged<MercuryLinuxCaptureCallbackBox>
                .fromOpaque(oldContext)
                .release()
        }
    }
    #endif

    public func setBitrate(_ targetBitrateBps: UInt32) throws {
        #if OPENBURNBAR_MEDIA_CAPTURE_LINKED
        lock.lock()
        defer { lock.unlock() }
        let activePipeline = pipeline
        guard let activePipeline else {
            throw MercuryLinuxCaptureError.noActivePipeline
        }
        media_capture_set_bitrate(activePipeline, targetBitrateBps)
        #else
        _ = targetBitrateBps
        throw MercuryLinuxCaptureError.mediaCrateUnavailable
        #endif
    }

    public static func mediaCapabilities() -> MercuryLinuxMediaCapabilities {
        MercuryLinuxMediaCapabilities.probe()
    }
}

extension MercuryLinuxCaptureEngine: MercuryLinuxCaptureEngineProtocol {}

/// A portal-backed Opus capture request. Audio is kept separate from the
/// screen-share request because PipeWire grants are source-specific and the
/// receiver must negotiate `MediaFrame.Kind.audioOpus` independently.
public struct MercuryLinuxAudioCaptureRequest: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        case portal(MercuryLinuxScreenCastGrant)
        case testPattern(numBuffers: UInt32)
    }

    public var source: Source

    public static func portal(
        _ grant: MercuryLinuxScreenCastGrant
    ) -> MercuryLinuxAudioCaptureRequest {
        MercuryLinuxAudioCaptureRequest(source: .portal(grant))
    }

    /// Test-only source. It is never selected by the production portal adapter.
    static func testPattern(
        numBuffers: UInt32 = 10
    ) -> MercuryLinuxAudioCaptureRequest {
        MercuryLinuxAudioCaptureRequest(source: .testPattern(numBuffers: numBuffers))
    }

    private init(source: Source) {
        self.source = source
    }
}

public enum MercuryLinuxAudioCaptureError: Error, LocalizedError, Equatable {
    case invalidPipeWireFD(Int32)
    case portalConsentNotLive
    case mediaCrateUnavailable
    case startFailed
    case noActivePipeline

    public var errorDescription: String? {
        switch self {
        case .invalidPipeWireFD(let fd):
            return "PipeWire fd \(fd) is invalid for Linux Mercury audio capture."
        case .portalConsentNotLive:
            return "Linux Mercury audio capture requires a live portal grant."
        case .mediaCrateUnavailable:
            return "Linux Mercury audio capture is not linked in this build."
        case .startFailed:
            return "Linux Mercury audio capture failed to start."
        case .noActivePipeline:
            return "Linux Mercury audio capture has no active pipeline."
        }
    }
}

private final class MercuryLinuxAudioCaptureCallbackBox: Sendable {
    let onFrame: @Sendable (MediaFrame) -> Void
    let onStopped: @Sendable (String) -> Void

    init(
        onFrame: @escaping @Sendable (MediaFrame) -> Void,
        onStopped: @escaping @Sendable (String) -> Void
    ) {
        self.onFrame = onFrame
        self.onStopped = onStopped
    }
}

private typealias MercuryLinuxAudioCaptureFrameCallback =
    @convention(c) (UnsafePointer<UInt8>?, Int, UInt64, UInt8, UnsafeMutableRawPointer?) -> Void

private let mercuryLinuxAudioCaptureFrameCallback: MercuryLinuxAudioCaptureFrameCallback = { payload, len, ptsMS, flags, userData in
    guard let payload, let userData, len > 0 else { return }
    let box = Unmanaged<MercuryLinuxAudioCaptureCallbackBox>
        .fromOpaque(userData)
        .takeUnretainedValue()
    box.onFrame(MediaFrame(
        kind: .audioOpus,
        flags: MediaFrame.Flags(rawValue: flags),
        presentationTimestampMillis: ptsMS,
        payload: Data(bytes: payload, count: len)
    ))
}

private typealias MercuryLinuxAudioCaptureStoppedCallback =
    @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, Int) -> Void

private let mercuryLinuxAudioCaptureStoppedCallback: MercuryLinuxAudioCaptureStoppedCallback = { userData, reasonPointer, reasonLength in
    guard let userData else { return }
    let box = Unmanaged<MercuryLinuxAudioCaptureCallbackBox>
        .fromOpaque(userData)
        .takeUnretainedValue()
    let reason: String
    if let reasonPointer, reasonLength > 0 {
        reason = String(
            decoding: UnsafeRawBufferPointer(start: reasonPointer, count: reasonLength),
            as: UTF8.self
        )
    } else {
        reason = "audio_capture_pipeline_ended"
    }
    box.onStopped(reason)
}

public protocol MercuryLinuxAudioCaptureEngineProtocol: Sendable {
    func start(
        _ request: MercuryLinuxAudioCaptureRequest,
        onFrame: @escaping @Sendable (MediaFrame) -> Void,
        onStopped: @escaping @Sendable (String) -> Void
    ) throws
    func stop()
}

// AUDIT: Native pipeline/context pointers are touched only under the
// lifecycle lock. The C ABI cannot express that ownership.
// sendable-allowlist: internal-lock-snapshot-store
public final class MercuryLinuxAudioCaptureEngine: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var pipeline: UnsafeMutableRawPointer?
    private var callbackContext: UnsafeMutableRawPointer?

    public init() {}

    deinit {
        stop()
    }

    public func start(
        _ request: MercuryLinuxAudioCaptureRequest,
        onFrame: @escaping @Sendable (MediaFrame) -> Void,
        onStopped: @escaping @Sendable (String) -> Void = { _ in }
    ) throws {
        if case .portal(let grant) = request.source {
            guard grant.isLive else {
                throw MercuryLinuxAudioCaptureError.portalConsentNotLive
            }
            guard grant.pipeWireFD >= 0 else {
                throw MercuryLinuxAudioCaptureError.invalidPipeWireFD(grant.pipeWireFD)
            }
        }
        #if OPENBURNBAR_MEDIA_CAPTURE_LINKED
        lock.lock()
        defer { lock.unlock() }

        let pipelineStarter: (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer?
        switch request.source {
        case .portal(let grant):
            pipelineStarter = { context in
                media_audio_capture_start(
                    grant.pipeWireFD,
                    grant.pipeWireNodeID,
                    mercuryLinuxAudioCaptureFrameCallback,
                    mercuryLinuxAudioCaptureStoppedCallback,
                    context
                )
            }
        case .testPattern(let numBuffers):
            pipelineStarter = { context in
                media_audio_capture_start_test(
                    numBuffers,
                    mercuryLinuxAudioCaptureFrameCallback,
                    mercuryLinuxAudioCaptureStoppedCallback,
                    context
                )
            }
        }

        stopLocked()
        let callbackBox = MercuryLinuxAudioCaptureCallbackBox(onFrame: onFrame, onStopped: onStopped)
        let context = Unmanaged.passRetained(callbackBox).toOpaque()
        guard let pipeline = pipelineStarter(context) else {
            Unmanaged<MercuryLinuxAudioCaptureCallbackBox>.fromOpaque(context).release()
            throw MercuryLinuxAudioCaptureError.startFailed
        }
        self.pipeline = pipeline
        self.callbackContext = context
        #else
        _ = request
        _ = onFrame
        _ = onStopped
        throw MercuryLinuxAudioCaptureError.mediaCrateUnavailable
        #endif
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        #if OPENBURNBAR_MEDIA_CAPTURE_LINKED
        stopLocked()
        #else
        pipeline = nil
        callbackContext = nil
        #endif
    }

    #if OPENBURNBAR_MEDIA_CAPTURE_LINKED
    private func stopLocked() {
        let oldPipeline = pipeline
        let oldContext = callbackContext
        pipeline = nil
        callbackContext = nil
        if let oldPipeline {
            media_capture_stop(oldPipeline)
        }
        if let oldContext {
            Unmanaged<MercuryLinuxAudioCaptureCallbackBox>
                .fromOpaque(oldContext)
                .release()
        }
    }
    #endif
}

extension MercuryLinuxAudioCaptureEngine: MercuryLinuxAudioCaptureEngineProtocol {}
#endif
