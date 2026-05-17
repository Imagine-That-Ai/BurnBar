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
    private static let chatForwardTimeout: TimeInterval = 300
    private static let unaryForwardTimeout: TimeInterval = 20

    private let relayKeyStore: HermesRelayKeyStore
    private let urlSession: URLSession
    private let settingsManager: any SettingsManagerProtocol
    private let mediaDispatcher: MediaFrameDispatcher?
    private let mediaControlRegistrar: MediaControlStreamRegistrar?
    private let auditLogger: (any IrohTransportAuditLogging)?

    @MainActor
    init(
        relayKeyStore: HermesRelayKeyStore,
        urlSession: URLSession,
        settingsManager: any SettingsManagerProtocol,
        mediaDispatcher: MediaFrameDispatcher? = nil,
        mediaControlRegistrar: MediaControlStreamRegistrar? = nil,
        auditLogger: (any IrohTransportAuditLogging)? = nil
    ) {
        self.relayKeyStore = relayKeyStore
        self.urlSession = urlSession
        self.settingsManager = settingsManager
        self.mediaDispatcher = mediaDispatcher
        self.mediaControlRegistrar = mediaControlRegistrar
        self.auditLogger = auditLogger
    }

    func serve(
        stream: any IrohRelayStream,
        uid: String,
        connectionID: String
    ) async throws {
        var classifiedAsMediaControl = false
        while let frame = try await stream.receive() {
            guard frame.uid == uid, frame.connectionId == connectionID else { continue }
            await auditStage(
                "host_frame_received",
                uid: uid,
                connectionID: connectionID,
                requestID: frame.requestId,
                extra: ["frameType": frame.type.rawValue]
            )

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
                    await auditStage(
                        "host_request_malformed",
                        uid: uid,
                        connectionID: connectionID,
                        extra: ["reason": "missing_request_id"]
                    )
                    try await sendError(
                        message: "Malformed realtime relay request.",
                        frame: frame,
                        stream: stream
                    )
                    continue
                }
                await auditStage(
                    "host_request_start",
                    uid: uid,
                    connectionID: connectionID,
                    requestID: requestID
                )
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
                    await auditStage(
                        "host_request_error",
                        uid: uid,
                        connectionID: connectionID,
                        requestID: requestID,
                        extra: ["error": String(error.localizedDescription.prefix(256))]
                    )
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
            await auditStage(
                "host_request_malformed",
                uid: uid,
                connectionID: connectionID,
                requestID: requestID,
                extra: ["reason": "invalid_payload"]
            )
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
        await auditStage(
            "host_request_decrypted",
            uid: uid,
            connectionID: connectionID,
            requestID: requestID,
            extra: [
                "operation": operation.rawValue,
                "path": encryptedPayload.path ?? ""
            ]
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
        await auditStage(
            "host_forward_unary_complete",
            uid: uid,
            connectionID: connectionID,
            requestID: requestID,
            extra: [
                "operation": operation.rawValue,
                "chunks": String(sequence)
            ]
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
        let requestedModel = Self.requestedModel(fromBody: payload.body)
        let requestMetadata = Self.chatRequestMetadata(fromBody: payload.body)
        var request = try await makeForwardRequest(operation: .chatCompletions, payload: payload)
        request.httpMethod = "POST"
        await auditStage(
            "host_forward_chat_start",
            uid: uid,
            connectionID: connectionID,
            requestID: requestID,
            extra: [
                "url": request.url?.absoluteString ?? "",
                "requestedModel": requestedModel ?? "",
                "bodyBytes": requestMetadata.bodyBytes,
                "messageCount": requestMetadata.messageCount,
                "toolCount": requestMetadata.toolCount,
                "stream": requestMetadata.stream
            ]
        )
        let startedAt = Date()
        let (bytes, response) = try await urlSession.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw IrohRelayHostError.invalidResponse
        }
        let statusCode = httpResponse.statusCode
        guard (200..<300).contains(statusCode) else {
            let body = try await Self.readErrorBody(from: bytes)
            throw IrohRelayHostError.httpStatus(
                code: statusCode,
                body: body,
                requestedModel: requestedModel
            )
        }
        if let headerError = Self.hermesErrorHeader(from: httpResponse) {
            throw IrohRelayHostError.upstreamError(
                Self.formattedUpstreamError(
                    message: headerError,
                    statusCode: nil,
                    requestedModel: requestedModel
                )
            )
        }
        await auditStage(
            "host_forward_chat_response",
            uid: uid,
            connectionID: connectionID,
            requestID: requestID,
            extra: ["status": String(statusCode)]
        )

        var eventLines: [String] = []
        var pendingLineBytes: [UInt8] = []
        var sequence = 0
        var receivedDone = false
        var sawFirstUpstreamByte = false

        func sendSSEEvent(_ event: String) async throws -> Bool {
            if Self.isSSEDoneEvent(event) {
                return true
            }
            if let upstreamError = Self.upstreamErrorMessage(
                fromSSEEvent: event,
                requestedModel: requestedModel
            ) {
                await auditStage(
                    "host_forward_chat_upstream_error",
                    uid: uid,
                    connectionID: connectionID,
                    requestID: requestID,
                    extra: [
                        "requestedModel": requestedModel ?? "",
                        "error": String(upstreamError.prefix(256))
                    ]
                )
                throw IrohRelayHostError.upstreamError(upstreamError)
            }
            let isTerminalEvent = Self.isSSETerminalChoiceEvent(event)
            if sequence == 0 || isTerminalEvent {
                await auditStage(
                    sequence == 0 ? "host_forward_chat_chunk_send_start" : "host_forward_chat_terminal_chunk_send_start",
                    uid: uid,
                    connectionID: connectionID,
                    requestID: requestID,
                    extra: [
                        "sequence": String(sequence),
                        "terminal": isTerminalEvent ? "true" : "false",
                        "elapsedMs": String(Int(Date().timeIntervalSince(startedAt) * 1000))
                    ]
                )
            }
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
            if sequence == 0 || isTerminalEvent {
                await auditStage(
                    sequence == 0 ? "host_forward_chat_chunk_sent" : "host_forward_chat_terminal_chunk_sent",
                    uid: uid,
                    connectionID: connectionID,
                    requestID: requestID,
                    extra: [
                        "sequence": String(sequence),
                        "terminal": isTerminalEvent ? "true" : "false",
                        "elapsedMs": String(Int(Date().timeIntervalSince(startedAt) * 1000))
                    ]
                )
            }
            sequence += 1
            return isTerminalEvent
        }

        func processSSELine(_ line: String) async throws -> Bool {
            if Self.isSSEDoneLine(line) {
                for event in Self.flushSSEEventLines(&eventLines) {
                    if try await sendSSEEvent(event) {
                        return true
                    }
                }
                return true
            }
            let emittedEvents = HermesRelayHostService.consumeSSELine(line, eventLines: &eventLines)
            for event in emittedEvents {
                if Self.isSSEDoneEvent(event) {
                    return true
                }
                if try await sendSSEEvent(event) {
                    return true
                }
            }
            if emittedEvents.isEmpty, Self.shouldFlushBufferedTerminalSSEEvent(eventLines) {
                let bufferedEvent = eventLines.joined(separator: "\n")
                _ = try await sendSSEEvent(bufferedEvent)
                eventLines.removeAll(keepingCapacity: true)
                return true
            }
            return false
        }

        for try await byte in bytes {
            try Task.checkCancellation()
            if !sawFirstUpstreamByte {
                sawFirstUpstreamByte = true
                await auditStage(
                    "host_forward_chat_first_upstream_byte",
                    uid: uid,
                    connectionID: connectionID,
                    requestID: requestID,
                    extra: [
                        "elapsedMs": String(Int(Date().timeIntervalSince(startedAt) * 1000))
                    ]
                )
            }
            if byte == 0x0A {
                let line = Self.sseLine(from: pendingLineBytes)
                pendingLineBytes.removeAll(keepingCapacity: true)
                if try await processSSELine(line) {
                    receivedDone = true
                    break
                }
                continue
            }

            pendingLineBytes.append(byte)
            if let bufferedEvent = Self.bufferedTerminalSSEEvent(
                eventLines: eventLines,
                pendingLineBytes: pendingLineBytes
            ) {
                _ = try await sendSSEEvent(bufferedEvent)
                eventLines.removeAll(keepingCapacity: true)
                pendingLineBytes.removeAll(keepingCapacity: true)
                receivedDone = true
                break
            }
        }
        if !receivedDone, !pendingLineBytes.isEmpty {
            let line = Self.sseLine(from: pendingLineBytes)
            pendingLineBytes.removeAll(keepingCapacity: true)
            receivedDone = try await processSSELine(line)
        }
        if !eventLines.isEmpty {
            let event = eventLines.joined(separator: "\n")
            if try await sendSSEEvent(event) {
                receivedDone = true
            }
        }
        await auditStage(
            "host_forward_chat_complete_send_start",
            uid: uid,
            connectionID: connectionID,
            requestID: requestID,
            extra: [
                "chunks": String(sequence),
                "done": receivedDone ? "true" : "false",
                "elapsedMs": String(Int(Date().timeIntervalSince(startedAt) * 1000))
            ]
        )
        try await sendComplete(
            uid: uid,
            connectionID: connectionID,
            requestID: requestID,
            chunkCount: sequence,
            stream: stream
        )
        await auditStage(
            "host_forward_chat_complete",
            uid: uid,
            connectionID: connectionID,
            requestID: requestID,
            extra: [
                "chunks": String(sequence),
                "done": receivedDone ? "true" : "false",
                "elapsedMs": String(Int(Date().timeIntervalSince(startedAt) * 1000))
            ]
        )
    }

    private func forwardUnary(
        operation: HermesRelayOperation,
        payload: HermesRelayEncryptedRequestPayload
    ) async throws -> String {
        let request = try await makeForwardRequest(operation: operation, payload: payload)
        let (body, response) = try await urlSession.data(for: request)
        guard let statusCode = (response as? HTTPURLResponse)?.statusCode else {
            throw IrohRelayHostError.invalidResponse
        }
        guard (200..<300).contains(statusCode) else {
            throw IrohRelayHostError.httpStatus(
                code: statusCode,
                body: String(data: body, encoding: .utf8),
                requestedModel: Self.requestedModel(fromBody: payload.body)
            )
        }
        let responseBody: Data
        if operation == .models {
            responseBody = await enrichedModelsBody(primaryBody: body)
        } else {
            responseBody = body
        }
        return String(data: responseBody, encoding: .utf8) ?? ""
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
        var request = URLRequest(
            url: url,
            timeoutInterval: operation == .chatCompletions
                ? Self.chatForwardTimeout
                : Self.unaryForwardTimeout
        )
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

    @MainActor
    private func enrichedModelsBody(primaryBody: Data) async -> Data {
        let settings = settingsManager as? SettingsManager
        let port = settings?.gatewayPort ?? 8317
        guard port > 0,
              let url = URL(string: "http://127.0.0.1:\(port)/v1/models") else {
            return primaryBody
        }
        var request = URLRequest(url: url, timeoutInterval: 5)
        let token = settings?.gatewayAuthToken.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (secondaryBody, response) = try await urlSession.data(for: request)
            guard let statusCode = (response as? HTTPURLResponse)?.statusCode,
                  (200..<300).contains(statusCode) else {
                return primaryBody
            }
            return HermesRelayHostService.mergedModelsResponseBodies(primaryBody, secondaryBody) ?? primaryBody
        } catch {
            return primaryBody
        }
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

    private func auditStage(
        _ stage: String,
        uid: String,
        connectionID: String,
        requestID: String? = nil,
        extra: [String: String] = [:]
    ) async {
        guard let auditLogger else { return }
        var detail = extra
        detail["stage"] = stage
        if let requestID {
            detail["requestId"] = requestID
        }
        await auditLogger.record(
            event: .streamOpened,
            uid: uid,
            connectionId: connectionID,
            transport: .irohDirect,
            rttMillis: nil,
            detail: detail
        )
    }

    nonisolated static func flushSSEEventLines(_ eventLines: inout [String]) -> [String] {
        guard !eventLines.isEmpty else { return [] }
        let event = eventLines.joined(separator: "\n")
        eventLines.removeAll(keepingCapacity: true)
        return [event]
    }

    nonisolated static func isSSEDoneLine(_ rawLine: String) -> Bool {
        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:") else { return false }
        let payload = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        return payload == "[DONE]"
    }

    nonisolated static func isSSEDoneEvent(_ event: String) -> Bool {
        for rawLine in event.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("data:") else { continue }
            let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" {
                return true
            }
        }
        return false
    }

    nonisolated static func isSSETerminalChoiceEvent(_ event: String) -> Bool {
        for dataPayload in sseDataPayloads(from: event) {
            guard let data = dataPayload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = object["choices"] as? [[String: Any]] else {
                continue
            }
            if choices.contains(where: { choice in
                guard let finishReason = choice["finish_reason"] else { return false }
                if finishReason is NSNull { return false }
                if let text = finishReason as? String {
                    return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                return true
            }) {
                return true
            }
        }
        return false
    }

    nonisolated static func shouldFlushBufferedTerminalSSEEvent(_ eventLines: [String]) -> Bool {
        guard !eventLines.isEmpty else { return false }
        return isSSETerminalChoiceEvent(eventLines.joined(separator: "\n"))
    }

    nonisolated static func bufferedTerminalSSEEvent(
        eventLines: [String],
        pendingLineBytes: [UInt8]
    ) -> String? {
        guard !pendingLineBytes.isEmpty else { return nil }
        let candidateLines = eventLines + [sseLine(from: pendingLineBytes)]
        guard shouldFlushBufferedTerminalSSEEvent(candidateLines) else { return nil }
        return candidateLines.joined(separator: "\n")
    }

    nonisolated static func sseLine(from bytes: [UInt8]) -> String {
        var line = String(decoding: bytes, as: UTF8.self)
        if line.hasSuffix("\r") {
            line.removeLast()
        }
        return line
    }

    nonisolated static func requestedModel(fromBody body: String?) -> String? {
        guard let body,
              let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = object["model"] as? String else {
            return nil
        }
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated static func chatRequestMetadata(fromBody body: String?) -> (
        bodyBytes: String,
        messageCount: String,
        toolCount: String,
        stream: String
    ) {
        guard let body else {
            return ("0", "0", "0", "")
        }
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (String(body.utf8.count), "0", "0", "")
        }
        let messages = object["messages"] as? [Any]
        let tools = object["tools"] as? [Any]
        let stream: String
        if let bool = object["stream"] as? Bool {
            stream = bool ? "true" : "false"
        } else {
            stream = ""
        }
        return (
            String(body.utf8.count),
            String(messages?.count ?? 0),
            String(tools?.count ?? 0),
            stream
        )
    }

    nonisolated static func upstreamErrorMessage(
        fromSSEEvent event: String,
        requestedModel: String?
    ) -> String? {
        for dataPayload in sseDataPayloads(from: event) {
            guard let data = dataPayload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            if let message = errorMessage(fromJSONObject: object) {
                return formattedUpstreamError(
                    message: message,
                    statusCode: nil,
                    requestedModel: requestedModel
                )
            }
            if let message = hermesFailureMessage(fromJSONObject: object)
                ?? terminalChoiceErrorMessage(fromJSONObject: object) {
                return formattedUpstreamError(
                    message: message,
                    statusCode: nil,
                    requestedModel: requestedModel
                )
            }
        }
        return nil
    }

    nonisolated static func hermesErrorHeader(from response: HTTPURLResponse) -> String? {
        stringValue(response.value(forHTTPHeaderField: "X-Hermes-Error"))
    }

    nonisolated private static func sseDataPayloads(from event: String) -> [String] {
        var values: [String] = []
        for rawLine in event.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("data:") else { continue }
            let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if !payload.isEmpty, payload != "[DONE]" {
                values.append(payload)
            }
        }
        return values
    }

    nonisolated private static func errorMessage(fromJSONObject object: [String: Any]) -> String? {
        if let error = object["error"] as? [String: Any] {
            return stringValue(error["message"])
                ?? stringValue(error["error"])
                ?? stringValue(error["description"])
        }
        return stringValue(object["error"])
            ?? stringValue(object["message"])
    }

    nonisolated private static func hermesFailureMessage(fromJSONObject object: [String: Any]) -> String? {
        guard let hermes = object["hermes"] as? [String: Any],
              boolValue(hermes["failed"]) == true
                || boolValue(hermes["completed"]) == false && stringValue(hermes["error"]) != nil else {
            return nil
        }
        return stringValue(hermes["error"])
            ?? stringValue(hermes["message"])
            ?? "Hermes reported that the upstream model request failed."
    }

    nonisolated private static func terminalChoiceErrorMessage(fromJSONObject object: [String: Any]) -> String? {
        guard let choices = object["choices"] as? [[String: Any]] else {
            return nil
        }
        for choice in choices {
            guard stringValue(choice["finish_reason"])?.lowercased() == "error"
                    || stringValue(choice["finishReason"])?.lowercased() == "error" else {
                continue
            }
            if let message = choiceVisibleContent(choice)
                ?? stringValue(object["error"])
                ?? stringValue(object["message"]) {
                return message
            }
            return "Hermes reported that the upstream model request failed."
        }
        return nil
    }

    nonisolated private static func choiceVisibleContent(_ choice: [String: Any]) -> String? {
        if let message = choice["message"] as? [String: Any],
           let content = visibleContentValue(message["content"]) {
            return content
        }
        if let delta = choice["delta"] as? [String: Any],
           let content = visibleContentValue(delta["content"]) {
            return content
        }
        return visibleContentValue(choice["text"])
    }

    nonisolated private static func visibleContentValue(_ raw: Any?) -> String? {
        if let value = raw as? String {
            return stringValue(value)
        }
        if let object = raw as? [String: Any] {
            return visibleContentValue(object["text"])
                ?? visibleContentValue(object["value"])
                ?? visibleContentValue(object["content"])
        }
        if let array = raw as? [Any] {
            let joined = array.compactMap { part -> String? in
                if let text = part as? String { return text }
                guard let object = part as? [String: Any] else { return nil }
                return visibleContentValue(object["text"])
                    ?? visibleContentValue(object["value"])
                    ?? visibleContentValue(object["content"])
            }
            .joined()
            return stringValue(joined)
        }
        return nil
    }

    nonisolated private static func stringValue(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated private static func boolValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool {
            return value
        }
        if let value = value as? NSNumber {
            return value.boolValue
        }
        if let value = value as? String {
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1", "yes":
                return true
            case "false", "0", "no":
                return false
            default:
                return nil
            }
        }
        return nil
    }

    nonisolated private static func stringValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated static func formattedUpstreamError(
        message: String,
        statusCode: Int?,
        requestedModel: String?
    ) -> String {
        var prefix = "Hermes upstream model"
        if let requestedModel, !requestedModel.isEmpty {
            prefix += " '\(requestedModel)'"
        }
        if let statusCode {
            prefix += " returned HTTP \(statusCode)"
        } else {
            prefix += " failed"
        }
        return "\(prefix): \(message)"
    }

    nonisolated static func httpStatusErrorMessage(
        code: Int,
        body: String?,
        requestedModel: String?
    ) -> String {
        let message: String
        if let body,
           let data = body.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let parsed = errorMessage(fromJSONObject: object) {
            message = parsed
        } else if let body,
                  !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            message = body.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            message = "No response body."
        }
        return formattedUpstreamError(
            message: String(message.prefix(1_200)),
            statusCode: code,
            requestedModel: requestedModel
        )
    }

    private static func readErrorBody(
        from bytes: URLSession.AsyncBytes,
        maxCharacters: Int = 1_200
    ) async throws -> String {
        var lines: [String] = []
        var count = 0
        for try await line in bytes.lines {
            lines.append(line)
            count += line.count
            if count >= maxCharacters { break }
        }
        return lines.joined(separator: "\n")
    }
}

enum IrohRelayHostError: LocalizedError {
    case invalidPath
    case invalidResponse
    case httpStatus(code: Int, body: String?, requestedModel: String?)
    case upstreamError(String)

    var errorDescription: String? {
        switch self {
        case .invalidPath:
            return "Iroh relay request path is invalid."
        case .invalidResponse:
            return "Hermes gateway returned an invalid response over the iroh transport."
        case .httpStatus(let code, let body, let requestedModel):
            return IrohRelayRequestHandler.httpStatusErrorMessage(
                code: code,
                body: body,
                requestedModel: requestedModel
            )
        case .upstreamError(let message):
            return message
        }
    }
}
