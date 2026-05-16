import FirebaseAppCheck
@preconcurrency import FirebaseAuth
import Foundation
import OpenBurnBarCore

@MainActor
protocol HermesRealtimeRelayHosting: AnyObject {
    var publishableRelayURLString: String? { get }

    @discardableResult
    func start(uid: String, connectionID: String) async -> Bool
    func stop()
}

@MainActor
final class HermesRealtimeRelayHostClient: HermesRealtimeRelayHosting {
    private let accountManager: AccountManager
    private let settingsManager: SettingsManager
    private let relayKeyStore: HermesRelayKeyStore
    private let urlSession: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var activeRequestTasks: [String: Task<Void, Never>] = [:]
    private var readyUID: String?
    private var readyConnectionID: String?

    init(
        accountManager: AccountManager = .shared,
        settingsManager: SettingsManager = .shared,
        relayKeyStore: HermesRelayKeyStore = HermesRelayKeyStore(),
        urlSession: URLSession = .shared
    ) {
        self.accountManager = accountManager
        self.settingsManager = settingsManager
        self.relayKeyStore = relayKeyStore
        self.urlSession = urlSession
    }

    var isConfigured: Bool {
        realtimeRelayURL() != nil
    }

    var isReady: Bool {
        task != nil && readyConnectionID != nil
    }

    var publishableRelayURLString: String? {
        guard isReady,
              let url = realtimeRelayURL(),
              url.scheme == "wss" else {
            return nil
        }
        return url.absoluteString
    }

    @discardableResult
    func start(uid: String, connectionID: String) async -> Bool {
        if task != nil, readyUID == uid, readyConnectionID == connectionID {
            return true
        }
        stop()
        guard settingsManager.hermesRemoteRelayEnabled,
              let url = realtimeRelayURL() else {
            return false
        }
        do {
            var request = URLRequest(url: url, timeoutInterval: 60)
            request.setValue("Bearer \(try await firebaseIDToken())", forHTTPHeaderField: "Authorization")
            request.setValue(try await appCheckToken(), forHTTPHeaderField: "X-Firebase-AppCheck")
            request.setValue(
                HermesRealtimeRelayProtocol.hostRoleHeaderValue,
                forHTTPHeaderField: HermesRealtimeRelayProtocol.roleHeaderName
            )
            let socket = urlSession.webSocketTask(with: request)
            task = socket
            socket.resume()
            let frame = HermesRealtimeRelayFrame(
                type: .hostRegister,
                uid: uid,
                connectionId: connectionID,
                payload: HermesRealtimeRelayPayload(capabilities: ["chat_completions", "remote_relay", HermesRealtimeRelayProtocol.capability])
            )
            try await socket.send(.data(encoder.encode(frame)))
            try await waitForHostReady(uid: uid, connectionID: connectionID, socket: socket)
            readyUID = uid
            readyConnectionID = connectionID
            receiveTask = Task { @MainActor [weak self] in
                await self?.receiveLoop(uid: uid, connectionID: connectionID, socket: socket)
            }
            return true
        } catch {
            AppLogger.network.silentFailure("hermes_realtime_relay_connect_failed", error: error)
            stop()
            return false
        }
    }

    func stop() {
        receiveTask?.cancel()
        receiveTask = nil
        for task in activeRequestTasks.values {
            task.cancel()
        }
        activeRequestTasks.removeAll()
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        readyUID = nil
        readyConnectionID = nil
    }

