import Foundation
import OpenBurnBarCore
import OpenBurnBarIrohRelay

/// Closure type the host client injects so this handler can hand a
/// Mercury media frame off to the file-transfer service (or, in later
/// phases, the screen-share / call coordinator). Sendable so it survives
/// the actor boundary of the spawned per-stream task. `ackSender` lets
/// the dispatcher write the corresponding ack frame back on the same
/// chat stream without re-importing the stream protocol.
typealias MediaFrameDispatcher = @Sendable (
    _ frame: HermesRealtimeRelayFrame,
    _ ackSender: @Sendable (HermesRealtimeRelayFrame) async throws -> Void
) async -> Void

/// Closure type the host client injects when iOS opens a stream and
/// classifies it as the long-lived media control stream. The handler
/// hands the stream off, returns from `serve()`, and the registered
/// owner drives the read loop + outbound sends from then on. Sendable so
/// it survives the per-stream task boundary.
typealias MediaControlStreamRegistrar = @Sendable (
    _ stream: any IrohRelayStream,
    _ uid: String,
    _ connectionID: String
) async -> Void

/// Serves one inbound iroh stream: decrypts an inbound `request.start`
/// frame, forwards the request to the local Hermes gateway, and streams
/// the response back as `response.chunk` + `response.complete` frames. The
/// crypto envelope and forwarding logic are byte-identical to the WSS
/// `HermesRealtimeRelayHostClient`.
final class IrohRelayRequestHandler: Sendable {
    private let relayKeyStore: HermesRelayKeyStore
    private let urlSession: URLSession
    private let settingsManager: any SettingsManagerProtocol
    private let mediaDispatcher: MediaFrameDispatcher?
    private let mediaControlRegistrar: MediaControlStreamRegistrar?

    @MainActor
    init(
        relayKeyStore: HermesRelayKeyStore,
        urlSession: URLSession,
        settingsManager: any SettingsManagerProtocol,
        mediaDispatcher: MediaFrameDispatcher? = nil,
        mediaControlRegistrar: MediaControlStreamRegistrar? = nil
    ) {
        self.relayKeyStore = relayKeyStore
        self.urlSession = urlSession
        self.settingsManager = settingsManager
        self.mediaDispatcher = mediaDispatcher
        self.mediaControlRegistrar = mediaControlRegistrar
    }

    func serve(
        stream: any IrohRelayStream,
        uid: String,
        connectionID: String
    ) async throws {
        var classifiedAsMediaControl = false
        while let frame = try await stream.receive() {
            guard frame.uid == uid, frame.connectionId == connectionID else { continue }

            // First-frame classification — when iOS opens a stream and
            // declares it the long-lived media control stream, hand
            // ownership to the registry and return. The registry's
            // owner drives the read loop from there.
            if !classifiedAsMediaControl,
               frame.type == .mediaClassify,
               let mediaControlRegistrar,
               frame.media?.streamClass == "media.control" {
                classifiedAsMediaControl = true
                await mediaControlRegistrar(stream, uid, connectionID)
                return
            }
            switch frame.type {
            case .requestStart:
                guard let requestID = frame.requestId else {
                    try await sendError(
                        message: "Malformed realtime relay request.",
                        frame: frame,
                        stream: stream
                    )
                    continue
                }
                do {
                    try await handleRequest(
                        frame: frame,
                        requestID: requestID,
                        uid: uid,
                        connectionID: connectionID,
                        stream: stream
                    )
                } catch is CancellationError {
                    return
                } catch {
                    try await sendError(
                        message: error.localizedDescription,
                        frame: frame,
                        stream: stream
                    )
                }
            case .ping:
                try await stream.send(
                    HermesRealtimeRelayFrame(
                        type: .pong,
                        uid: uid,
                        connectionId: connectionID,
                        requestId: frame.requestId
                    )
                )
            case .requestCancel,
                 .hostReady,
                 .pong,
                 .hostRegister,
                 .responseChunk,
                 .responseComplete,
                 .responseError:
                continue
            case .mediaClassify, .mediaBlobAdvertise, .mediaBlobAck:
                guard let mediaDispatcher else { continue }
                // Wrap the stream send in a Sendable closure so the
                // dispatcher can ack without holding a reference to the
                // stream object directly.
                let ackSender: @Sendable (HermesRealtimeRelayFrame) async throws -> Void = {
                    [stream] outboundFrame in
                    try await stream.send(outboundFrame)
                }
                await mediaDispatcher(frame, ackSender)
                continue
            }
        }
    }

