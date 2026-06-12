import Foundation
import FirebaseAppCheck
import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import OpenBurnBarCore
import OpenBurnBarComputerUseCore

@MainActor
final class HermesRealtimeRelayTransport: HermesRelayTransporting {
    static let shared = HermesRealtimeRelayTransport()

    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(session: URLSession = .shared) {
        self.session = session
    }

    func sendUnary(_ payload: HermesRelayPayload, timeout: TimeInterval) async throws -> Data {
        var fragments: [Int: String] = [:]
        try await send(payload, timeout: timeout) { chunk in
            switch chunk.kind {
            case .data:
                fragments[chunk.sequence] = chunk.data ?? chunk.text ?? ""
            case .error:
                throw HermesServiceError.relayFailure(chunk.error, fallback: "Hermes realtime relay failed.")
            case .sse:
                break
            }
        }
        let body = fragments
            .sorted { $0.key < $1.key }
            .map(\.value)
            .joined()
        return Data(body.utf8)
    }

    func sendStreaming(
        _ payload: HermesRelayPayload,
        timeout: TimeInterval,
        onSSEEvent: @escaping @MainActor (String) -> Void
    ) async throws {
        try await send(payload, timeout: timeout) { chunk in
            switch chunk.kind {
            case .sse:
                if let data = chunk.data ?? chunk.text, !data.isEmpty {
                    onSSEEvent(data)
                }
            case .error:
                throw HermesServiceError.relayFailure(chunk.error, fallback: "Hermes realtime relay stream failed.")
            case .data:
                break
            }
        }
    }

    private func send(
        _ payload: HermesRelayPayload,
        timeout: TimeInterval,
        onChunk: (HermesRelayChunkRecord) throws -> Void
    ) async throws {
        guard FirebaseApp.app() != nil else {
            throw FirestoreError.firebaseUnavailable
        }
        guard let uid = Auth.auth().currentUser?.uid else {
            throw FirestoreError.notAuthenticated
        }
        guard let relayURL = realtimeRelayURL(for: payload) else {
            throw HermesServiceError.relayUnavailable("Realtime relay URL is not configured.")
        }
        guard payload.connectionID != HermesConnectionRecord.localDefault.id else {
            throw HermesServiceError.relayUnavailable("Select a Remote Relay Hermes connection first.")
        }
        guard payload.relayEncryption == HermesRelayCrypto.relayEncryptionV3,
              payload.relayKeyVersion == HermesRelayCrypto.gatewayRelayKeyVersionV3,
              let relayPublicKey = payload.relayPublicKey,
              !relayPublicKey.isEmpty else {
            throw HermesServiceError.relayUnavailable("Update OpenBurnBar on your Mac and re-enable Remote Relay so this iPhone/iPad can use authenticated relay traffic.")
        }

        let requestID = "rt_\(UUID().uuidString.lowercased())"
        _ = relayPublicKey
        let sealed = try await MobileHermesAuthenticatedRelayRequestSealer.seal(
            payload: payload,
            uid: uid,
            requestID: requestID
        )
        let keyData = sealed.keyData

        var request = URLRequest(url: relayURL, timeoutInterval: timeout)
        request.setValue("Bearer \(try await firebaseIDToken())", forHTTPHeaderField: "Authorization")
        request.setValue(try await appCheckToken(), forHTTPHeaderField: "X-Firebase-AppCheck")
        request.setValue(
            HermesRealtimeRelayProtocol.clientRoleHeaderValue,
            forHTTPHeaderField: HermesRealtimeRelayProtocol.roleHeaderName
        )
        let task = session.webSocketTask(with: request)
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }

        let startFrame = HermesRealtimeRelayFrame(
            type: .requestStart,
            uid: uid,
            connectionId: payload.connectionID,
            requestId: requestID,
            payload: sealed.payload
        )
        try await task.send(.data(encoder.encode(startFrame)))

        let deadline = Date().addingTimeInterval(timeout)
        // F4: detect a relay that drops/withholds a sealed chunk (silent truncation).
        var chunkValidator = ChunkReassemblyValidator()
        while Date() < deadline {
            let frame = try await receiveFrame(
                from: task,
                timeout: max(0, deadline.timeIntervalSinceNow)
            )
            guard frame.uid == uid,
                  frame.connectionId == payload.connectionID,
                  frame.requestId == requestID else {
                continue
            }
            switch frame.type {
            case .responseChunk:
                guard let chunk = try chunkRecord(from: frame, uid: uid, keyData: keyData) else { continue }
                try onChunk(chunk)
                try chunkValidator.record(sequence: chunk.sequence)
            case .responseComplete:
                // F4: refuse a truncated response (a relay dropped a sealed chunk).
                try chunkValidator.validateComplete(declaredChunkCount: frame.payload?.chunkCount ?? 0)
                return
            case .responseError:
                throw HermesServiceError.relayFailure(
                    HermesRealtimeRelayErrorCode.publicMessage(for: frame.payload?.errorCode),
                    fallback: "Hermes realtime relay failed."
                )
            case .ping:
                try await task.send(.data(encoder.encode(HermesRealtimeRelayFrame(
                    type: .pong,
                    uid: uid,
                    connectionId: payload.connectionID,
                    requestId: requestID
                ))))
            case .hostRegister, .hostReady, .requestStart, .requestCancel, .pong, .signalSessionMessage:  // cov:ignore
                break
            case .signalSessionMessage,
                 .mediaClassify,
                 .mediaBlobAdvertise,
                 .mediaBlobAck,
                 .mediaMirrorRequest,
                 .mediaMirrorAck,
                 .mediaMirrorStop,
                 .mediaMirrorDisplaySelect,
                 .mediaPresenceHeartbeat,
                 .mediaLongTermReferenceAck,
                 .mediaCallInvite,
                 .mediaCallAck,
                 .mediaStreamFrame:
                // Mercury media frames are iroh-transport-only and never
                // appear on the WSS dialer's chat response stream.
                break
            case .controlClassify, .controlActionLogEntry, .controlInputIntent,
                 .controlApprovalRequest, .controlApprovalResponse,
                 .controlAgentGrantRequest, .controlAgentGrantReceipt,
                 .controlClipboardRequest, .controlClipboardResponse,
                 .controlAgentContextTarget,
                 .controlDenied,
                 .controlSystemPermissionRequest,
                 .controlSystemPermissionStatus,
                 .remoteUnlockSession,
                 .remoteUnlockState,
                 .remoteUnlockInput,
                 .remoteUnlockCredential,
                 .remoteUnlockResult,
                 .remoteUnlockDenied:
                // Computer Use control frames are handled by the control
                // plane; chat relay responses ignore them.
                break
            }
        }