    private func receiveLoop(uid: String, connectionID: String, socket: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let frame = try await receiveFrame(from: socket)
                guard frame.uid == uid, frame.connectionId == connectionID else { continue }
                switch frame.type {
                case .requestStart:
                    guard let requestID = frame.requestId else {
                        await sendError("Malformed realtime relay request.", frame: frame, socket: socket)
                        continue
                    }
                    activeRequestTasks[requestID]?.cancel()
                    activeRequestTasks[requestID] = Task { @MainActor [weak self] in
                        await self?.handleRequest(frame, uid: uid, connectionID: connectionID, socket: socket)
                        self?.activeRequestTasks[requestID] = nil
                    }
                case .requestCancel:
                    if let requestID = frame.requestId {
                        activeRequestTasks[requestID]?.cancel()
                        activeRequestTasks[requestID] = nil
                    }
                case .ping:
                    try await socket.send(.data(encoder.encode(HermesRealtimeRelayFrame(
                        type: .pong,
                        uid: uid,
                        connectionId: connectionID,
                        requestId: frame.requestId
                    ))))
                case .hostReady, .pong, .hostRegister, .responseChunk, .responseComplete, .responseError:
                    break
                case .mediaClassify, .mediaBlobAdvertise, .mediaBlobAck:
                    // Mercury media frames ride the iroh transport, not WSS.
                    // If a peer sends one here it is either a misrouted
                    // frame or an old-format probe; ignore.
                    break
                }
            } catch {
                if Task.isCancelled || (error as NSError).code == NSURLErrorCancelled {
                    return
                }
                AppLogger.network.silentFailure("hermes_realtime_relay_receive_failed", error: error)
                stop()
                return
            }
        }
    }

    private func handleRequest(
        _ frame: HermesRealtimeRelayFrame,
        uid: String,
        connectionID: String,
        socket: URLSessionWebSocketTask
    ) async {
        guard let requestID = frame.requestId,
              let payload = frame.payload,
              let operation = payload.operation,
              let payloadCiphertext = payload.payloadCiphertext,
              let wrappedKey = payload.wrappedKey,
              payload.relayEncryption == HermesRelayCrypto.algorithm else {
            await sendError("Malformed realtime relay request.", frame: frame, socket: socket)
            return
        }
        do {
            let privateKey = try relayKeyStore.privateKey()
            let keyData = try HermesRelayCrypto.unwrapSymmetricKey(
                wrappedKey,
                privateKey: privateKey,
                aad: HermesRelayCrypto.keyAAD(uid: uid, connectionID: connectionID, requestID: requestID)
            )
            let requestPlaintext = try HermesRelayCrypto.openBase64(
                ciphertext: payloadCiphertext,
                keyData: keyData,
                aad: HermesRelayCrypto.requestAAD(uid: uid, connectionID: connectionID, requestID: requestID)
            )
            let encryptedPayload = try JSONDecoder().decode(HermesRelayEncryptedRequestPayload.self, from: requestPlaintext)
            if operation == .chatCompletions {
                try await forwardStreamingChat(
                    payload: encryptedPayload,
                    uid: uid,
                    connectionID: connectionID,
                    requestID: requestID,
                    keyData: keyData,
                    socket: socket
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
                    socket: socket
                )
                sequence += 1
            }
            try await sendComplete(uid: uid, connectionID: connectionID, requestID: requestID, chunkCount: sequence, socket: socket)
        } catch {
            await sendError(error.localizedDescription, frame: frame, socket: socket)
        }
    }

    private func forwardStreamingChat(
        payload: HermesRelayEncryptedRequestPayload,
        uid: String,
        connectionID: String,
        requestID: String,
        keyData: Data,
        socket: URLSessionWebSocketTask
    ) async throws {
        var request = try makeForwardRequest(operation: .chatCompletions, payload: payload)
        request.httpMethod = "POST"
        let (bytes, response) = try await urlSession.bytes(for: request)
        guard let statusCode = (response as? HTTPURLResponse)?.statusCode,
              (200..<300).contains(statusCode) else {
            throw HermesRealtimeRelayHostError.invalidResponse
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
                    socket: socket
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
                socket: socket
            )
            sequence += 1
        }
        try await sendComplete(uid: uid, connectionID: connectionID, requestID: requestID, chunkCount: sequence, socket: socket)
    }

    private func forwardUnary(operation: HermesRelayOperation, payload: HermesRelayEncryptedRequestPayload) async throws -> String {
        let request = try makeForwardRequest(operation: operation, payload: payload)
        let (body, response) = try await urlSession.data(for: request)
        guard let statusCode = (response as? HTTPURLResponse)?.statusCode,
              (200..<300).contains(statusCode) else {
            throw HermesRealtimeRelayHostError.invalidResponse
        }
        // Models enrichment happens server-side in CloudSyncService;
        // the realtime relay host client returns the raw body verbatim.
        return String(data: body, encoding: .utf8) ?? ""
    }

    private func makeForwardRequest(operation: HermesRelayOperation, payload: HermesRelayEncryptedRequestPayload) throws -> URLRequest {
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
                throw HermesRealtimeRelayHostError.invalidPath
            }
            path = "api/sessions/\(sessionID)"
        }
        guard let url = URL(string: path, relativeTo: hermesBaseURLWithTrailingSlash())?.absoluteURL else {
            throw HermesRealtimeRelayHostError.invalidPath
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
                throw HermesRealtimeRelayHostError.invalidPath
            }
            request.httpBody = body
        }
        return request
    }

    private func sendChunk(
        data: String,
        sequence: Int,
        kind: HermesRelayChunkKind,
        uid: String,
        connectionID: String,
        requestID: String,
        keyData: Data,
        socket: URLSessionWebSocketTask
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
        let frame = HermesRealtimeRelayFrame(
            type: .responseChunk,
            uid: uid,
            connectionId: connectionID,
            requestId: requestID,
            payload: HermesRealtimeRelayPayload(sequence: sequence, kind: kind, ciphertext: ciphertext)
        )
        try await socket.send(.data(encoder.encode(frame)))
    }

    private func sendComplete(
        uid: String,
        connectionID: String,
        requestID: String,
        chunkCount: Int,
        socket: URLSessionWebSocketTask
    ) async throws {
        let frame = HermesRealtimeRelayFrame(
            type: .responseComplete,
            uid: uid,
            connectionId: connectionID,
            requestId: requestID,
            payload: HermesRealtimeRelayPayload(chunkCount: chunkCount)
        )
        try await socket.send(.data(encoder.encode(frame)))
    }

    private func sendError(_ message: String, frame: HermesRealtimeRelayFrame, socket: URLSessionWebSocketTask) async {
        let response = HermesRealtimeRelayFrame(
            type: .responseError,
            uid: frame.uid,
            connectionId: frame.connectionId,
            requestId: frame.requestId,
            payload: HermesRealtimeRelayPayload(error: String(message.prefix(2_000)))
        )
        try? await socket.send(.data((try? encoder.encode(response)) ?? Data()))
    }

    private func receiveFrame(from task: URLSessionWebSocketTask) async throws -> HermesRealtimeRelayFrame {
        let message = try await task.receive()
        switch message {
        case .data(let data):
            return try decoder.decode(HermesRealtimeRelayFrame.self, from: data)
        case .string(let string):
            return try decoder.decode(HermesRealtimeRelayFrame.self, from: Data(string.utf8))
        @unknown default:
            throw HermesRealtimeRelayHostError.invalidResponse
        }
    }

    private func waitForHostReady(uid: String, connectionID: String, socket: URLSessionWebSocketTask) async throws {
        let frame = try await withThrowingTaskGroup(of: HermesRealtimeRelayFrame.self) { group in
            group.addTask { [weak self] in
                guard let self else { throw HermesRealtimeRelayHostError.invalidResponse }
                return try await self.receiveFrame(from: socket)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                throw HermesRealtimeRelayHostError.registrationTimedOut
            }
            guard let frame = try await group.next() else {
                throw HermesRealtimeRelayHostError.registrationTimedOut
            }
            group.cancelAll()
            return frame
        }

        guard frame.type == .hostReady,
              frame.uid == uid,
              frame.connectionId == connectionID else {
            throw HermesRealtimeRelayHostError.invalidResponse
        }
    }

    private func realtimeRelayURL() -> URL? {
        let configured = settingsManager.hermesRealtimeRelayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = configured.isEmpty ? HermesRealtimeRelayProtocol.defaultHostedRelayURLString : configured
        guard !raw.isEmpty, let url = URL(string: raw), url.scheme == "wss" || url.scheme == "ws" else {
            return nil
        }
        return url
    }

    private func firebaseIDToken() async throws -> String {
        guard let user = Auth.auth().currentUser else {
            throw HermesRealtimeRelayHostError.unauthenticated
        }
        return try await withCheckedThrowingContinuation { continuation in
            user.getIDToken { token, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let token, !token.isEmpty {
                    continuation.resume(returning: token)
                } else {
                    continuation.resume(throwing: HermesRealtimeRelayHostError.unauthenticated)
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
                    continuation.resume(throwing: HermesRealtimeRelayHostError.unauthenticated)
                }
            }
        }
    }

    private func hermesBaseURL() -> URL {
        URL(string: settingsManager.hermesGatewayBaseURL.trimmingCharacters(in: .whitespacesAndNewlines))
            ?? URL(string: "http://127.0.0.1:8642")!
    }

    private func hermesBaseURLWithTrailingSlash() -> URL {
        let url = hermesBaseURL()
        if url.absoluteString.hasSuffix("/") { return url }
        return URL(string: "\(url.absoluteString)/") ?? url
    }
}

private enum HermesRealtimeRelayHostError: LocalizedError {
    case unauthenticated
    case invalidPath
    case invalidResponse
    case registrationTimedOut

    var errorDescription: String? {
        switch self {
        case .unauthenticated:
            return "Realtime Hermes relay requires a signed-in Firebase user."
        case .invalidPath:
            return "Realtime Hermes relay request path is invalid."
        case .invalidResponse:
            return "Hermes returned an invalid realtime relay response."
        case .registrationTimedOut:
            return "Realtime Hermes relay registration timed out."
        }
    }
}