    private func handleRequest(
        frame: HermesRealtimeRelayFrame,
        requestID: String,
        uid: String,
        connectionID: String,
        stream: any IrohRelayStream
    ) async throws {
        guard let payload = frame.payload,
              let operation = payload.operation,
              let payloadCiphertext = payload.payloadCiphertext,
              let wrappedKey = payload.wrappedKey,
              payload.relayEncryption == HermesRelayCrypto.algorithm else {
            try await sendError(
                message: "Malformed realtime relay request.",
                frame: frame,
                stream: stream
            )
            return
        }

        let privateKey = try relayKeyStore.privateKey()
        let keyData = try HermesRelayCrypto.unwrapSymmetricKey(
            wrappedKey,
            privateKey: privateKey,
            aad: HermesRelayCrypto.keyAAD(
                uid: uid,
                connectionID: connectionID,
                requestID: requestID
            )
        )
        let requestPlaintext = try HermesRelayCrypto.openBase64(
            ciphertext: payloadCiphertext,
            keyData: keyData,
            aad: HermesRelayCrypto.requestAAD(
                uid: uid,
                connectionID: connectionID,
                requestID: requestID
            )
        )
        let encryptedPayload = try JSONDecoder().decode(
            HermesRelayEncryptedRequestPayload.self,
            from: requestPlaintext
        )

        if operation == .chatCompletions {
            try await forwardStreamingChat(
                payload: encryptedPayload,
                uid: uid,
                connectionID: connectionID,
                requestID: requestID,
                keyData: keyData,
                stream: stream
            )
            return
        }

        let body = try await forwardUnary(operation: operation, payload: encryptedPayload)
        var sequence = 0
        for fragment in HermesRelayHostService.relayDataFragments(body) {
            try Task.checkCancellation()
            try await sendChunk(
                data: fragment,
                sequence: sequence,
                kind: .data,
                uid: uid,
                connectionID: connectionID,
                requestID: requestID,
                keyData: keyData,
                stream: stream
            )
            sequence += 1
        }
        try await sendComplete(
            uid: uid,
            connectionID: connectionID,
            requestID: requestID,
            chunkCount: sequence,
            stream: stream
        )
    }

    private func forwardStreamingChat(
        payload: HermesRelayEncryptedRequestPayload,
        uid: String,
        connectionID: String,
        requestID: String,
        keyData: Data,
        stream: any IrohRelayStream
    ) async throws {
        var request = try await makeForwardRequest(operation: .chatCompletions, payload: payload)
        request.httpMethod = "POST"
        let (bytes, response) = try await urlSession.bytes(for: request)
        guard let statusCode = (response as? HTTPURLResponse)?.statusCode,
              (200..<300).contains(statusCode) else {
            throw IrohRelayHostError.invalidResponse
        }

        var eventLines: [String] = []
        var sequence = 0
        for try await line in bytes.lines {
            try Task.checkCancellation()
            for event in HermesRelayHostService.consumeSSELine(line, eventLines: &eventLines) {
                try await sendChunk(
                    data: event,
                    sequence: sequence,
                    kind: .sse,
                    uid: uid,
                    connectionID: connectionID,
                    requestID: requestID,
                    keyData: keyData,
                    stream: stream
                )
                sequence += 1
            }
        }
        if !eventLines.isEmpty {
            try await sendChunk(
                data: eventLines.joined(separator: "\n"),
                sequence: sequence,
                kind: .sse,
                uid: uid,
                connectionID: connectionID,
                requestID: requestID,
                keyData: keyData,
                stream: stream
            )
            sequence += 1
        }
        try await sendComplete(
            uid: uid,
            connectionID: connectionID,
            requestID: requestID,
            chunkCount: sequence,
            stream: stream
        )
    }