        try? await task.send(.data(encoder.encode(HermesRealtimeRelayFrame(
            type: .requestCancel,
            uid: uid,
            connectionId: payload.connectionID,
            requestId: requestID
        ))))
        throw HermesServiceError.relayTimeout
    }

    private func chunkRecord(from frame: HermesRealtimeRelayFrame, uid: String, keyData: Data) throws -> HermesRelayChunkRecord? {
        guard let payload = frame.payload,
              let sequence = payload.sequence,
              let kind = payload.kind,
              let requestID = frame.requestId else {
            return nil
        }
        guard let ciphertext = payload.ciphertext else {
            throw HermesServiceError.relayUnavailable("Realtime relay returned a chunk without ciphertext.")
        }
        let plaintext = try HermesRelayCrypto.openBase64(
            ciphertext: ciphertext,
            keyData: keyData,
            aad: HermesRelayCrypto.chunkAAD(
                uid: uid,
                connectionID: frame.connectionId,
                requestID: requestID,
                sequence: sequence,
                kind: kind.rawValue
            )
        )
        let text = String(data: plaintext, encoding: .utf8) ?? ""
        return HermesRelayChunkRecord(
            id: String(format: "%08d", sequence),
            requestId: requestID,
            sequence: sequence,
            kind: kind,
            data: kind == .error ? nil : text,
            text: text,
            error: kind == .error ? text : nil,
            schemaVersion: 2
        )
    }

    private func receiveFrame(from task: URLSessionWebSocketTask) async throws -> HermesRealtimeRelayFrame {
        try Self.decodeFrame(try await task.receive())
    }

    private func receiveFrame(
        from task: URLSessionWebSocketTask,
        timeout: TimeInterval
    ) async throws -> HermesRealtimeRelayFrame {
        guard timeout > 0 else {
            throw HermesServiceError.relayTimeout
        }
        return try await withThrowingTaskGroup(of: HermesRealtimeRelayFrame.self) { group in
            group.addTask {
                try Self.decodeFrame(try await task.receive())
            }
            group.addTask {
                try await Task.sleep(nanoseconds: Self.timeoutNanoseconds(timeout))
                throw HermesServiceError.relayTimeout
            }
            guard let frame = try await group.next() else {
                throw HermesServiceError.relayTimeout
            }
            group.cancelAll()
            return frame
        }
    }

    private nonisolated static func decodeFrame(
        _ message: URLSessionWebSocketTask.Message
    ) throws -> HermesRealtimeRelayFrame {
        switch message {
        case .data(let data):
            return try JSONDecoder().decode(HermesRealtimeRelayFrame.self, from: data)
        case .string(let string):
            return try JSONDecoder().decode(HermesRealtimeRelayFrame.self, from: Data(string.utf8))
        @unknown default:
            throw HermesServiceError.invalidResponse
        }
    }

    private nonisolated static func timeoutNanoseconds(_ timeout: TimeInterval) -> UInt64 {
        let capped = min(max(timeout, 0.001), 3_600)
        return UInt64(capped * 1_000_000_000)
    }

    private func realtimeRelayURL(for payload: HermesRelayPayload) -> URL? {
        let raw = payload.realtimeRelayURL?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? Bundle.main.object(forInfoDictionaryKey: "HermesRealtimeRelayURL") as? String
            ?? ""
        guard !raw.isEmpty else { return nil }
        if let url = URL(string: raw), url.scheme == "wss" || url.scheme == "ws" {
            return url
        }
        return nil
    }

    private func firebaseIDToken() async throws -> String {
        guard FirebaseApp.app() != nil else {
            throw FirestoreError.firebaseUnavailable
        }
        guard let user = Auth.auth().currentUser else {
            throw FirestoreError.notAuthenticated
        }
        return try await withCheckedThrowingContinuation { continuation in
            user.getIDToken { token, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let token, !token.isEmpty {
                    continuation.resume(returning: token)
                } else {
                    continuation.resume(throwing: FirestoreError.notAuthenticated)
                }
            }
        }
    }

    private func appCheckToken() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            AppCheck.appCheck().token(forcingRefresh: false) { token, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let token, !token.token.isEmpty {
                    continuation.resume(returning: token.token)
                } else {
                    continuation.resume(throwing: HermesServiceError.relayUnavailable("App Check token is unavailable."))
                }
            }
        }
    }
}
