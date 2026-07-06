import Foundation
import OpenBurnBarCore

extension BurnBarDaemonServer {
    func handleMediaRPC(
        method: BurnBarRPCMethod,
        decoder: JSONDecoder,
        request: BurnBarRPCRequestEnvelope,
        requestData: Data
    ) async throws -> Data {
        switch method {
        case .daemonMediaSessionState:
            #if os(Linux)
            let result = DaemonMediaSessionStateResponse(session: await mediaService.sessionSnapshot())
            #else
            let result = DaemonMediaSessionStateResponse(session: Self.unavailableMediaSessionSnapshot())
            #endif
            return encode(BurnBarRPCResponseEnvelope(id: request.id, result: result))

        case .daemonMediaCapabilityGet:
            #if os(Linux)
            let result = await mediaService.capability()
            #else
            let result = Self.unavailableMediaCapability()
            #endif
            return encode(BurnBarRPCResponseEnvelope(id: request.id, result: result))

        case .daemonMediaStatus:
            #if os(Linux)
            let result = await mediaService.status()
            #else
            let result = DaemonMediaStatusResponse(
                capability: Self.unavailableMediaCapability(),
                session: Self.unavailableMediaSessionSnapshot()
            )
            #endif
            return encode(BurnBarRPCResponseEnvelope(id: request.id, result: result))

        case .daemonMediaCallAccept:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<DaemonMediaCallAcceptRequest>.self,
                from: requestData
            )
            #if os(Linux)
            let result = await mediaService.accept(typedRequest.params)
            #else
            let result = DaemonMediaCallActionResponse(
                accepted: false,
                session: Self.unavailableMediaSessionSnapshot(),
                detail: "Linux Mercury media is unavailable on this platform."
            )
            #endif
            return encode(BurnBarRPCResponseEnvelope(id: typedRequest.id, result: result))

        case .daemonMediaCallDecline:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<DaemonMediaCallDeclineRequest>.self,
                from: requestData
            )
            #if os(Linux)
            let result = await mediaService.decline(typedRequest.params)
            #else
            let result = DaemonMediaCallActionResponse(
                accepted: false,
                session: Self.unavailableMediaSessionSnapshot(),
                detail: "Linux Mercury media is unavailable on this platform."
            )
            #endif
            return encode(BurnBarRPCResponseEnvelope(id: typedRequest.id, result: result))

        case .daemonMediaCallEnd:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<DaemonMediaCallEndRequest>.self,
                from: requestData
            )
            #if os(Linux)
            let result = await mediaService.end(typedRequest.params)
            #else
            let result = DaemonMediaCallActionResponse(
                accepted: false,
                session: Self.unavailableMediaSessionSnapshot(),
                detail: "Linux Mercury media is unavailable on this platform."
            )
            #endif
            return encode(BurnBarRPCResponseEnvelope(id: typedRequest.id, result: result))

        default:
            preconditionFailure("Unhandled media RPC method: \(method.rawValue)")
        }
    }

    private nonisolated static func unavailableMediaCapability() -> DaemonMediaCapabilityResponse {
        DaemonMediaCapabilityResponse(
            platform: "non-linux",
            available: false,
            mediaSocketPath: nil,
            supportsDaemonToShellFrames: false,
            supportsShellToDaemonControl: false,
            codecsKnown: false,
            codecs: [:],
            source: "platform-unavailable",
            detail: "Linux Mercury media is unavailable on this platform."
        )
    }

    private nonisolated static func unavailableMediaSessionSnapshot() -> DaemonMediaSessionSnapshot {
        DaemonMediaSessionSnapshot(
            phase: .idle,
            updatedAt: Date(),
            shellConnected: false,
            queuedFrameCount: 0,
            droppedFrameCount: 0
        )
    }
}