    private func forwardUnary(
        operation: HermesRelayOperation,
        payload: HermesRelayEncryptedRequestPayload
    ) async throws -> String {
        let request = try await makeForwardRequest(operation: operation, payload: payload)
        let (body, response) = try await urlSession.data(for: request)
        guard let statusCode = (response as? HTTPURLResponse)?.statusCode,
              (200..<300).contains(statusCode) else {
            throw IrohRelayHostError.invalidResponse
        }
        return String(data: body, encoding: .utf8) ?? ""
    }

    @MainActor
    private func makeForwardRequest(
        operation: HermesRelayOperation,
        payload: HermesRelayEncryptedRequestPayload
    ) async throws -> URLRequest {
        let path: String
        switch operation {
        case .chatCompletions:
            path = "v1/chat/completions"
        case .models:
            path = "v1/models"
        case .sessions:
            path = "api/sessions"
        case .profiles:
            path = "api/profiles"
        case .jobs:
            path = "api/jobs"
        case .sessionDetail:
            guard let sessionID = payload.sessionId?.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
                throw IrohRelayHostError.invalidPath
            }
            path = "api/sessions/\(sessionID)"
        }
        let base = hermesBaseURLWithTrailingSlash()
        guard let url = URL(string: path, relativeTo: base)?.absoluteURL else {
            throw IrohRelayHostError.invalidPath
        }
        var request = URLRequest(url: url, timeoutInterval: operation == .chatCompletions ? 120 : 20)
        request.httpMethod = operation == .chatCompletions ? "POST" : "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let token = settingsManager.hermesBearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if operation == .chatCompletions {
            guard let body = payload.body?.data(using: .utf8) else {
                throw IrohRelayHostError.invalidPath
            }
            request.httpBody = body
        }
        return request
    }

    @MainActor
    private func hermesBaseURLWithTrailingSlash() -> URL {
        let base = URL(string: settingsManager.hermesGatewayBaseURL.trimmingCharacters(in: .whitespacesAndNewlines))
            ?? URL(string: "http://127.0.0.1:8642")!
        if base.absoluteString.hasSuffix("/") { return base }
        return URL(string: "\(base.absoluteString)/") ?? base
    }

    private func sendChunk(
        data: String,
        sequence: Int,
        kind: HermesRelayChunkKind,
        uid: String,
        connectionID: String,
        requestID: String,
        keyData: Data,
        stream: any IrohRelayStream
    ) async throws {
        let ciphertext = try HermesRelayCrypto.sealToBase64(
            plaintext: Data(data.utf8),
            keyData: keyData,
            aad: HermesRelayCrypto.chunkAAD(
                uid: uid,
                connectionID: connectionID,
                requestID: requestID,
                sequence: sequence,
                kind: kind.rawValue
            )
        )
        try await stream.send(
            HermesRealtimeRelayFrame(
                type: .responseChunk,
                uid: uid,
                connectionId: connectionID,
                requestId: requestID,
                payload: HermesRealtimeRelayPayload(
                    sequence: sequence,
                    kind: kind,
                    ciphertext: ciphertext
                )
            )
        )
    }

    private func sendComplete(
        uid: String,
        connectionID: String,
        requestID: String,
        chunkCount: Int,
        stream: any IrohRelayStream
    ) async throws {
        try await stream.send(
            HermesRealtimeRelayFrame(
                type: .responseComplete,
                uid: uid,
                connectionId: connectionID,
                requestId: requestID,
                payload: HermesRealtimeRelayPayload(chunkCount: chunkCount)
            )
        )
    }

    private func sendError(
        message: String,
        frame: HermesRealtimeRelayFrame,
        stream: any IrohRelayStream
    ) async throws {
        let response = HermesRealtimeRelayFrame(
            type: .responseError,
            uid: frame.uid,
            connectionId: frame.connectionId,
            requestId: frame.requestId,
            payload: HermesRealtimeRelayPayload(error: String(message.prefix(2_000)))
        )
        try await stream.send(response)
    }
}

enum IrohRelayHostError: LocalizedError {
    case invalidPath
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidPath:
            return "Iroh relay request path is invalid."
        case .invalidResponse:
            return "Hermes gateway returned an invalid response over the iroh transport."
        }
    }
}
