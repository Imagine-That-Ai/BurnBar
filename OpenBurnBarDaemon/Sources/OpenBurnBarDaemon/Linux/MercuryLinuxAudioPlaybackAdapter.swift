#if os(Linux)
import COpenBurnBarMediaCapture
import Foundation
import OpenBurnBarMedia

/// Native playback boundary for inbound Mercury Opus packets.
///
/// The daemon owns the authenticated route and therefore owns the decision to
/// render a remote packet. The adapter itself is deliberately small: the
/// GStreamer pipeline lives in the shared Linux media crate and this type
/// keeps the C pointer lifecycle and fail-closed behavior in Swift.
public protocol MercuryLinuxAudioPlaybackAdapterProtocol: Sendable {
    func startIfNeeded() throws
    func play(_ frame: MediaFrame) throws
    func stop()
}

public enum MercuryLinuxAudioPlaybackError: Error, LocalizedError, Equatable {
    case mediaCrateUnavailable
    case unsupportedFormat
    case startFailed
    case notStarted
    case pushFailed

    public var errorDescription: String? {
        switch self {
        case .mediaCrateUnavailable:
            return "Linux Mercury audio playback is unavailable in this build."
        case .unsupportedFormat:
            return "Linux Mercury audio playback requires 48 kHz mono Opus packets."
        case .startFailed:
            return "Linux Mercury audio playback could not open the native output sink."
        case .notStarted:
            return "Linux Mercury audio playback has no active native pipeline."
        case .pushFailed:
            return "Linux Mercury audio playback rejected an Opus packet."
        }
    }
}

// AUDIT(@unchecked Sendable): the native pipeline handle and lifecycle state
// are serialized by `lock`; sendable-allowlist: internal-lock-snapshot-store
public final class MercuryLinuxGStreamerAudioPlaybackAdapter:
    MercuryLinuxAudioPlaybackAdapterProtocol,
    @unchecked Sendable { // sendable-allowlist: internal-lock-snapshot-store
    private let lock = NSLock()
    private var pipeline: UnsafeMutableRawPointer?
    private let sampleRate: UInt32
    private let channels: UInt8

    public init(sampleRate: UInt32 = 48_000, channels: UInt8 = 1) {
        self.sampleRate = sampleRate
        self.channels = channels
    }

    deinit {
        stop()
    }

    public func startIfNeeded() throws {
        lock.lock()
        defer { lock.unlock() }
        guard pipeline == nil else { return }
        guard sampleRate == 48_000, channels == 1 else {
            throw MercuryLinuxAudioPlaybackError.unsupportedFormat
        }
#if OPENBURNBAR_MEDIA_CAPTURE_LINKED
        guard let created = media_audio_playback_start(sampleRate, channels) else {
            throw MercuryLinuxAudioPlaybackError.startFailed
        }
        pipeline = created
#else
        throw MercuryLinuxAudioPlaybackError.mediaCrateUnavailable
#endif
    }

    public func play(_ frame: MediaFrame) throws {
        guard frame.kind == .audioOpus else { return }
        guard frame.payload.isEmpty == false else {
            throw MercuryLinuxAudioPlaybackError.pushFailed
        }
        lock.lock()
        defer { lock.unlock() }
        guard let pipeline else {
            throw MercuryLinuxAudioPlaybackError.notStarted
        }
#if OPENBURNBAR_MEDIA_CAPTURE_LINKED
        let accepted = frame.payload.withUnsafeBytes { bytes in
            media_audio_playback_push(
                pipeline,
                bytes.bindMemory(to: UInt8.self).baseAddress,
                bytes.count,
                frame.presentationTimestampMillis
            )
        }
        guard accepted == 0 else {
            throw MercuryLinuxAudioPlaybackError.pushFailed
        }
#else
        throw MercuryLinuxAudioPlaybackError.mediaCrateUnavailable
#endif
    }

    public func stop() {
        lock.lock()
        let oldPipeline = pipeline
        pipeline = nil
        lock.unlock()
#if OPENBURNBAR_MEDIA_CAPTURE_LINKED
        if let oldPipeline {
            media_audio_playback_stop(oldPipeline)
        }
#else
        _ = oldPipeline
#endif
    }
}

// AUDIT(@unchecked Sendable): recorded frames and lifecycle counters are
// serialized by `lock`; sendable-allowlist: internal-lock-snapshot-store
/// Test double used by the daemon controller tests. It records packets but
/// never opens a desktop audio device.
public final class RecordingMercuryLinuxAudioPlaybackAdapter:
    MercuryLinuxAudioPlaybackAdapterProtocol,
    @unchecked Sendable { // sendable-allowlist: internal-lock-snapshot-store
    private let lock = NSLock()
    private var started = false
    public private(set) var startCount = 0
    public private(set) var stopCount = 0
    public private(set) var frames: [MediaFrame] = []
    public var startError: Error?
    public var playError: Error?

    public init() {}

    public func startIfNeeded() throws {
        if let startError { throw startError }
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }
        started = true
        startCount += 1
    }

    public func play(_ frame: MediaFrame) throws {
        if let playError { throw playError }
        lock.lock()
        frames.append(frame)
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        if started {
            stopCount += 1
        }
        started = false
        lock.unlock()
    }
}
#endif
