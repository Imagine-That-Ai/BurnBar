#if os(Linux)
import COpenBurnBarPortal
import Foundation
import OpenBurnBarCore
import OpenBurnBarMedia

public protocol MercuryLinuxScreenCastPortalClient: Sendable {
    func acquireScreenCastConsent() async throws -> MercuryLinuxScreenCastGrant
    func closeScreenCastSession(_ grant: MercuryLinuxScreenCastGrant) async
}

public enum MercuryLinuxScreenCastPortalError: Error, LocalizedError, Equatable {
    case unavailable(String)
    case denied(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let detail):
            return "Linux ScreenCast portal is unavailable: \(detail)"
        case .denied(let detail):
            return "Linux ScreenCast portal consent was denied: \(detail)"
        }
    }
}

public final class MercuryLinuxGDBusScreenCastPortalClient: MercuryLinuxScreenCastPortalClient, Sendable {
    private let sourceTypes: UInt32
    private let cursorMode: UInt32
    private let timeoutMillis: UInt32

    public init(
        sourceTypes: UInt32 = 1,
        cursorMode: UInt32 = 2,
        timeoutMillis: UInt32 = 60_000
    ) {
        self.sourceTypes = sourceTypes
        self.cursorMode = cursorMode
        self.timeoutMillis = timeoutMillis
    }

    public func acquireScreenCastConsent() async throws -> MercuryLinuxScreenCastGrant {
        let sourceTypes = sourceTypes
        let cursorMode = cursorMode
        let timeoutMillis = timeoutMillis
        return try await Task.detached(priority: .userInitiated) {
            var rawGrant = OpenBurnBarPortalScreenCastGrant()
            var rawError = OpenBurnBarPortalError()
            let result = openburnbar_portal_screencast_acquire(
                sourceTypes,
                cursorMode,
                timeoutMillis,
                &rawGrant,
                &rawError
            )
            guard result == 0 else {
                let detail = portalString(from: &rawError.message)
                if rawError.code >= 100 {
                    throw MercuryLinuxScreenCastPortalError.denied(detail)
                }
                throw MercuryLinuxScreenCastPortalError.unavailable(detail)
            }
            var sessionHandle = rawGrant.session_handle
            return MercuryLinuxScreenCastGrant(
                pipeWireFD: rawGrant.pipewire_fd,
                pipeWireNodeID: rawGrant.pipewire_node_id,
                sessionHandle: portalString(from: &sessionHandle),
                isLive: rawGrant.live != 0
            )
        }.value
    }

    public func closeScreenCastSession(_ grant: MercuryLinuxScreenCastGrant) async {
        let sessionHandle = grant.sessionHandle
        await Task.detached {
            var bytes = Array(sessionHandle.utf8CString)
            bytes.withUnsafeMutableBufferPointer { buffer in
                openburnbar_portal_screencast_close(buffer.baseAddress)
            }
        }.value
    }
}

public protocol MercuryLinuxCaptureAdapterProtocol: Sendable {
    func startOutboundCapture(
        targetBitrateBps: UInt32,
        codec: MercuryLinuxCaptureCodec,
        onFrame: @escaping @Sendable (MediaFrame) -> Void,
        onStopped: @escaping @Sendable (String) -> Void
    ) async throws
    func stopOutboundCapture()
    func setOutboundCaptureBitrate(_ targetBitrateBps: UInt32) throws
}

public final class MercuryLinuxCaptureAdapter: MercuryLinuxCaptureAdapterProtocol, Sendable {
    private let portalClient: any MercuryLinuxScreenCastPortalClient
    private let captureEngine: any MercuryLinuxCaptureEngineProtocol
    private let activeGrant = Locked<MercuryLinuxScreenCastGrant?>(nil)

    public init(
        portalClient: any MercuryLinuxScreenCastPortalClient = MercuryLinuxGDBusScreenCastPortalClient(),
        captureEngine: any MercuryLinuxCaptureEngineProtocol = MercuryLinuxCaptureEngine()
    ) {
        self.portalClient = portalClient
        self.captureEngine = captureEngine
    }

    public func startOutboundCapture(
        targetBitrateBps: UInt32,
        codec: MercuryLinuxCaptureCodec = .vp9,
        onFrame: @escaping @Sendable (MediaFrame) -> Void,
        onStopped: @escaping @Sendable (String) -> Void
    ) async throws {
        let grant = try await portalClient.acquireScreenCastConsent()
        guard grant.isLive else {
            await portalClient.closeScreenCastSession(grant)
            throw MercuryLinuxCaptureError.portalConsentNotLive
        }
        do {
            try captureEngine.start(
                .portal(grant, targetBitrateBps: targetBitrateBps, codec: codec),
                onFrame: onFrame,
                onStopped: onStopped
            )
            activeGrant.withLock { $0 = grant }
        } catch {
            await portalClient.closeScreenCastSession(grant)
            throw error
        }
    }

    public func stopOutboundCapture() {
        captureEngine.stop()
        let grant = takeActiveGrant()
        if let grant {
            Task.detached { [portalClient] in
                await portalClient.closeScreenCastSession(grant)
            }
        }
    }

    public func setOutboundCaptureBitrate(_ targetBitrateBps: UInt32) throws {
        try captureEngine.setBitrate(targetBitrateBps)
    }

    private func takeActiveGrant() -> MercuryLinuxScreenCastGrant? {
        activeGrant.withLock { grant in
            let current = grant
            grant = nil
            return current
        }
    }
}

final class MercuryLinuxCaptureFrameQueue: Sendable {
    let stream: AsyncStream<MediaFrame>
    private let continuation: Locked<AsyncStream<MediaFrame>.Continuation?>

    init(bufferingNewest count: Int) {
        let pair = AsyncStream.makeStream(
            of: MediaFrame.self,
            bufferingPolicy: .bufferingNewest(count)
        )
        stream = pair.stream
        continuation = Locked(pair.continuation)
    }

    func offer(_ frame: MediaFrame) {
        continuation.read()?.yield(frame)
    }

    func finish() {
        continuation.withLock { stored in
            stored?.finish()
            stored = nil
        }
    }
}

private func portalString<T>(from storage: inout T) -> String {
    withUnsafeBytes(of: &storage) { rawBuffer in
        let bytes = rawBuffer.prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }
}
#endif
