#if os(Linux)
import COpenBurnBarMediaCapture
import Foundation
import OpenBurnBarMedia

public enum MercuryLinuxCaptureCodec: UInt8, Sendable, Equatable {
    case vp9 = 0
    case av1 = 1
}

public struct MercuryLinuxCaptureRequest: Sendable, Equatable {
    public var pipeWireFD: Int32
    public var pipeWireNodeID: UInt32
    public var targetBitrateBps: UInt32
    public var codec: MercuryLinuxCaptureCodec

    public init(
        pipeWireFD: Int32,
        pipeWireNodeID: UInt32,
        targetBitrateBps: UInt32 = 1_500_000,
        codec: MercuryLinuxCaptureCodec = .vp9
    ) {
        self.pipeWireFD = pipeWireFD
        self.pipeWireNodeID = pipeWireNodeID
        self.targetBitrateBps = targetBitrateBps
        self.codec = codec
    }
}

public enum MercuryLinuxCaptureError: Error, LocalizedError, Equatable {
    case invalidPipeWireFD(Int32)
    case startFailed
    case noActivePipeline
    case sessionNotStreaming

    public var errorDescription: String? {
        switch self {
        case .invalidPipeWireFD(let fd):
            return "PipeWire fd \(fd) is invalid for Linux Mercury capture."
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
    public var vp9Encode: Bool
    public var vp9Decode: Bool
    public var av1Encode: Bool
    public var av1Decode: Bool
    public var opusEncode: Bool
    public var opusDecode: Bool
    public var pipeWireSource: Bool

    public var daemonCodecMap: [String: Bool] {
        [
            "vp9": vp9Encode && pipeWireSource,
            "opus": opusEncode && pipeWireSource,
            "h264": false,
            "av1": av1Encode && pipeWireSource
        ]
    }

    static func probe() -> MercuryLinuxMediaCapabilities {
        let raw = media_capability_probe()
        return MercuryLinuxMediaCapabilities(
            vp9Encode: raw.vp9enc != 0,
            vp9Decode: raw.vp9dec != 0,
            av1Encode: raw.av1enc != 0,
            av1Decode: raw.av1dec != 0,
            opusEncode: raw.opusenc != 0,
            opusDecode: raw.opusdec != 0,
            pipeWireSource: raw.pipewiresrc != 0
        )
    }
}

private final class MercuryLinuxCaptureCallbackBox: @unchecked Sendable {
    let onFrame: @Sendable (MediaFrame) -> Void

    init(onFrame: @escaping @Sendable (MediaFrame) -> Void) {
        self.onFrame = onFrame
    }
}

private let mercuryLinuxCaptureFrameCallback:
    @convention(c) (UnsafePointer<UInt8>?, Int, UInt64, UInt8, UnsafeMutableRawPointer?) -> Void = {
        payload,
        len,
        ptsMS,
        flags,
        userData in
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

public final class MercuryLinuxCaptureEngine: @unchecked Sendable {
    private let lock = NSLock()
    private var pipeline: UnsafeMutableRawPointer?
    private var callbackContext: UnsafeMutableRawPointer?

    public init() {}

    deinit {
        stop()
    }

    public func start(
        _ request: MercuryLinuxCaptureRequest,
        onFrame: @escaping @Sendable (MediaFrame) -> Void
    ) throws {
        guard request.pipeWireFD >= 0 else {
            throw MercuryLinuxCaptureError.invalidPipeWireFD(request.pipeWireFD)
        }

        stop()

        let callbackBox = MercuryLinuxCaptureCallbackBox(onFrame: onFrame)
        let context = Unmanaged.passRetained(callbackBox).toOpaque()
        guard let pipeline = media_capture_start(
            request.pipeWireFD,
            request.pipeWireNodeID,
            request.targetBitrateBps,
            request.codec.rawValue,
            mercuryLinuxCaptureFrameCallback,
            context
        ) else {
            Unmanaged<MercuryLinuxCaptureCallbackBox>.fromOpaque(context).release()
            throw MercuryLinuxCaptureError.startFailed
        }

        lock.lock()
        self.pipeline = pipeline
        self.callbackContext = context
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        let oldPipeline = pipeline
        let oldContext = callbackContext
        pipeline = nil
        callbackContext = nil
        lock.unlock()

        if let oldPipeline {
            media_capture_stop(oldPipeline)
        }
        if let oldContext {
            Unmanaged<MercuryLinuxCaptureCallbackBox>
                .fromOpaque(oldContext)
                .release()
        }
    }

    public func setBitrate(_ targetBitrateBps: UInt32) throws {
        lock.lock()
        let activePipeline = pipeline
        lock.unlock()

        guard let activePipeline else {
            throw MercuryLinuxCaptureError.noActivePipeline
        }
        media_capture_set_bitrate(activePipeline, targetBitrateBps)
    }

    public static func mediaCapabilities() -> MercuryLinuxMediaCapabilities {
        MercuryLinuxMediaCapabilities.probe()
    }
}
#endif
